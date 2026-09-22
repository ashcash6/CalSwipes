import SwiftUI

struct PlanMyDayScreen: View {
    var planStore: PlanStore
    var store: AppStore
    var daily: DailyStore

    @State private var showCreate = false

    private var today: String { BerkeleyClock.serviceDate() }

    var body: some View {
        NavigationStack {
            Group {
                if planStore.isLoading && planStore.plan == nil {
                    ProgressView("Planning your day…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let plan = planStore.plan {
                    PlanContentView(plan: plan, planStore: planStore, daily: daily)
                } else {
                    EmptyPlanView { showCreate = true }
                }
            }
            .background(CP.bg)
            .navigationTitle("Plan My Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if planStore.plan != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Plan") { showCreate = true }
                            .fontWeight(.medium)
                    }
                }
            }
        }
        .task {
            await planStore.loadPlan(date: today, goal: daily.goal, logs: daily.todayLogs,
                                     recurringFoods: daily.recurringFoods)
        }
        .onChange(of: daily.todayCalories) { _, _ in
            guard let goal = daily.goal else { return }
            planStore.refreshBudget(goal: goal, logs: daily.todayLogs,
                                    recurringFoods: daily.recurringFoods)
        }
        .sheet(isPresented: $showCreate) {
            CreatePlanSheet(store: store, daily: daily, planStore: planStore, today: today)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { planStore.error != nil },
            set: { if !$0 { planStore.clearError() } }
        )) {
            Button("OK") { planStore.clearError() }
        } message: {
            Text(planStore.error ?? "")
        }
    }
}

// MARK: - Empty State

private struct EmptyPlanView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: CP.sp24) {
            Spacer()
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 52))
                .foregroundStyle(CP.navy.opacity(0.5))
            VStack(spacing: CP.sp8) {
                Text("No plan for today")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .foregroundStyle(CP.text)
                Text("Plan your meals ahead and get smart recommendations based on your goals.")
                    .font(.subheadline)
                    .foregroundStyle(CP.textSec)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            CPPrimaryButton(title: "Plan My Day", icon: "calendar.badge.plus", action: onCreate)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }
}

// MARK: - Plan Content

private struct PlanContentView: View {
    let plan: DayPlan
    var planStore: PlanStore
    var daily: DailyStore

