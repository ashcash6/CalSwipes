import Foundation

/// Menus + goal captured for one assistant request. A plain value type, so it's Sendable and
/// can be handed to Foundation Models tools that run off the main actor.
struct MenuSnapshot: Sendable {
    var menus: [String: MenuEnvelope]   // key: "<hall>|<meal>"
    var goal: UserGoal?
    var todayCalories: Double
    var defaultHall: Hall
    var availableMeals: [Meal]

    static func key(_ hall: Hall, _ meal: Meal) -> String { "\(hall.rawValue)|\(meal.rawValue)" }
    func menu(_ hall: Hall, _ meal: Meal) -> MenuEnvelope? { menus[Self.key(hall, meal)] }
}

/// Tier 1: deterministic answers from cached menus + LocalRecommender. No AI, no network.
/// Also the implementation behind the on-device model's tools (Tier 2).
enum LocalAssistantEngine {

    // MARK: Budgets (same rule as MakeMealSheet / MenuScreen: one-third of the day, capped by what's left)

    static func mealBudget(goal: UserGoal?, todayCalories: Double, fraction: Double = 1.0 / 3.0) -> PlanBudget {
        let goalCal  = goal?.targetCalories ?? 2100
        let goalPro  = goal?.targetProteinG ?? 130
        let goalCarb = goal?.targetCarbsG   ?? 250
        let goalFat  = goal?.targetFatG     ?? 65
        let remaining = max(0, goalCal - todayCalories)
        let mealCal   = max(100, min(remaining, goalCal * fraction))
        let f         = goalCal > 0 ? mealCal / goalCal : fraction
        return PlanBudget(caloriesKcal: mealCal, proteinG: max(10, goalPro * f),
                          carbsG: max(20, goalCarb * f), fatG: max(5, goalFat * f))
    }

    static func fullDayBudget(goal: UserGoal?) -> PlanBudget {
        PlanBudget(caloriesKcal: (goal?.targetCalories ?? 2100) / 3, proteinG: (goal?.targetProteinG ?? 130) / 3,
                   carbsG: (goal?.targetCarbsG ?? 250) / 3, fatG: (goal?.targetFatG ?? 65) / 3)
    }

    // MARK: Building blocks

    /// Published items that are real food and don't contain the user's allergens.
    static func eligibleItems(_ menu: MenuEnvelope, goal: UserGoal?) -> [MenuItem] {
        let blocked = Set(goal?.allergens ?? [])
        return menu.items.filter { item in
            item.nutritionStatus == "published" && item.macros != nil
                && !LocalRecommender.isAccessoryItem(item)
                && !item.allergens.contains(where: { blocked.contains($0) })
        }
    }

