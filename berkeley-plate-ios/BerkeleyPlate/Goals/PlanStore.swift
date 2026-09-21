import Foundation
import Observation
import os

private let planLog = Logger(subsystem: "BerkeleyPlate", category: "PlanStore")
// Bumped to v2 after data model change (PlanSlot.recommendations → mealOptions).
// Old v1 plans stored in UserDefaults are silently ignored and not migrated.
private let planDefaultsPrefix = "localPlan_v2_"

@Observable @MainActor
final class PlanStore {
    private(set) var plan: DayPlan?
    private(set) var isLoading = false
    private(set) var error: String?

    private let api: APIClient
    private var menuCache: [MenuKey: MenuEnvelope] = [:]

    init() {
        let base = (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String) ?? ""
        api = APIClient(baseURL: URL(string: base) ?? URL(string: "https://api.example.invalid")!)
    }

    // MARK: - Plan Lifecycle

    func loadPlan(date: String, goal: UserGoal?, logs: [LoggedMeal], recurringFoods: [RecurringFood]) async {
        guard let saved = loadFromDefaults(date: date) else { plan = nil; return }
        plan = saved
        if let goal {
            refreshBudget(goal: goal, logs: logs, recurringFoods: recurringFoods)
            await scoreLocally(goal: goal, recurringFoods: recurringFoods)
        }
    }

    func createPlan(
        date: String, goal: UserGoal,
        slots: [PlanSlotInput], logs: [LoggedMeal],
        recurringFoods: [RecurringFood],
        snackOverrides: [DailySnackOverride],
        savedOutsideKcal: Double = 0
    ) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        // Resolve each slot's meal period, then sort chronologically using Meal.allCases
        // canonical order (breakfast → brunch → lunch → allDay → dinner → lateNight).
        let fallbackMeals: [Meal] = [.breakfast, .lunch, .dinner]
        let resolvedSlots: [(PlanSlotInput, Meal)] = slots.enumerated().map { i, s in
            let meal = s.mealPeriod.flatMap { Meal(rawValue: $0) } ?? fallbackMeals[min(i, 2)]
            return (s, meal)
        }
        let chronological = resolvedSlots.sorted { a, b in
            let ia = Meal.allCases.firstIndex(of: a.1) ?? 99
            let ib = Meal.allCases.firstIndex(of: b.1) ?? 99
            return ia < ib
        }
        let planSlots = chronological.enumerated().map { i, pair -> PlanSlot in
            let (s, meal) = pair
            return PlanSlot(
                id: UUID().uuidString, slotOrder: i,
                hall: s.hall, mealPeriod: meal.rawValue,
                status: "pending", mealOptions: [],
                acceptedComboId: nil, acceptedMacros: nil
            )
        }