    @State private var showRecurringFoods = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: CP.sp16) {
                planHeader
                offTargetBanner
                if daily.recurringFoods.isEmpty {
                    recurringFoodsNudge
                } else {
                    snacksSection
                }
                ForEach(plan.slots.sorted(by: { $0.slotOrder < $1.slotOrder })) { slot in
                    PlanSlotCard(slot: slot, plan: plan, planStore: planStore, daily: daily)
                }
                if !plan.isConfirmed && plan.allSlotsResolved {
                    confirmButton
                } else if plan.isConfirmed {
                    confirmedBadge
                }
            }
            .padding(CP.sp20)
        }
        .sheet(isPresented: $showRecurringFoods) {
            RecurringFoodsScreen(daily: daily)
        }
    }

    private var recurringFoodsNudge: some View {
        Button { showRecurringFoods = true } label: {
            HStack(spacing: CP.sp12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(CP.navy)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add recurring foods")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CP.text)
                    Text("Protein shakes, bars, or snacks you eat daily — deducted from your plan budget.")
                        .font(.caption)
                        .foregroundStyle(CP.textSec)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CP.textSec)
            }
            .padding(CP.sp16)
            .background(CP.navy.opacity(0.06), in: RoundedRectangle(cornerRadius: CP.r12))
        }
        .buttonStyle(CPPressStyle())
    }

    // Dining-hall slots only — used for the off-target comparison (goal minus snacks).
    private var totalDiningMacros: PlanMacros {
        plan.slots.reduce(.zero) { total, slot in
            if let m = slot.acceptedMacros { return total + m }
            if let m = slot.mealOptions.first?.totalMacros { return total + m }
            return total
        }
    }

    // Full day total: dining slots + enabled recurring snacks.
    private var totalProjectedMacros: PlanMacros {
        totalDiningMacros + plan.snackMacros(recurringFoods: daily.recurringFoods)
    }

    private var planHeader: some View {
        let snackMacros  = plan.snackMacros(recurringFoods: daily.recurringFoods)
        let snackCal     = snackMacros.caloriesKcal
        let diningTarget = max(0, plan.goalCalories - plan.savedOutsideKcal - snackCal)
        let total        = totalProjectedMacros

        return VStack(alignment: .leading, spacing: CP.sp12) {
            CPSectionLabel(text: plan.planDate)

            VStack(alignment: .leading, spacing: 4) {
                Text("Your meal plan")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .foregroundStyle(CP.text)

                if plan.savedOutsideKcal > 0 {
                    HStack(spacing: 4) {
                        Text("Daily goal: \(Int(plan.goalCalories)) kcal")
                        Text("·")
                        Text("\(Int(plan.savedOutsideKcal)) kcal outside")
                            .foregroundStyle(CP.carbs)
                        Text("·")
                        Text("\(Int(diningTarget)) kcal dining")
                            .foregroundStyle(CP.navy)
                    }
                    .font(.caption2).foregroundStyle(CP.textSec)
                } else {
                    Text("Goal: \(Int(plan.goalCalories)) kcal daily")
                        .font(.caption2).foregroundStyle(CP.textSec)
                }
            }

            if total.caloriesKcal > 0 {
                Divider()
                VStack(alignment: .leading, spacing: CP.sp8) {
                    CPSectionLabel(text: "Total projected")
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Int(total.caloriesKcal))")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(CP.navy)
                        Text("kcal")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(CP.textSec)
                        Spacer()
                        HStack(spacing: CP.sp14) {
                            macroChip(Int(total.proteinG), label: "pro", color: CP.protein)
                            macroChip(Int(total.carbsG),   label: "carbs", color: CP.carbs)
                            macroChip(Int(total.fatG),     label: "fat", color: CP.fat)
                        }
                    }
                    if snackCal > 0 {
                        Text("Includes \(Int(snackCal)) kcal from recurring snacks")
                            .font(.caption2).foregroundStyle(CP.textSec)
                    }
                }
            }
        }
        .cpCard(CP.sp20)
    }

    private func macroChip(_ value: Int, label: String, color: Color) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text("\(value)")
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(CP.textSec)
        }
    }


    private var snacksSection: some View {
        VStack(alignment: .leading, spacing: CP.sp8) {
            CPSectionLabel(text: "Recurring foods")
            ForEach(daily.recurringFoods) { food in
                let override  = plan.snackOverrides.first(where: { $0.foodId == food.id })
                let isEnabled = override?.isEnabled ?? food.defaultEnabled
                let kcal = Int(override?.caloriesOverride ?? food.calories)
                let prot = Int(override?.proteinGOverride ?? food.proteinG)
                HStack(spacing: CP.sp12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(food.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(CP.text)
                        if isEnabled {
                            Text("\(kcal) kcal · \(prot)g protein")
                                .font(.caption2).foregroundStyle(CP.textSec)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isEnabled },
                        set: { newValue in
                            var updated = override ?? DailySnackOverride(foodId: food.id, isEnabled: newValue)
                            updated.isEnabled = newValue
                            planStore.updateSnackOverride(updated)
                            if let goal = daily.goal {
                                planStore.refreshBudget(goal: goal, logs: daily.todayLogs,
                                                        recurringFoods: daily.recurringFoods)
                                Task { await planStore.scoreLocally(goal: goal, recurringFoods: daily.recurringFoods) }
                            }
                        }
                    ))
                    .labelsHidden()
                    .tint(CP.navy)
                    .frame(width: 51)
                }
                .padding(CP.sp12)
                .background(CP.surface, in: RoundedRectangle(cornerRadius: CP.r12))
                .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 1)
                .opacity(isEnabled ? 1.0 : 0.55)
            }
        }
    }

    private var confirmButton: some View {
        CPPrimaryButton(title: "Confirm Plan for Today", icon: "checkmark.seal.fill") {
            planStore.confirmPlan()
        }
        .padding(.top, CP.sp8)
    }

    private var confirmedBadge: some View {
        HStack(spacing: CP.sp8) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(CP.navy)
            Text("Plan confirmed for today")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CP.navy)
        }
        .padding(CP.sp16)
        .frame(maxWidth: .infinity)
        .background(CP.navy.opacity(0.08), in: RoundedRectangle(cornerRadius: CP.r14))
        .padding(.top, CP.sp8)
    }

    @ViewBuilder
    private var offTargetBanner: some View {
        let total = totalDiningMacros
        let snackCal = plan.snackMacros(recurringFoods: daily.recurringFoods).caloriesKcal
        let target = max(100, plan.goalCalories - plan.savedOutsideKcal - snackCal)
        if total.caloriesKcal > 50 {
            let ratio = total.caloriesKcal / target
            if ratio < 0.9 || ratio > 1.1 {
                let diff = total.caloriesKcal - target
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Int(abs(diff))) kcal \(diff > 0 ? "over" : "under") your dining-hall target")
                            .font(.caption.weight(.semibold))
                        Text("Adjust servings or add/remove items to reach \(Int(target)) kcal.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

// MARK: - Plan Slot Card

private struct SwapRequest: Identifiable {
    let id = UUID()
    let slotId: String
    let comboId: String
    let role: FoodRole
}

private struct AddItemRequest: Identifiable {
    let id = UUID()
    let slotId: String
    let comboId: String
}

private struct PlanSlotCard: View {
    let slot: PlanSlot
    let plan: DayPlan
    var planStore: PlanStore
    var daily: DailyStore

    @State private var isRegenerating = false
    @State private var rejectedIds: Set<String> = []
    @State private var swapRequest: SwapRequest?
    @State private var addItemRequest: AddItemRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            slotHeader
            CPDivider()
            slotBody
        }
        .background(CP.surface, in: RoundedRectangle(cornerRadius: CP.r16))
        .shadow(color: .black.opacity(CP.shadowOpacity), radius: CP.shadowRadius, x: 0, y: CP.shadowY)
        .sheet(item: $swapRequest) { req in
            SwapSheet(request: req, planStore: planStore, goal: daily.goal)
        }
        .sheet(item: $addItemRequest) { req in
            AddItemSheet(request: req, planStore: planStore, goal: daily.goal)
        }
    }

    private var slotHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.hallTitle)
                    .font(.subheadline.weight(.semibold))
                Text(slot.mealPeriodTitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            slotStatusBadge
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private var slotStatusBadge: some View {
        switch slot.status {
        case "accepted":
            Label("Accepted", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CP.navy)
                .labelStyle(.titleAndIcon)
        case "consumed_externally":
            Label("Logged", systemImage: "fork.knife")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        default:
            Text("Choose a meal")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var slotBody: some View {
        if slot.isAccepted {
            acceptedBody
        } else if slot.isConsumed {
            consumedBody
        } else {
            pendingBody
        }
    }

    // Shows the accepted combo's full component breakdown
    private var acceptedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let combo = slot.acceptedCombo {
                let sorted = combo.components.sorted {
                    let p: [FoodRole: Int] = [.protein: 0, .carb: 1, .produce: 2, .fat: 3, .other: 4]
                    return (p[$0.role] ?? 5) < (p[$1.role] ?? 5)
                }
                ForEach(sorted) { component in
                    ComponentRow(
                        component: component, showActions: false, onSwap: {}, onRemove: {},
                        onAdjustServing: { delta in
                            if let comboId = slot.acceptedComboId {
                                planStore.adjustServing(slotId: slot.id, comboId: comboId,
                                                        itemId: component.itemId, delta: delta)
                            }
                        }
                    )
                }
                if let macros = slot.acceptedMacros {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(CP.navy).font(.caption)
                        Text("\(Int(macros.caloriesKcal)) kcal · \(Int(macros.proteinG))g protein")
                            .font(.caption).foregroundStyle(CP.textSec)
                    }
                    .padding(.horizontal, CP.sp16).padding(.vertical, CP.sp10)
                }
            } else if let macros = slot.acceptedMacros {
                HStack(spacing: CP.sp12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(CP.navy).font(.title3)
                    Text("\(Int(macros.caloriesKcal)) kcal · \(Int(macros.proteinG))g protein")
                        .font(.caption).foregroundStyle(CP.textSec)
                }
                .padding(CP.sp16)
            }
        }
    }

    private var consumedBody: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Filled by a logged meal").font(.subheadline).foregroundStyle(.secondary)
                Text("This slot was counted when you logged a meal today.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
    }

    private var pendingBody: some View {
        VStack(spacing: 0) {
            if slot.mealOptions.isEmpty {
                Text("No recommendations available — tap refresh to try again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(16)
            } else {
                // Each option is its own visually distinct card so the three choices
                // are clearly separated rather than running together.
                VStack(spacing: 10) {
                    ForEach(Array(slot.mealOptions.enumerated()), id: \.element.id) { index, combo in
                        MealComboCard(
                            combo: combo,
                            optionNumber: index + 1,
                            planIsConfirmed: plan.isConfirmed,
                            onAccept: {
                                planStore.acceptSlot(slotId: slot.id, comboId: combo.id)
                            },
                            onSwap: { role in
                                swapRequest = SwapRequest(slotId: slot.id, comboId: combo.id, role: role)
                            },
                            onRemove: { itemId in
                                planStore.removeComponent(slotId: slot.id, comboId: combo.id, itemId: itemId)
                            },
                            onAddItem: {
                                addItemRequest = AddItemRequest(slotId: slot.id, comboId: combo.id)
                            },
                            onAdjustServing: { itemId, delta in
                                planStore.adjustServing(slotId: slot.id, comboId: combo.id, itemId: itemId, delta: delta)
                            }
                        )
                        .background(CP.surface2, in: RoundedRectangle(cornerRadius: CP.r12))
                    }
                }
                .padding(12)
            }

            if !plan.isConfirmed {
                Button {
                    let allItemIds = Set(slot.mealOptions.flatMap { $0.components.map(\.itemId) })
                    let excluded = rejectedIds.union(allItemIds)
                    rejectedIds = excluded
                    isRegenerating = true
                    Task {
                        await planStore.regenerateSlotLocally(
                            slotId: slot.id, excluding: excluded, goal: daily.goal,
                            recurringFoods: daily.recurringFoods
                        )
                        isRegenerating = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isRegenerating { ProgressView().scaleEffect(0.75) }
                        else { Image(systemName: "arrow.triangle.2.circlepath") }
                        Text("Try different options")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .disabled(isRegenerating)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }
}

// MARK: - Meal Combo Card

private struct MealComboCard: View {
    let combo: MealCombo
    let optionNumber: Int
    let planIsConfirmed: Bool
    let onAccept: () -> Void
    let onSwap: (FoodRole) -> Void
    let onRemove: (String) -> Void          // itemId
    let onAddItem: () -> Void
    let onAdjustServing: (String, Double) -> Void  // itemId, delta

    // Protein first, then carbs, then produce, then extras — most important items visible at top.
    private var sortedComponents: [MealComponent] {
        let priority: [FoodRole: Int] = [.protein: 0, .carb: 1, .produce: 2, .fat: 3, .other: 4]
        return combo.components.sorted { (priority[$0.role] ?? 5) < (priority[$1.role] ?? 5) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Option header
            HStack {
                let ordinals = ["1st choice", "2nd choice", "3rd choice"]
                Text(optionNumber <= ordinals.count ? ordinals[optionNumber - 1] : "Option \(optionNumber)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CP.navy)
                Spacer()
            }
            .padding(.horizontal, CP.sp14)
            .padding(.top, 11)
            .padding(.bottom, 6)

            CPDivider().padding(.horizontal, CP.sp14)

            // Components sorted protein → carbs → produce → extras
            ForEach(sortedComponents) { component in
                ComponentRow(
                    component: component,
                    showActions: !planIsConfirmed,
                    onSwap: { onSwap(component.role) },
                    onRemove: { onRemove(component.itemId) },
                    onAdjustServing: planIsConfirmed ? nil : { delta in
                        onAdjustServing(component.itemId, delta)
                    }
                )
            }

            CPDivider().padding(.horizontal, CP.sp14)

            // Footer: totals + accept + add
            HStack(alignment: .center, spacing: CP.sp10) {
                let totals = combo.totalMacros
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(totals.caloriesKcal)) kcal")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CP.navy)
                    Text("\(Int(totals.proteinG))g pro · \(Int(totals.carbsG))g carbs · \(Int(totals.fatG))g fat")
                        .font(.caption2).foregroundStyle(CP.textSec)
                }
                Spacer()
                if !planIsConfirmed {
                    Button { onAddItem() } label: {
                        Image(systemName: "plus.circle")
                            .font(.title3)
                            .foregroundStyle(CP.navy.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    Button("Accept", action: onAccept)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(CP.navy)
                }
            }
            .padding(.horizontal, CP.sp14)
            .padding(.vertical, CP.sp10)
        }
    }
}

// MARK: - Component Row

private struct ComponentRow: View {
    let component: MealComponent
    let showActions: Bool
    let onSwap: () -> Void
    let onRemove: () -> Void
    /// When provided, shows a −/+ stepper. nil = read-only (accepted state).
    var onAdjustServing: ((Double) -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: component.role.systemImage)
                .font(.caption)
                .foregroundStyle(CP.roleColor(component.role))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(component.itemName)
                    .font(.subheadline)
                    .lineLimit(1)
                if let phys = physicalLabel(component.servingCount, component.baseServing) {
                    Text("\(servingCountText(component.servingCount)) · \(phys)")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(servingCountText(component.servingCount))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let macros = component.macros {
                    Text("\(Int(macros.caloriesKcal)) kcal · \(Int(macros.proteinG))g pro")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            // Serving stepper — shown whenever the callback is provided (pending OR accepted)
            if let onAdjust = onAdjustServing {
                HStack(spacing: 1) {
                    Button { onAdjust(-0.25) } label: {
                        Image(systemName: "minus.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(component.servingCount <= 0.25)

                    Text(servingLabel(component.servingCount))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CP.navy)
                        .frame(minWidth: 30, alignment: .center)

                    Button { onAdjust(0.25) } label: {
                        Image(systemName: "plus.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else if component.servingCount > 1 {
                // Read-only badge when no stepper (confirmed plan)
                Text(servingLabel(component.servingCount))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(CP.navy)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(CP.navy.opacity(0.08), in: Capsule())
            }

            if showActions {
                Button { onSwap() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Button { onRemove() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.secondary.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private func servingLabel(_ count: Double) -> String {
    // "2.0" → "×2", "1.25" → "×1.25", "1.5" → "×1.5"
    if count.truncatingRemainder(dividingBy: 1) == 0 { return "×\(Int(count))" }
    var s = String(format: "%.2f", count)
    while s.hasSuffix("0") { s = String(s.dropLast()) }
    if s.hasSuffix(".")   { s = String(s.dropLast()) }
    return "×\(s)"
}

/// "2.0" → "2 servings", "1.0" → "1 serving", "1.25" → "1.25 servings"
private func servingCountText(_ count: Double) -> String {
    var num: String
    if count.truncatingRemainder(dividingBy: 1) == 0 {
        num = "\(Int(count))"
    } else {
        var s = String(format: "%.2f", count)
        while s.hasSuffix("0") { s = String(s.dropLast()) }
        if s.hasSuffix(".") { s = String(s.dropLast()) }
        num = s
    }
    return "\(num) \(count == 1.0 ? "serving" : "servings")"
}

/// Converts serving count × base quantity into a human-readable physical amount.
/// Returns nil for generic units ("serving", "portion") where no conversion applies.
private func physicalLabel(_ count: Double, _ serving: ComponentServing?) -> String? {
    guard let serving else { return nil }
    let total = count * serving.quantity
    let unitLC = serving.unit.lowercased()
    guard !["serving", "servings", "portion", "portions"].contains(unitLC) else { return nil }

    func fmt(_ d: Double) -> String {
        if d.truncatingRemainder(dividingBy: 1) == 0 { return "\(Int(d))" }
        var s = String(format: "%.2f", d)
        while s.hasSuffix("0") { s = String(s.dropLast()) }
        if s.hasSuffix(".") { s = String(s.dropLast()) }
        return s
    }

    switch unitLC {
    case "oz", "ounce", "ounces":
        let r = (total * 2).rounded() / 2
        return "~\(fmt(r)) oz"
    case "cup", "cups":
        let r = (total * 4).rounded() / 4
        return "~\(fmt(r)) \(r == 1 ? "cup" : "cups")"
    case "g", "gram", "grams":
        let r = max(1, (total / 5).rounded() * 5)
        return "~\(Int(r)) g"
    case "piece", "pieces", "each", "item", "items":
        let r = total.rounded()
        return r == 1 ? "1 piece" : "\(Int(r)) pieces"
    case "slice", "slices":
        let r = total.rounded()
        return r == 1 ? "1 slice" : "\(Int(r)) slices"
    case "bar", "bars":
        let r = total.rounded()
        return r == 1 ? "1 bar" : "\(Int(r)) bars"
    case "scoop", "scoops":
        let r = (total * 2).rounded() / 2
        return "\(fmt(r)) \(r == 1 ? "scoop" : "scoops")"
    default:
        let r = (total * 2).rounded() / 2
        return "~\(fmt(r)) \(serving.unit)"
    }
}

// MARK: - Swap Sheet

private struct SwapSheet: View {
    let request: SwapRequest
    var planStore: PlanStore
    let goal: UserGoal?

    @State private var candidates: [MealComponent] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading alternatives…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No alternatives available").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(candidates) { candidate in
                        Button {
                            planStore.swapComponent(
                                slotId: request.slotId,
                                comboId: request.comboId,
                                role: request.role,
                                newComponent: candidate
                            )
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.itemName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                if let macros = candidate.macros {
                                    Text("\(Int(macros.caloriesKcal)) kcal · \(Int(macros.proteinG))g protein · \(Int(macros.carbsG))g carbs")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Swap \(request.role.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            candidates = await planStore.swapCandidates(
                slotId: request.slotId,
                comboId: request.comboId,
                role: request.role,
                goal: goal
            )
            isLoading = false
        }
    }
}

// MARK: - Create Plan Sheet

/// One eating occasion in the plan draft: a specific dining hall + meal period.
private struct MealOccasion: Identifiable {
    let id = UUID()
    var hall: Hall
    var meal: Meal
}

struct CreatePlanSheet: View {
    var store: AppStore
    var daily: DailyStore
    var planStore: PlanStore
    let today: String

    @Environment(\.dismiss) private var dismiss
    /// Each entry is one eating occasion with its own hall + meal period.
    @State private var mealOccasions: [MealOccasion] = []
    @State private var snackOverrides: [DailySnackOverride] = []
    @State private var editingSnackFood: RecurringFood?
    @State private var isGenerating = false
    /// Calories to keep aside for meals eaten outside dining halls (typed as text for keyboard).
    @State private var savedOutsideText: String = ""
    /// Per-hall available meals fetched when the sheet opens — drives the meal period pickers.
    @State private var hallMeals: [Hall: [Meal]] = [:]

    var body: some View {
        NavigationStack {
            Form {
                goalSection
                outsideSection
                mealsSection
                if !daily.recurringFoods.isEmpty {
                    snacksSection
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Plan My Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isGenerating = true
                        Task {
                            guard let goal = daily.goal else { isGenerating = false; return }
                            // Build inputs in canonical chronological order,
                            // repeating a period N times if the user chose N occasions.
                            let inputs = mealOccasions.map { occasion in
                                PlanSlotInput(hall: occasion.hall.rawValue, mealPeriod: occasion.meal.rawValue)
                            }
                            await planStore.createPlan(
                                date: today, goal: goal, slots: inputs, logs: daily.todayLogs,
                                recurringFoods: daily.recurringFoods,
                                snackOverrides: snackOverrides,
                                savedOutsideKcal: Double(savedOutsideText) ?? 0
                            )
                            isGenerating = false
                            if planStore.plan != nil { dismiss() }
                        }
                    } label: {
                        if isGenerating { ProgressView().scaleEffect(0.8) }
                        else { Text("Generate") }
                    }
                    .fontWeight(.semibold)
                    .disabled(mealOccasions.isEmpty || isGenerating || daily.goal == nil)
                }
            }
        }
        .onAppear { applyDefaults() }
        .task {
            // Fetch availability for ALL halls in parallel so every hall's meal
            // period picker shows only the periods that actually exist for that day.
            let date = today
            await withTaskGroup(of: (Hall, [Meal]?).self) { group in
                for hall in Hall.allCases {
                    group.addTask { @MainActor in
                        let meals = await store.cachedOrFetchMeals(for: hall, date: date)
                        return (hall, meals)
                    }
                }
                for await (hall, meals) in group {
                    if let meals { hallMeals[hall] = meals }
                }
            }
            // Correct any pre-filled occasions whose meal period is now known to be invalid
            // for the selected hall (happens when applyDefaults() ran before data arrived).
            for i in mealOccasions.indices {
                let avail = availableMeals(for: mealOccasions[i].hall)
                if avail.count < Meal.allCases.count && !avail.contains(mealOccasions[i].meal) {
                    mealOccasions[i].meal = avail.first ?? mealOccasions[i].meal
                }
            }
        }
        .interactiveDismissDisabled(isGenerating)
        .sheet(item: $editingSnackFood) { food in
            EditSnackTodaySheet(food: food,
                                override: snackOverrides.first(where: { $0.foodId == food.id })) { updated in
                if let idx = snackOverrides.firstIndex(where: { $0.foodId == food.id }) {
                    snackOverrides[idx] = updated
                }
            } onUpdateDefault: { updatedFood in
                daily.updateRecurringFood(updatedFood)
            }
        }
    }

    private var enabledSnackSummary: (cal: Double, pro: Double)? {
        let enabled = snackOverrides.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }
        let cal = enabled.compactMap { ov -> Double? in
            guard let food = daily.recurringFoods.first(where: { $0.id == ov.foodId }) else { return nil }
            return ov.caloriesOverride ?? food.calories
        }.reduce(0, +)
        let pro = enabled.compactMap { ov -> Double? in
            guard let food = daily.recurringFoods.first(where: { $0.id == ov.foodId }) else { return nil }
            return ov.proteinGOverride ?? food.proteinG
        }.reduce(0, +)
        return (cal, pro)
    }

    private var goalSection: some View {
        Section("Goals") {
            if let goal = daily.goal {
                LabeledContent("Daily target") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(goal.targetCalories)) kcal")
                        Text("\(Int(goal.targetProteinG))g protein")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                // Live budget breakdown (snacks + outside deductions)
                let savedOutside = Double(savedOutsideText) ?? 0
                let snackCal = enabledSnackSummary?.cal ?? 0
                let snackPro = enabledSnackSummary?.pro ?? 0
                let hasDeductions = snackCal > 0 || savedOutside > 0

                if snackCal > 0 {
                    LabeledContent("Snacks (enabled)") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("−\(Int(snackCal)) kcal").foregroundStyle(.orange)
                            Text("−\(Int(snackPro))g protein")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if savedOutside > 0 {
                    LabeledContent("Reserved outside") {
                        Text("−\(Int(savedOutside)) kcal").foregroundStyle(.orange)
                    }
                }
                if hasDeductions {
                    LabeledContent("Dining-hall budget") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(max(0, goal.targetCalories - snackCal - savedOutside))) kcal")
                                .fontWeight(.semibold).foregroundStyle(CP.navy)
                            Text("\(Int(max(0, goal.targetProteinG - snackPro)))g protein")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Set your goals first in the Today tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var outsideSection: some View {
        Section {
            HStack {
                Text("Save for outside dining")
                Spacer()
                TextField("0", text: $savedOutsideText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text("kcal")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Outside Dining Hall")
        } footer: {
            Text("Reserve calories for protein bars, shakes, snacks, or meals eaten outside the dining hall.")
        }
    }

    private var mealsSection: some View {
        Section {
            ForEach(Array(mealOccasions.enumerated()), id: \.element.id) { index, occasion in
                HStack(spacing: 10) {
                    // Hall picker — corrects meal period when the new hall's
                    // known availability doesn't include the current selection.
                    Menu {
                        ForEach(Hall.allCases) { hall in
                            Button {
                                mealOccasions[index].hall = hall
                                let avail = availableMeals(for: hall)
                                if avail.count < Meal.allCases.count,
                                   !avail.contains(mealOccasions[index].meal) {
                                    mealOccasions[index].meal = avail.first ?? mealOccasions[index].meal
                                }
                            } label: {
                                if hall == occasion.hall {
                                    Label(hall.title, systemImage: "checkmark")
                                } else {
                                    Text(hall.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(occasion.hall.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    Text("·").foregroundStyle(.tertiary).font(.caption)

                    // Meal period picker — filtered to periods known to exist for THIS slot's hall.
                    let availablePeriods = availableMeals(for: occasion.hall)
                    Menu {
                        ForEach(availablePeriods) { meal in
                            Button {
                                mealOccasions[index].meal = meal
                            } label: {
                                if meal == occasion.meal {
                                    Label(meal.title, systemImage: "checkmark")
                                } else {
                                    Text(meal.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(occasion.meal.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button {
                        mealOccasions.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red.opacity(0.6))
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                let defaultHall = mealOccasions.last?.hall ?? store.selectedHall
                let defaultMeal = mealOccasions.last?.meal ?? .dinner
                mealOccasions.append(MealOccasion(hall: defaultHall, meal: defaultMeal))
            } label: {
                Label("Add Meal", systemImage: "plus.circle.fill")
                    .foregroundStyle(CP.navy)
            }
        } header: {
            Text("Meals")
        } footer: {
            if mealOccasions.isEmpty {
                Text("Add at least one meal to generate a plan.")
            } else {
                let count = mealOccasions.count
                Text("\(count) meal\(count == 1 ? "" : "s") planned")
            }
        }
    }

    // MARK: - Snacks Section

    private var snacksSection: some View {
        Section {
            ForEach(daily.recurringFoods) { food in
                if let idx = snackOverrides.firstIndex(where: { $0.foodId == food.id }) {
                    HStack {
                        Toggle(isOn: $snackOverrides[idx].isEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(food.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                let macros = snackOverrides[idx].effectiveMacros(food: food)
                                if macros.caloriesKcal > 0 {
                                    Text("\(Int(macros.caloriesKcal)) kcal · \(Int(macros.proteinG))g protein")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(CP.navy)

                        Button {
                            editingSnackFood = food
                        } label: {
                            Image(systemName: "pencil.circle")
                                .font(.title3)
                                .foregroundStyle(CP.navy.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } header: {
            Text("Recurring Foods")
        } footer: {
            let enabled = snackOverrides.filter(\.isEnabled)
            if enabled.isEmpty {
                Text("Enabled snacks are deducted from your meal budget before recommendations are generated.")
            } else {
                let totalCal = enabled.compactMap { ov -> Double? in
                    guard let food = daily.recurringFoods.first(where: { $0.id == ov.foodId }) else { return nil }
                    return ov.caloriesOverride ?? food.calories
                }.reduce(0, +)
                let totalPro = enabled.compactMap { ov -> Double? in
                    guard let food = daily.recurringFoods.first(where: { $0.id == ov.foodId }) else { return nil }
                    return ov.proteinGOverride ?? food.proteinG
                }.reduce(0, +)
                Text("\(Int(totalCal)) kcal · \(Int(totalPro))g protein from \(enabled.count) enabled snack\(enabled.count == 1 ? "" : "s") — deducted from budget.")
            }
        }
    }

    /// Available meal periods for a given hall.
    /// Priority: (1) live data fetched this session, (2) UserDefaults cache from AppStore,
    /// (3) live store data for the currently selected hall, (4) all cases as a fallback.
    private func availableMeals(for hall: Hall) -> [Meal] {
        // Freshest: fetched when the sheet opened
        if let meals = hallMeals[hall], !meals.isEmpty { return meals }
        // Warm UserDefaults cache (written by AppStore on previous foreground/selectHall calls)
        let key = "availMeals-\(hall.rawValue)-\(today)"
        if let raw = UserDefaults.standard.stringArray(forKey: key) {
            let meals = raw.compactMap { Meal(rawValue: $0) }
            if !meals.isEmpty { return meals }
        }
        // Live data for the currently selected hall
        if hall == store.selectedHall && !store.availableMeals.isEmpty {
            return store.availableMeals
        }
        // No data yet — allow any period; the task will correct invalid selections after it lands
        return Meal.allCases
    }

    /// Pre-fill defaults when the sheet opens.
    /// Creates one occasion per KNOWN available meal period for the detected hall.
    /// When no cached data exists, falls back to a sensible time-based guess.
    private func applyDefaults() {
        let defaultHall = store.selectedHall
        let available   = availableMeals(for: defaultHall)
        // Only pre-populate specific slots when we have real availability data for this hall.
        // Meal.allCases (6 entries) means we had no cached data — use a time-based default instead.
        if available.count < Meal.allCases.count {
            mealOccasions = available.map { MealOccasion(hall: defaultHall, meal: $0) }
        } else {
            let suggested = BerkeleyClock.suggestedMeal()
            let second: Meal = suggested == .dinner ? .lunch : .dinner
            mealOccasions = [
                MealOccasion(hall: defaultHall, meal: suggested),
                MealOccasion(hall: defaultHall, meal: second)
            ]
        }
        snackOverrides = daily.recurringFoods.map { food in
            DailySnackOverride(foodId: food.id, isEnabled: food.defaultEnabled)
        }
    }
}

// MARK: - Edit Snack Today Sheet

/// Lets the user adjust macros for a recurring food for today only.
/// An "Update default" action also persists the change back to DailyStore.
private struct EditSnackTodaySheet: View {
    let food: RecurringFood
    let override: DailySnackOverride?
    let onSave: (DailySnackOverride) -> Void
    let onUpdateDefault: (RecurringFood) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var caloriesText: String
    @State private var proteinText: String
    @State private var carbsText: String
    @State private var fatText: String

    init(food: RecurringFood, override: DailySnackOverride?,
         onSave: @escaping (DailySnackOverride) -> Void,
         onUpdateDefault: @escaping (RecurringFood) -> Void) {
        self.food            = food
        self.override        = override
        self.onSave          = onSave
        self.onUpdateDefault = onUpdateDefault
        let ov = override
        _caloriesText = State(initialValue: ov?.caloriesOverride.map { String(Int($0)) } ?? String(Int(food.calories)))
        _proteinText  = State(initialValue: ov?.proteinGOverride.map { String(Int($0)) } ?? String(Int(food.proteinG)))
        _carbsText    = State(initialValue: ov?.carbsGOverride.map   { String(Int($0)) } ?? String(Int(food.carbsG)))
        _fatText      = State(initialValue: ov?.fatGOverride.map     { String(Int($0)) } ?? String(Int(food.fatG)))
    }

    private func parse(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".")).map { max(0, $0) } ?? 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(food.servingDescription.isEmpty ? food.name : "\(food.name) — \(food.servingDescription)") {
                    macroRow(label: "Calories (kcal)", text: $caloriesText)
                    macroRow(label: "Protein (g)",     text: $proteinText)
                    macroRow(label: "Carbs (g)",        text: $carbsText)
                    macroRow(label: "Fat (g)",          text: $fatText)
                }

                Section {
                    Button("Update default too") {
                        var updated = food
                        updated.calories = parse(caloriesText)
                        updated.proteinG = parse(proteinText)
                        updated.carbsG   = parse(carbsText)
                        updated.fatG     = parse(fatText)
                        onUpdateDefault(updated)
                        saveToday(isEnabled: override?.isEnabled ?? true)
                    }
                    .foregroundStyle(CP.navy)
                } footer: {
                    Text("Updates both today's plan and the saved default for this food.")
                }
            }
            .navigationTitle("Today Only")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveToday(isEnabled: override?.isEnabled ?? true)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func macroRow(label: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField("0", text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
        }
    }

    private func saveToday(isEnabled: Bool) {
        let updated = DailySnackOverride(
            foodId:           food.id,
            isEnabled:        isEnabled,
            caloriesOverride: parse(caloriesText),
            proteinGOverride: parse(proteinText),
            carbsGOverride:   parse(carbsText),
            fatGOverride:     parse(fatText)
        )
        onSave(updated)
        dismiss()
    }
}

// MARK: - Add Item Sheet

/// Lets the user pick an extra item from the same dining-hall menu and append it to an existing combo.
private struct AddItemSheet: View {
    let request: AddItemRequest
    var planStore: PlanStore
    let goal: UserGoal?

    @State private var candidates: [MealComponent] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading items…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("No additional items available")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(candidates) { candidate in
                        Button {
                            planStore.addComponent(slotId: request.slotId,
                                                   comboId: request.comboId,
                                                   component: candidate)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: candidate.role.systemImage)
                                        .font(.caption)
                                        .foregroundStyle(CP.roleColor(candidate.role))
                                    Text(candidate.itemName)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                }
                                if let macros = candidate.macros {
                                    Text("\(Int(macros.caloriesKcal)) kcal · \(Int(macros.proteinG))g protein · \(Int(macros.carbsG))g carbs")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Add Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            candidates = await planStore.addCandidates(slotId: request.slotId,
                                                       comboId: request.comboId,
                                                       goal: goal)
            isLoading = false
        }
    }

}