    static func searchMenu(_ snap: MenuSnapshot, query: String, hall: Hall?, meal: Meal?, limit: Int = 8) -> [(Hall, Meal, MenuItem)] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        var out: [(Hall, Meal, MenuItem)] = []
        for (_, menu) in snap.menus where (hall == nil || menu.hall == hall) && (meal == nil || menu.meal == meal) {
            for item in eligibleItems(menu, goal: snap.goal)
            where q.isEmpty || item.name.lowercased().contains(q)
                || item.categories.contains(where: { $0.lowercased().contains(q) })
                || item.dietaryTags.contains(where: { $0.lowercased().contains(q) }) {
                out.append((menu.hall, menu.meal, item))
            }
        }
        return Array(out.sorted { ($0.2.macros?.proteinG ?? 0) > ($1.2.macros?.proteinG ?? 0) }.prefix(limit))
    }

    static func bestCombo(_ snap: MenuSnapshot, hall: Hall, meal: Meal, budget: PlanBudget) -> MealCombo? {
        guard let menu = snap.menu(hall, meal), menu.status == "published" else { return nil }
        return LocalRecommender.recommend(from: menu.items, meal: meal, goal: snap.goal, budget: budget,
                                          excluding: [], topN: 1, fixedPortions: !hall.isDiningHall).first
    }

    static func describe(_ combo: MealCombo) -> String {
        let items = combo.components.map { c in
            let n = c.servingCount.formatted(.number.precision(.fractionLength(0...2)))
            return n == "1" ? c.itemName : "\(c.itemName) ×\(n)"
        }.joined(separator: ", ")
        let t = combo.totalMacros
        return "\(items) (\(Int(t.caloriesKcal)) kcal, \(Int(t.proteinG))g protein)"
    }

    // MARK: Quick actions

    static func answer(_ action: QuickAction, snap: MenuSnapshot, now: Date = Date()) -> String {
        switch action {
        case .bestProtein(let hall):
            let meal = BerkeleyClock.closestMeal(to: BerkeleyClock.suggestedMeal(now), among: snap.availableMeals)
            let hits = searchMenu(snap, query: "", hall: hall, meal: meal, limit: 5)
            guard !hits.isEmpty else { return "I don't have \(hall.title)'s \(meal.title.lowercased()) menu loaded yet. Open the Menu tab once and try again." }
            let lines = hits.map { _, _, i in
                "• \(i.name): \(Int(i.macros?.proteinG ?? 0))g protein, \(Int(i.macros?.caloriesKcal ?? 0)) kcal per \(i.serving.label)"
            }
            return "Highest protein at \(hall.title) for \(meal.title.lowercased()):\n" + lines.joined(separator: "\n")

        case .suggestMeal(let hall, let meal):
            let budget = mealBudget(goal: snap.goal, todayCalories: snap.todayCalories)
            guard let combo = bestCombo(snap, hall: hall, meal: meal, budget: budget) else {
                return "No published \(meal.title.lowercased()) menu at \(hall.title) right now."
            }
            return "For about \(Int(budget.caloriesKcal)) kcal at \(hall.title): \(describe(combo))."

        case .planMyDay(let hall):
            let budget = fullDayBudget(goal: snap.goal)
            var lines: [String] = []
            var total = PlanMacros.zero
            for meal in [Meal.breakfast, .lunch, .dinner] {
                if let combo = bestCombo(snap, hall: hall, meal: meal, budget: budget) {
                    lines.append("\(meal.title): \(describe(combo))")
                    total = total + combo.totalMacros
                } else {
                    lines.append("\(meal.title): no published menu at \(hall.title)")
                }
            }
            let target = Int(snap.goal?.targetCalories ?? 2100)
            return "Day plan at \(hall.title):\n" + lines.joined(separator: "\n")
                + "\nTotal \(Int(total.caloriesKcal)) of \(target) kcal, \(Int(total.proteinG))g protein. Open the Plan tab to save and tweak it."

        case .whatsOpenNow:
            let natural = BerkeleyClock.suggestedMeal(now)
            let meal = BerkeleyClock.closestMeal(to: natural, among: snap.availableMeals)
            let halls = Hall.allCases.filter(\.isDiningHall).filter { snap.menu($0, meal)?.status == "published" }
            let where_ = halls.isEmpty ? "No hall menus are loaded yet." : "Published menus: \(halls.map(\.title).joined(separator: ", "))."
            return "It's \(meal.title.lowercased()) time (usually \(meal.typicalHours)). \(where_) Hours vary by hall and day, so check Berkeley Dining before walking over."

        case .scanTray:
            return "Take a photo of your tray and I'll match it to today's menu."
        }
    }

    /// Cheap keyword mapping from free text to a chip, used when on-device AI isn't available.
    static func quickAction(for text: String, defaultHall: Hall, now: Date = Date()) -> QuickAction? {
        let t = text.lowercased()
        let hall = Hall.allCases.first { t.contains($0.title.lowercased()) || t.contains($0.rawValue.replacingOccurrences(of: "-", with: " ")) } ?? defaultHall
        let meal = Meal.allCases.first { t.contains($0.title.lowercased()) }
        if t.contains("plan") && t.contains("day") { return .planMyDay(hall) }
        if t.contains("open") || t.contains("what time") || t.contains("hours") { return .whatsOpenNow }
        if t.contains("protein") && !t.contains("allerg") { return .bestProtein(hall) }
        if t.contains("suggest") || t.contains("what should i eat") || t.contains("make me") {
            return .suggestMeal(hall, meal ?? BerkeleyClock.suggestedMeal(now))
        }
        if t.contains("scan") || t.contains("tray") || t.contains("photo") { return .scanTray }
        return nil
    }
}