        let budget = computeBudget(goal: goal, logs: logs, slots: planSlots,
                                   recurringFoods: recurringFoods, snackOverrides: snackOverrides,
                                   savedOutsideKcal: savedOutsideKcal)
        plan = DayPlan(
            id: UUID().uuidString, planDate: date,
            goalCalories: goal.targetCalories, goalProteinG: goal.targetProteinG,
            goalCarbsG: goal.targetCarbsG, goalFatG: goal.targetFatG,
            lastRegeneratedAt: Date(), lastComputedBudget: budget,
            confirmedAt: nil, slots: planSlots,
            snackOverrides: snackOverrides,
            savedOutsideKcal: savedOutsideKcal
        )
        saveToDefaults()
        await scoreLocally(goal: goal, recurringFoods: recurringFoods)
    }

    // MARK: - Slot Actions

    /// Accept a specific meal combo for a slot. Synchronous — updates state immediately.
    func acceptSlot(slotId: String, comboId: String) {
        guard let idx = plan?.slots.firstIndex(where: { $0.id == slotId }) else { return }
        guard let combo = plan?.slots[idx].mealOptions.first(where: { $0.id == comboId }) else { return }
        plan?.slots[idx].status = "accepted"
        plan?.slots[idx].acceptedComboId = comboId
        plan?.slots[idx].acceptedMacros = combo.totalMacros
        saveToDefaults()
    }

    /// Mark the plan confirmed. Synchronous.
    func confirmPlan() {
        plan?.confirmedAt = Date()
        saveToDefaults()
    }

    // MARK: - Component Swap

    /// Replace one component in an existing combo with a new item. Synchronous.
    func swapComponent(slotId: String, comboId: String, role: FoodRole, newComponent: MealComponent) {
        guard let slotIdx = plan?.slots.firstIndex(where: { $0.id == slotId }) else { return }
        guard let comboIdx = plan?.slots[slotIdx].mealOptions.firstIndex(where: { $0.id == comboId }) else { return }
        if let compIdx = plan?.slots[slotIdx].mealOptions[comboIdx].components.firstIndex(where: { $0.role == role }) {
            plan?.slots[slotIdx].mealOptions[comboIdx].components[compIdx] = newComponent
        } else {
            plan?.slots[slotIdx].mealOptions[comboIdx].components.append(newComponent)
        }
        saveToDefaults()
    }

    /// Async: fetch alternative items for one role in a combo, ready to display in a swap sheet.
    func swapCandidates(slotId: String, comboId: String, role: FoodRole, goal: UserGoal?) async -> [MealComponent] {
        guard let slot  = plan?.slots.first(where: { $0.id == slotId }),
              let combo = slot.mealOptions.first(where: { $0.id == comboId }) else { return [] }

        let key = MenuKey(
            hall: Hall(rawValue: slot.hall) ?? .crossroads,
            date: plan?.planDate ?? BerkeleyClock.serviceDate(),
            meal: Meal(rawValue: slot.mealPeriod) ?? .dinner
        )
        let envelope: MenuEnvelope?
        if let cached = menuCache[key] { envelope = cached }
        else { envelope = await fetchAndCacheMenu(key: key) }
        guard let envelope else { return [] }

        let existingIds = Set(combo.components.map(\.itemId))
        return LocalRecommender.swapCandidates(
            from: envelope.items, role: role, excluding: existingIds, goal: goal
        )
    }

    // MARK: - Slot Editing

    /// Remove one component from a pending combo (user says "no" without swapping).
    func removeComponent(slotId: String, comboId: String, itemId: String) {
        guard let slotIdx = plan?.slots.firstIndex(where: { $0.id == slotId }) else { return }
        guard let comboIdx = plan?.slots[slotIdx].mealOptions.firstIndex(where: { $0.id == comboId }) else { return }
        plan?.slots[slotIdx].mealOptions[comboIdx].components.removeAll { $0.itemId == itemId }
        saveToDefaults()
    }

    /// Append a new component to a pending combo (user adds an extra item).
    func addComponent(slotId: String, comboId: String, component: MealComponent) {
        guard let slotIdx = plan?.slots.firstIndex(where: { $0.id == slotId }) else { return }
        guard let comboIdx = plan?.slots[slotIdx].mealOptions.firstIndex(where: { $0.id == comboId }) else { return }
        plan?.slots[slotIdx].mealOptions[comboIdx].components.append(component)
        saveToDefaults()
    }

    /// Return items from the slot's menu that can be added to an existing combo (all roles, no overlaps).
    func addCandidates(slotId: String, comboId: String, goal: UserGoal?) async -> [MealComponent] {
        guard let slot  = plan?.slots.first(where: { $0.id == slotId }),
              let combo = slot.mealOptions.first(where: { $0.id == comboId }) else { return [] }

        let key = MenuKey(
            hall: Hall(rawValue: slot.hall) ?? .crossroads,
            date: plan?.planDate ?? BerkeleyClock.serviceDate(),
            meal: Meal(rawValue: slot.mealPeriod) ?? .dinner
        )
        let envelope: MenuEnvelope?
        if let cached = menuCache[key] { envelope = cached }
        else { envelope = await fetchAndCacheMenu(key: key) }
        guard let envelope else { return [] }

        let existingIds = Set(combo.components.map(\.itemId))
        return LocalRecommender.addCandidates(from: envelope.items, excluding: existingIds, goal: goal)
    }

    /// Adjust the serving count of one component inside a pending combo by `delta` (±0.25 steps).
    /// Rescales the component's stored macros proportionally.
    func adjustServing(slotId: String, comboId: String, itemId: String, delta: Double) {
        guard let si = plan?.slots.firstIndex(where: { $0.id == slotId }) else { return }
        guard let ci = plan?.slots[si].mealOptions.firstIndex(where: { $0.id == comboId }) else { return }
        guard let pi = plan?.slots[si].mealOptions[ci].components.firstIndex(where: { $0.itemId == itemId }) else { return }
        var comp = plan!.slots[si].mealOptions[ci].components[pi]
        let oldCount = comp.servingCount
        let newCount = max(0.25, ((oldCount + delta) * 4).rounded() / 4)
        guard newCount != oldCount, oldCount > 0 else { return }
        if let m = comp.macros {
            let s = newCount / oldCount
            comp.macros = PlanMacros(caloriesKcal: m.caloriesKcal * s,
                                     proteinG:     m.proteinG     * s,
                                     carbsG:       m.carbsG       * s,
                                     fatG:         m.fatG         * s)
        }
        comp.servingCount = newCount
        plan!.slots[si].mealOptions[ci].components[pi] = comp
        // If this is the accepted combo, keep acceptedMacros in sync with the new totals.
        if plan!.slots[si].acceptedComboId == comboId {
            plan!.slots[si].acceptedMacros = plan!.slots[si].mealOptions[ci]
                .components.compactMap(\.macros).reduce(.zero, +)
        }
        saveToDefaults()
    }

    /// Overwrite the accepted macros for an already-accepted slot (e.g. user corrects a value).
    func updateAcceptedMacros(slotId: String, macros: PlanMacros) {
        guard let idx = plan?.slots.firstIndex(where: { $0.id == slotId }) else { return }
        plan?.slots[idx].acceptedMacros = macros
        saveToDefaults()
    }

    // MARK: - Snack Overrides

    /// Update the snack override for a specific recurring food for today's plan only.
    func updateSnackOverride(_ override: DailySnackOverride) {
        guard let idx = plan?.snackOverrides.firstIndex(where: { $0.foodId == override.foodId }) else {
            plan?.snackOverrides.append(override)
            saveToDefaults()
            return
        }
        plan?.snackOverrides[idx] = override
        saveToDefaults()
    }

    // MARK: - Budget Refresh

    /// Recompute remaining macro budget from today's logs + accepted slot macros + recurring snacks.
    func refreshBudget(goal: UserGoal, logs: [LoggedMeal], recurringFoods: [RecurringFood]) {
        guard let current = plan else { return }
        let budget = computeBudget(goal: goal, logs: logs, slots: current.slots,
                                   recurringFoods: recurringFoods, snackOverrides: current.snackOverrides,
                                   savedOutsideKcal: current.savedOutsideKcal)
        plan?.lastComputedBudget = budget
        plan?.lastRegeneratedAt = Date()
        saveToDefaults()
    }

    // MARK: - Scoring

    /// Re-score all pending slots using the local menu cache.
    func scoreLocally(goal: UserGoal?, recurringFoods: [RecurringFood]) async {
        guard var updated = plan, let budget = updated.lastComputedBudget else { return }

        let pendingCount = max(updated.slots.filter { $0.isPending }.count, 1)
        let perSlotBudget = PlanBudget(
            caloriesKcal: max(budget.caloriesKcal / Double(pendingCount), 50),
            proteinG:     max(budget.proteinG     / Double(pendingCount),  5),
            carbsG:       budget.carbsG / Double(pendingCount),
            fatG:         budget.fatG   / Double(pendingCount)
        )

        // Track items used by previously scored slots for the same menu so that
        // multiple eating occasions at the same meal period (e.g. Brunch ×2) get
        // different food combinations instead of identical suggestions.
        var usedItemsByKey: [MenuKey: Set<String>] = [:]

        for i in updated.slots.indices where updated.slots[i].isPending {
            let slot = updated.slots[i]
            let key  = MenuKey(
                hall: Hall(rawValue: slot.hall) ?? .crossroads,
                date: updated.planDate,
                meal: Meal(rawValue: slot.mealPeriod) ?? .dinner
            )
            let envelope: MenuEnvelope?
            if let cached = menuCache[key] { envelope = cached }
            else { envelope = await fetchAndCacheMenu(key: key) }

            if let envelope {
                let excluding = usedItemsByKey[key] ?? []
                let options = LocalRecommender.recommend(
                    from: envelope.items,
                    meal: key.meal,
                    goal: goal,
                    budget: perSlotBudget,
                    excluding: excluding
                )
                updated.slots[i].mealOptions = options
                // Mark these items as used so subsequent same-period slots avoid them
                let usedIds = Set(options.flatMap { $0.components.map(\.itemId) })
                usedItemsByKey[key, default: []].formUnion(usedIds)
            }
        }
        plan = updated
        saveToDefaults()
    }

    /// Generate fresh meal options for one pending slot, excluding previously seen items.
    func regenerateSlotLocally(slotId: String, excluding: Set<String>, goal: UserGoal?,
                               recurringFoods: [RecurringFood]) async {
        guard var updated = plan, let budget = updated.lastComputedBudget else { return }
        guard let idx = updated.slots.firstIndex(where: { $0.id == slotId }),
              updated.slots[idx].isPending else { return }

        let pendingCount = max(updated.slots.filter { $0.isPending }.count, 1)
        let perSlotBudget = PlanBudget(
            caloriesKcal: max(budget.caloriesKcal / Double(pendingCount), 50),
            proteinG:     max(budget.proteinG     / Double(pendingCount),  5),
            carbsG:       budget.carbsG / Double(pendingCount),
            fatG:         budget.fatG   / Double(pendingCount)
        )

        let slot = updated.slots[idx]
        let key  = MenuKey(
            hall: Hall(rawValue: slot.hall) ?? .crossroads,
            date: updated.planDate,
            meal: Meal(rawValue: slot.mealPeriod) ?? .dinner
        )
        let envelope: MenuEnvelope?
        if let cached = menuCache[key] { envelope = cached }
        else { envelope = await fetchAndCacheMenu(key: key) }

        if let envelope {
            updated.slots[idx].mealOptions = LocalRecommender.recommend(
                from: envelope.items,
                meal: key.meal,
                goal: goal,
                budget: perSlotBudget,
                excluding: excluding
            )
            plan = updated
            saveToDefaults()
        }
    }

    // MARK: - Misc

    func clearPlan() {
        if let date = plan?.planDate {
            UserDefaults.standard.removeObject(forKey: planDefaultsPrefix + date)
        }
        plan = nil
    }

    func clearError() { error = nil }

    // MARK: - Private

    private func computeBudget(
        goal: UserGoal, logs: [LoggedMeal], slots: [PlanSlot],
        recurringFoods: [RecurringFood], snackOverrides: [DailySnackOverride],
        savedOutsideKcal: Double = 0
    ) -> PlanBudget {
        let logCal   = logs.reduce(0.0) { $0 + $1.macros.caloriesKcal }
        let logPro   = logs.reduce(0.0) { $0 + $1.macros.proteinG }
        let logCarb  = logs.reduce(0.0) { $0 + $1.macros.carbsG }
        let logFat   = logs.reduce(0.0) { $0 + $1.macros.fatG }
        let accepted = slots.filter { $0.isAccepted }
        let accCal   = accepted.reduce(0.0) { $0 + ($1.acceptedMacros?.caloriesKcal ?? 0) }
        let accPro   = accepted.reduce(0.0) { $0 + ($1.acceptedMacros?.proteinG     ?? 0) }
        let accCarb  = accepted.reduce(0.0) { $0 + ($1.acceptedMacros?.carbsG       ?? 0) }
        let accFat   = accepted.reduce(0.0) { $0 + ($1.acceptedMacros?.fatG         ?? 0) }

        // Deduct enabled recurring snack macros (today's override or recurring default)
        let snacks = snackMacros(from: snackOverrides, recurringFoods: recurringFoods)

        return PlanBudget(
            caloriesKcal: max(0, goal.targetCalories - logCal - accCal - snacks.caloriesKcal - savedOutsideKcal),
            proteinG:     max(0, goal.targetProteinG - logPro - accPro - snacks.proteinG),
            carbsG:       max(0, goal.targetCarbsG   - logCarb - accCarb - snacks.carbsG),
            fatG:         max(0, goal.targetFatG     - logFat  - accFat  - snacks.fatG)
        )
    }

    private func snackMacros(from overrides: [DailySnackOverride], recurringFoods: [RecurringFood]) -> PlanMacros {
        guard !overrides.isEmpty else { return .zero }
        let lookup = Dictionary(uniqueKeysWithValues: recurringFoods.map { ($0.id, $0) })
        return overrides.reduce(.zero) { total, ov in
            guard let food = lookup[ov.foodId] else { return total }
            return total + ov.effectiveMacros(food: food)
        }
    }

    private func fetchAndCacheMenu(key: MenuKey) async -> MenuEnvelope? {
        do {
            let result = try await api.send(
                path: "v1/menu",
                query: [
                    URLQueryItem(name: "hall",  value: key.hall.rawValue),
                    URLQueryItem(name: "date",  value: key.date),
                    URLQueryItem(name: "meal",  value: key.meal.rawValue),
                ],
                timeout: 10
            )
            let envelope = try JSONCoding.decoder().decode(MenuEnvelope.self, from: result.data)
            menuCache[key] = envelope
            planLog.info("cached menu \(key.hall.rawValue)/\(key.meal.rawValue) (\(envelope.items.count) items)")
            return envelope
        } catch {
            planLog.error("menu fetch failed \(key.hall.rawValue)/\(key.meal.rawValue): \(error.localizedDescription)")
            return nil
        }
    }

    private func loadFromDefaults(date: String) -> DayPlan? {
        guard let data = UserDefaults.standard.data(forKey: planDefaultsPrefix + date) else { return nil }
        return try? JSONCoding.decoder().decode(DayPlan.self, from: data)
    }

    private func saveToDefaults() {
        guard let plan else { return }
        if let data = try? JSONCoding.encoder().encode(plan) {
            UserDefaults.standard.set(data, forKey: planDefaultsPrefix + plan.planDate)
        }
    }
}
