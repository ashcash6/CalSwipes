import Foundation
import os

private let recLog = Logger(subsystem: "BerkeleyPlate", category: "LocalRecommender")

// MARK: - Private helpers

private func toPlanMacros(_ m: Macros) -> PlanMacros {
    PlanMacros(caloriesKcal: m.caloriesKcal, proteinG: m.proteinG, carbsG: m.carbsG, fatG: m.fatG)
}

private struct CandidateItem {
    let item: MenuItem
    let roles: Set<FoodRole>
    let itemScore: Double
}

// MARK: - Public API

enum LocalRecommender {

    /// Build up to `topN` complete MealCombo suggestions for one meal slot.
    ///
    /// Pipeline:
    ///   1. Hard filter: allergens, unpublished, excluded IDs, accessory items, dietary-tag requirement
    ///   2. Classify each remaining item into food roles (macro + keyword)
    ///   3. Build candidate pools per role (top 8 each)
    ///   4. Generate valid multi-component combinations (protein × carb × produce)
    ///   5. Score each combination on nutrition, completeness, preference, meal-period
    ///   6. Select top-N diverse combos (≤1 shared item between any two chosen combos)
    ///   7. Optionally attach a unique substantial fat/extra to each selected combo
    static func recommend(
        from items: [MenuItem],
        meal: Meal,
        goal: UserGoal?,
        budget: PlanBudget,
        excluding: Set<String> = [],
        topN: Int = 3
    ) -> [MealCombo] {
        let blocked       = Set(goal?.allergens ?? [])
        let preferredTags = Set((goal?.dietaryTags ?? []).map { dietaryTagToBackend[$0] ?? $0 })

        // 1. Hard filter — allergens and dietary tags are both hard requirements
        let valid = items.filter { item in
            guard item.nutritionStatus == "published" else { return false }
            guard !excluding.contains(item.id) else { return false }
            guard !isAccessoryItem(item) else { return false }
            guard !item.allergens.contains(where: { blocked.contains($0) }) else { return false }
            // Dietary tags: if the user has any preferences set, every candidate must carry
            // at least one matching tag.  (Vegan/Vegetarian/Halal are hard dietary identities,
            // not soft preferences.)
            if !preferredTags.isEmpty {
                return item.dietaryTags.contains(where: { preferredTags.contains($0) })
            }
            return true
        }
        guard !valid.isEmpty else { return [] }

        // 2. Classify + score
        let candidates = valid.map { item -> CandidateItem in
            CandidateItem(item: item,
                          roles: classifyRoles(item),
                          itemScore: baseItemScore(item, preferredTags: preferredTags))
        }

        // 3. Build candidate pools
        let pools = buildPools(from: candidates, preferredTags: preferredTags, maxPerRole: 8)
        let availableRoles = Set(pools.keys.filter { !(pools[$0]?.isEmpty ?? true) })

        // 4. Generate combinations
        let rawCombos = generateCombinations(pools: pools)

        guard !rawCombos.isEmpty else {
            return fallbackSingleItem(candidates: candidates, budget: budget, meal: meal,
                                      goal: goal, availableRoles: availableRoles, topN: topN)
        }

        // 5. Score
        let scored = rawCombos
            .map { combo -> ([(FoodRole, MenuItem)], MealScoreBreakdown) in
                let bd = scoreCombination(combo, budget: budget, meal: meal,
                                          goal: goal, availableRoles: availableRoles)
                return (combo, bd)
            }
            .sorted { $0.1.final > $1.1.final }

        // 6 & 7. Diverse selection + optional extras + serving scaling
        return selectDiverse(from: scored, pools: pools, preferredTags: preferredTags,
                             budget: budget, topN: topN)
    }

    // MARK: - Swap candidates

    /// Returns items from the slot menu that can be ADDED to an existing combo (any role, not already present).
    /// Sorted by healthiness so the best options float to the top.
    static func addCandidates(
        from items: [MenuItem],
        excluding: Set<String>,
        goal: UserGoal?,
        topN: Int = 12
    ) -> [MealComponent] {
        let blocked       = Set(goal?.allergens ?? [])
        let preferredTags = Set((goal?.dietaryTags ?? []).map { dietaryTagToBackend[$0] ?? $0 })

        return items
            .filter { item in
                guard item.nutritionStatus == "published" else { return false }
                guard !excluding.contains(item.id) else { return false }
                guard !isAccessoryItem(item) else { return false }
                guard !item.allergens.contains(where: { blocked.contains($0) }) else { return false }
                if !preferredTags.isEmpty {
                    guard item.dietaryTags.contains(where: { preferredTags.contains($0) }) else { return false }
                }
                return true
            }
            .map { item -> (MenuItem, Double) in
                (item, baseItemScore(item, preferredTags: preferredTags))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(topN)
            .map { item, score in
                let roles = classifyRoles(item)
                let role = [FoodRole.protein, .carb, .produce, .fat, .other]
                    .first(where: { roles.contains($0) }) ?? .other
                return MealComponent(
                    itemId: item.id, itemName: item.name, role: role,
                    macros: item.macros.map { toPlanMacros($0) },
                    categories: item.categories, dietaryTags: item.dietaryTags,
                    itemScore: score,
                    baseServing: ComponentServing(quantity: item.serving.quantity, unit: item.serving.unit)
                )
            }
    }

    /// Returns alternative items for swapping one component role in an existing combo.
    static func swapCandidates(
        from items: [MenuItem],
        role: FoodRole,
        excluding: Set<String>,
        goal: UserGoal?,
        topN: Int = 6
    ) -> [MealComponent] {
        let blocked       = Set(goal?.allergens ?? [])
        let preferredTags = Set((goal?.dietaryTags ?? []).map { dietaryTagToBackend[$0] ?? $0 })

        return items
            .filter { item in
                guard item.nutritionStatus == "published" else { return false }
                guard !excluding.contains(item.id) else { return false }
                guard !isAccessoryItem(item) else { return false }
                guard !item.allergens.contains(where: { blocked.contains($0) }) else { return false }
                if !preferredTags.isEmpty {
                    guard item.dietaryTags.contains(where: { preferredTags.contains($0) }) else { return false }
                }
                return classifyRoles(item).contains(role)
            }
            .map { item -> (MenuItem, Double) in
                (item, rankForRole(item, role: role, preferredTags: preferredTags))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(topN)
            .map { item, score in
                MealComponent(itemId: item.id, itemName: item.name, role: role,
                              macros: item.macros.map { toPlanMacros($0) },
                              categories: item.categories,
                              dietaryTags: item.dietaryTags,
                              itemScore: score,
                              baseServing: ComponentServing(quantity: item.serving.quantity, unit: item.serving.unit))
            }
    }
}

// MARK: - Accessory Detection

extension LocalRecommender {

    /// Returns true when an item is a condiment, sauce, dressing, garnish, or beverage that
    /// should NOT occupy a primary meal-component slot.
    ///
    /// Accessory items are excluded from ALL candidate pools — they can never appear in a
    /// recommended combo, even if no better option exists.
    static func isAccessoryItem(_ item: MenuItem) -> Bool {
        let nameLC = item.name.lowercased()
        let catLC  = item.categories.joined(separator: " ").lowercased()
        let unit   = item.serving.unit.lowercased()

        // Condiment-sized serving unit (tbsp, tsp, packet) → accessory
        let condimentUnits = ["tbsp", "tablespoon", "tsp", "teaspoon", "packet", "sachet", "oz packet"]
        if condimentUnits.contains(where: { unit == $0 || unit.hasPrefix($0) }) { return true }

        // Category explicitly marks item as a condiment or dressing
        if catLC.contains("condiment") || catLC.contains("dressing") { return true }

        // Name-based: unambiguous accessory keywords
        let accessoryKeywords: [String] = [
            // Dressings
            " dressing", "vinaigrette", "ranch ", "ranch\n",
            // Vinegars — always a condiment, never a meal component
            "vinegar",
            // Sauces & condiments
            "ketchup", "mustard", "mayonnaise", " mayo",
            "hot sauce", "sriracha", "tabasco", "soy sauce", "teriyaki sauce",
            "oyster sauce", "fish sauce", "worcestershire", "hoisin sauce",
            "bbq sauce", "barbecue sauce", "buffalo sauce",
            " glaze", " marinade", " drizzle",
            // Spreads / small servings
            "butter pat", "margarine pat", "jam ", "jelly ", "jam\n", "jelly\n",
            "peanut butter packet", "almond butter packet",
            "maple syrup", "syrup ",
            "cream cheese cup", "cream cheese packet", "cream cheese spread",
            "whipped cream", "cool whip", "whipped topping",
            "sour cream cup", "sour cream packet",
            "half and half",
            // Gravies
            " gravy", "au jus",
            // Other condiments
            "salsa ", "relish", "chutney", "pickle",
            "hot honey", "honey packet",
            "sugar packet", "splenda", "stevia packet",
            // Beverages
            "juice box", "juice carton", "soda", "lemonade",
            "water bottle", "sparkling water",
            "coffee cup", "tea bag", "milk carton",
        ]
        if accessoryKeywords.contains(where: { nameLC.contains($0) }) { return true }

        // Cooking oils and liquid fats — never a primary meal component
        let oilKeywords = [
            "olive oil", "vegetable oil", "canola oil", "sunflower oil", "corn oil",
            "sesame oil", "coconut oil", "oil spray", "cooking spray", "avocado oil",
            "butter spray", "pan spray", "non-stick spray"
        ]
        if oilKeywords.contains(where: { nameLC.contains($0) }) { return true }

        // Standalone oil or sauce serving (e.g. "Olive Oil, 1 tbsp")
        if nameLC.hasSuffix(" oil") || nameLC.hasSuffix(" sauce") { return true }

        // Macro-based traps
        if let m = item.macros {
            // Truly negligible serving — vinegar packets, spice sachets, hot sauce: < 15 kcal.
            // Vegetables (even leafy greens) always exceed this at a real serving size.
            if m.caloriesKcal < 15 && m.proteinG < 1 && m.carbsG < 3 { return true }

            // Tiny calorie + high fat percentage = liquid dressing or oil drizzle
            if m.caloriesKcal > 0 {
                let fatCalRatio = (m.fatG * 9) / m.caloriesKcal
                if m.caloriesKcal < 40 && fatCalRatio > 0.75 { return true }
            }
        }

        return false
    }
}

// MARK: - Role Classification

extension LocalRecommender {

    /// Classify an item into one or more food roles.
    ///
    /// An item can fill multiple roles (beans → protein + carb; eggs → protein + fat).
    /// The same item never appears twice in one combo — duplicate-ID combos are skipped.
    static func classifyRoles(_ item: MenuItem) -> Set<FoodRole> {
        let nameLC   = item.name.lowercased()
        let catLC    = item.categories.joined(separator: " ").lowercased()
        let combined = nameLC + " " + catLC

        var roles = Set<FoodRole>()

        // Macro-based classification
        if let m = item.macros {
            let cal          = max(m.caloriesKcal, 1.0)
            let proteinRatio = (m.proteinG * 4) / cal
            let carbRatio    = (m.carbsG   * 4) / cal
            let fatRatio     = (m.fatG     * 9) / cal

            if proteinRatio >= 0.20 && m.proteinG >= 8               { roles.insert(.protein) }
            if carbRatio    >= 0.45 && m.carbsG   >= 20
               && fatRatio  < 0.40                                    { roles.insert(.carb) }
            // Fat: only SUBSTANTIAL fat sources (avocado, nuts, cheese), not condiment-sized
            if fatRatio     >= 0.45 && m.fatG     >= 5
               && m.caloriesKcal >= 60                                // excludes tiny condiment portions
               && proteinRatio < 0.40                                  { roles.insert(.fat) }
            if cal < 150 && m.proteinG < 12 && m.fatG < 12
               && !roles.contains(.protein)                           { roles.insert(.produce) }
        }

        // Keyword-based classification
        let proteinWords: [String] = [
            "chicken", "beef", "bison", "fish", "salmon", "tuna", "tilapia", "cod", "halibut",
            "shrimp", "prawn", "scallop", "turkey", "pork", "lamb", "duck", "venison",
            "tofu", "tempeh", "seitan", "egg", "eggs",
            "bean", "beans", "lentil", "lentils", "chickpea", "chickpeas", "edamame",
            "cottage cheese", "ricotta", "hemp seed"
        ]
        let carbWords: [String] = [
            "rice", "pasta", "spaghetti", "fettuccine", "penne", "rigatoni", "noodle",
            "bread", "roll ", "tortilla", "bagel", "pita ", "wrap",
            "potato", "potatoes", "fries", "mashed", "sweet potato", "yam",
            "quinoa", "oat", "oatmeal", "cereal", "granola", "muffin", "pancake", "waffle",
            "couscous", "farro", "polenta", "barley", "bulgur", "grits", "grain", "grains",
            "cornbread", "crouton", "hashbrown", "hash brown"
        ]
        let produceWords: [String] = [
            "salad", "vegetable", "vegetables", "veggie", "veggies",
            "broccoli", "spinach", "kale", "lettuce", "arugula", "chard", "collard",
            "tomato", "tomatoes", "carrot", "carrots", "cucumber", "pepper", "bell pepper",
            "zucchini", "squash", "asparagus", "mushroom", "onion", "leek",
            "corn", "pea", "peas", "snap pea", "green bean",
            "cauliflower", "cabbage", "bok choy", "beet", "beets", "radish", "artichoke",
            "apple", "orange", "banana", "berry", "berries", "strawberr", "blueberr", "raspberr",
            "melon", "pear", "peach", "grape", "mango", "pineapple", "watermelon",
            "fruit", "fruits", "citrus", "grapefruit", "cantaloupe"
        ]
        // Substantial fat sources only — no dressings or condiments
        let substantialFatWords: [String] = [
            "avocado", "guacamole", "hummus",
            "peanut butter", "almond butter", "nut butter",
            "almonds", "walnuts", "cashews", "pecans", "pistachios", "mixed nuts",
            "cheddar", "mozzarella", "parmesan", "feta", "brie", "gouda",
            "cottage cheese", "ricotta",
            "tahini", "coconut"
        ]

        if proteinWords.contains(where:       { combined.contains($0) }) { roles.insert(.protein) }
        if carbWords.contains(where:          { combined.contains($0) }) { roles.insert(.carb)    }
        if produceWords.contains(where:       { combined.contains($0) }) { roles.insert(.produce) }
        if substantialFatWords.contains(where:{ combined.contains($0) }) { roles.insert(.fat)     }

        // Category-string hints
        if catLC.contains("grain") || catLC.contains("starch")  { roles.insert(.carb)    }
        if catLC.contains("salad") || catLC.contains("produce")  { roles.insert(.produce) }
        if catLC.contains("dairy") || catLC.contains("cheese")   { roles.insert(.fat)     }
        if catLC.contains("protein") || catLC.contains("entree") || catLC.contains("main") {
            roles.insert(.protein)
        }

        if roles.isEmpty { roles.insert(.other) }
        return roles
    }

    static func baseItemScore(_ item: MenuItem, preferredTags: Set<String>) -> Double {
        var score = healthinessBoost(item)
        if item.macros == nil { score *= 0.80 }
        if !preferredTags.isEmpty
            && item.dietaryTags.contains(where: { preferredTags.contains($0) }) {
            score *= 1.10
        }
        return score
    }

    /// Multiplier that nudges the pool ranking toward nutritionally better choices.
    private static func healthinessBoost(_ item: MenuItem) -> Double {
        let name = item.name.lowercased()
        var boost = 1.0

        // Penalise clearly unhealthy items so they surface only as last resort
        let unhealthyTerms = [
            "fried", "deep fried", "crispy fried", "tempura",
            "cake", "cookie", "brownie", "donut", "doughnut",
            "ice cream", "pudding", " pie", "pastry", "cobbler",
            "mac and cheese", "cheese sauce", "alfredo sauce", "cream sauce",
        ]
        if unhealthyTerms.contains(where: { name.contains($0) }) { boost *= 0.50 }

        // Boost lean protein sources
        let leanProteins = [
            "chicken breast", "turkey breast", "salmon", "tuna",
            "egg white", "tofu", "tempeh", "lentil", "edamame",
        ]
        if leanProteins.contains(where: { name.contains($0) }) { boost *= 1.40 }

        // Boost whole-grain carbs over refined
        let wholeGrains = [
            "brown rice", "quinoa", "whole wheat", "whole grain",
            "farro", "barley", "oat", "bulgur",
        ]
        if wholeGrains.contains(where: { name.contains($0) }) { boost *= 1.20 }

        return boost
    }

    static func rankForRole(_ item: MenuItem, role: FoodRole, preferredTags: Set<String>) -> Double {
        var score = baseItemScore(item, preferredTags: preferredTags)
        guard let m = item.macros else { return score }

        let cal          = max(m.caloriesKcal, 1.0)
        let proteinRatio = (m.proteinG * 4) / cal
        let carbRatio    = (m.carbsG   * 4) / cal
        let fatRatio     = (m.fatG     * 9) / cal

        switch role {
        case .protein:
            score *= min(2.0, 0.5 + proteinRatio * 2.0)
            score *= min(1.5, 0.8 + m.proteinG / 40.0)
        case .carb:
            score *= carbRatio
            score *= max(0.4, 1.0 - fatRatio)
        case .produce:
            let density = m.caloriesKcal / 200.0
            score *= max(0.2, 1.0 - density)
        case .fat:
            score *= fatRatio
        case .other:
            break
        }
        return score
    }
}

// MARK: - Pool Building

extension LocalRecommender {

    private static func buildPools(
        from candidates: [CandidateItem],
        preferredTags: Set<String>,
        maxPerRole: Int
    ) -> [FoodRole: [CandidateItem]] {
        var pools: [FoodRole: [CandidateItem]] = [:]
        for role in FoodRole.allCases {
            let matching = candidates
                .filter { $0.roles.contains(role) }
                .sorted {
                    rankForRole($0.item, role: role, preferredTags: preferredTags) >
                    rankForRole($1.item, role: role, preferredTags: preferredTags)
                }
            if !matching.isEmpty {
                pools[role] = Array(matching.prefix(maxPerRole))
            }
        }
        return pools
    }
}

// MARK: - Combination Generation

extension LocalRecommender {

    private static func generateCombinations(
        pools: [FoodRole: [CandidateItem]]
    ) -> [[(FoodRole, MenuItem)]] {
        let proteinPool = pools[.protein] ?? []
        let carbPool    = pools[.carb]    ?? []
        let producePool = pools[.produce] ?? []

        let hasProtein = !proteinPool.isEmpty
        let hasCarb    = !carbPool.isEmpty
        let hasProduce = !producePool.isEmpty

        var combos: [[(FoodRole, MenuItem)]] = []

        // Full three-role combos (preferred)
        if hasProtein && hasCarb && hasProduce {
            for p in proteinPool {
                for c in carbPool {
                    guard c.item.id != p.item.id else { continue }
                    for v in producePool {
                        guard v.item.id != p.item.id, v.item.id != c.item.id else { continue }
                        combos.append([(.protein, p.item), (.carb, c.item), (.produce, v.item)])
                    }
                }
            }
            return combos
        }

        // Two-role fallbacks — only include meaningful categories, never fill a missing slot with an accessory
        if hasProtein && hasCarb {
            for p in proteinPool { for c in carbPool where c.item.id != p.item.id {
                combos.append([(.protein, p.item), (.carb, c.item)])
            }}
        }
        if hasProtein && hasProduce {
            for p in proteinPool { for v in producePool where v.item.id != p.item.id {
                combos.append([(.protein, p.item), (.produce, v.item)])
            }}
        }
        if hasCarb && hasProduce {
            for c in carbPool { for v in producePool where v.item.id != c.item.id {
                combos.append([(.carb, c.item), (.produce, v.item)])
            }}
        }
        return combos
    }

    private static func fallbackSingleItem(
        candidates: [CandidateItem],
        budget: PlanBudget,
        meal: Meal,
        goal: UserGoal?,
        availableRoles: Set<FoodRole>,
        topN: Int
    ) -> [MealCombo] {
        return candidates
            .sorted { $0.itemScore > $1.itemScore }
            .prefix(topN)
            .map { candidate in
                let role = candidate.roles.sorted(by: { $0.rawValue < $1.rawValue }).first ?? .other
                let comp = MealComponent(
                    itemId: candidate.item.id, itemName: candidate.item.name, role: role,
                    macros: candidate.item.macros.map { toPlanMacros($0) },
                    categories: candidate.item.categories, dietaryTags: candidate.item.dietaryTags,
                    itemScore: candidate.itemScore,
                    baseServing: ComponentServing(quantity: candidate.item.serving.quantity, unit: candidate.item.serving.unit)
                )
                let bd = MealScoreBreakdown(nutritionScore: 50, completenessScore: 25,
                                            preferenceScore: 50, mealPeriodScore: 50, varietyScore: 100)
                return MealCombo(id: UUID().uuidString, components: [comp], scoreBreakdown: bd)
            }
    }
}

// MARK: - Scoring

extension LocalRecommender {

    private static func scoreCombination(
        _ combo: [(FoodRole, MenuItem)],
        budget: PlanBudget,
        meal: Meal,
        goal: UserGoal?,
        availableRoles: Set<FoodRole>
    ) -> MealScoreBreakdown {
        let totalCal = combo.compactMap { $0.1.macros?.caloriesKcal }.reduce(0, +)
        let totalPro = combo.compactMap { $0.1.macros?.proteinG     }.reduce(0, +)

        // Nutrition score
        let targetCal = max(budget.caloriesKcal, 50.0)
        let targetPro = max(budget.proteinG, 5.0)

        let calRatio  = totalCal / targetCal
        let calScore: Double
        if totalCal == 0         { calScore = 20 }
        else if calRatio <= 1.0  { calScore = calRatio * 100 }
        else                     { calScore = max(0, 100 - (calRatio - 1.0) * 200) }

        let proRatio  = totalPro / targetPro
        let proScore: Double
        if totalPro == 0         { proScore = 20 }
        else if proRatio <= 1.0  { proScore = proRatio * 100 }
        else                     { proScore = max(0, 100 - (proRatio - 1.0) * 150) }

        let hasMacroData    = combo.contains { $0.1.macros != nil }
        let nutritionScore  = hasMacroData ? (calScore * 0.6 + proScore * 0.4) : 40.0

        // Completeness score
        let presentRoles      = Set(combo.map(\.0))
        var completeness      = 100.0
        let roleWeights: [(FoodRole, Double)] = [(.protein, 40), (.carb, 35), (.produce, 25)]
        for (role, weight) in roleWeights where availableRoles.contains(role) {
            if !presentRoles.contains(role) { completeness -= weight }
        }
        let completenessScore = max(0, completeness)

        // Preference score
        let preferredTags = Set((goal?.dietaryTags ?? []).map { dietaryTagToBackend[$0] ?? $0 })
        let preferenceScore: Double = preferredTags.isEmpty ? 70.0 : {
            let matchCount = combo.filter { _, item in
                item.dietaryTags.contains(where: { preferredTags.contains($0) })
            }.count
            return Double(matchCount) / Double(combo.count) * 100
        }()

        let mealPeriodScore = mealPeriodFit(combo: combo, meal: meal)

        return MealScoreBreakdown(
            nutritionScore:    nutritionScore.rounded(),
            completenessScore: completenessScore.rounded(),
            preferenceScore:   preferenceScore.rounded(),
            mealPeriodScore:   mealPeriodScore.rounded(),
            varietyScore:      100
        )
    }

    private static func mealPeriodFit(combo: [(FoodRole, MenuItem)], meal: Meal) -> Double {
        let names = combo.map { $0.1.name.lowercased() }.joined(separator: " ")
        switch meal {
        case .breakfast, .brunch:
            let bWords = ["egg", "oat", "pancake", "waffle", "toast", "yogurt",
                          "cereal", "granola", "fruit", "bacon", "sausage", "muffin", "bagel", "parfait"]
            let dWords = ["steak", "burger", "curry", "stew", "roast", "braised",
                          "meatball", "lasagna", "enchilada", "risotto"]
            let hasBreakfast = bWords.contains { names.contains($0) }
            let hasDinner    = dWords.contains { names.contains($0) }
            if hasBreakfast && !hasDinner { return 100 }
            if hasDinner                  { return 30  }
            return 65
        case .lunch, .allDay:
            return 75
        case .dinner, .lateNight:
            let lightWords = ["cereal", "oatmeal", "pancake", "waffle"]
            return lightWords.contains { names.contains($0) } ? 50 : 80
        }
    }
}

// MARK: - Diverse Selection

extension LocalRecommender {

    private static func selectDiverse(
        from scored: [([(FoodRole, MenuItem)], MealScoreBreakdown)],
        pools: [FoodRole: [CandidateItem]],
        preferredTags: Set<String>,
        budget: PlanBudget,
        topN: Int
    ) -> [MealCombo] {
        var selected: [([(FoodRole, MenuItem)], MealScoreBreakdown)] = []
        var usedItemIds = Set<String>()

        for (combo, breakdown) in scored {
            guard selected.count < topN else { break }
            let ids    = Set(combo.map { $0.1.id })
            let shared = ids.intersection(usedItemIds).count
            guard selected.isEmpty || shared <= 1 else { continue }
            let varietyScore = shared == 0 ? 100.0 : 60.0
            let updated = MealScoreBreakdown(
                nutritionScore: breakdown.nutritionScore, completenessScore: breakdown.completenessScore,
                preferenceScore: breakdown.preferenceScore, mealPeriodScore: breakdown.mealPeriodScore,
                varietyScore: varietyScore
            )
            selected.append((combo, updated))
            usedItemIds.formUnion(ids)
        }

        // Relax constraint if we couldn't fill topN
        if selected.count < topN {
            for (combo, breakdown) in scored {
                guard selected.count < topN else { break }
                let ids = Set(combo.map { $0.1.id })
                let alreadyChosen = selected.contains { Set($0.0.map { $0.1.id }) == ids }
                if !alreadyChosen { selected.append((combo, breakdown)) }
            }
        }

        return selected.enumerated().map { index, pair in
            let (combo, breakdown) = pair
            let finalCombo = combo

            // Scale protein items to fill the per-slot calorie/protein budget.
            let servingMap = computeServings(combo: finalCombo, budget: budget)

            let components = finalCombo.map { role, item -> MealComponent in
                let count = Double(servingMap[item.id] ?? 1)
                let baseMacros = item.macros.map { toPlanMacros($0) }
                let scaledMacros = baseMacros.map { m in
                    PlanMacros(
                        caloriesKcal: m.caloriesKcal * count,
                        proteinG:     m.proteinG     * count,
                        carbsG:       m.carbsG       * count,
                        fatG:         m.fatG         * count
                    )
                }
                let score = pools[role]?.first(where: { $0.item.id == item.id })?.itemScore
                    ?? baseItemScore(item, preferredTags: preferredTags)
                return MealComponent(
                    itemId: item.id, itemName: item.name, role: role,
                    macros: scaledMacros,
                    categories: item.categories, dietaryTags: item.dietaryTags,
                    itemScore: score, servingCount: count,
                    baseServing: ComponentServing(quantity: item.serving.quantity, unit: item.serving.unit)
                )
            }

            recLog.debug("Option \(index + 1): \(components.map { $0.servingCount > 1 ? "\($0.itemName) ×\($0.servingCount)" : $0.itemName }.joined(separator: " + "))")
            recLog.debug("  \(breakdown.debugDescription)")

            return MealCombo(id: UUID().uuidString, components: components, scoreBreakdown: breakdown)
        }
    }

    /// Compute how many servings of each item to recommend, scaled to fill the budget.
    ///
    /// Protein items scale to hit both the protein target AND the calorie budget.
    /// Carb items scale up to 2× in a second pass when the meal is still well under budget.
    /// Ceiling: total meal must not exceed 1.25× budget. Max 4× per protein item.
    private static func computeServings(
        combo: [(FoodRole, MenuItem)],
        budget: PlanBudget
    ) -> [String: Int] {
        var result = [String: Int]()
        guard budget.proteinG > 5, budget.caloriesKcal > 50 else { return result }

        let nonProteinCal = combo
            .filter { $0.0 != .protein }
            .compactMap { $0.1.macros?.caloriesKcal }
            .reduce(0, +)
        let nonProteinPro = combo
            .filter { $0.0 != .protein }
            .compactMap { $0.1.macros?.proteinG }
            .reduce(0, +)

        for (role, item) in combo where role == .protein {
            guard let m = item.macros, m.proteinG > 0, m.caloriesKcal > 0 else {
                result[item.id] = 1
                continue
            }

            let remainingPro = max(0, budget.proteinG - nonProteinPro)
            // Hard ceiling: total meal must not exceed 1.25× the full budget (not just the protein slot)
            let maxForCals   = max(1, Int(floor((budget.caloriesKcal * 1.25 - nonProteinCal) / m.caloriesKcal)))
            // Minimum to hit protein target
            let idealForPro  = max(1, Int(ceil(remainingPro / m.proteinG)))
            // Minimum to reach 85% of calorie budget (protein is the right macro to add more of)
            let idealForCals = max(1, Int(ceil((budget.caloriesKcal * 0.85 - nonProteinCal) / m.caloriesKcal)))

            result[item.id] = max(1, min(4, min(maxForCals, max(idealForPro, idealForCals))))
        }

        // Second pass: scale one carb item up to 2× if the meal is still well under budget.
        let proteinCalTotal = combo
            .filter { $0.0 == .protein }
            .reduce(0.0) { total, pair in
                guard let m = pair.1.macros else { return total }
                return total + m.caloriesKcal * Double(result[pair.1.id] ?? 1)
            }
        let totalAfterProtein = nonProteinCal + proteinCalTotal

        if totalAfterProtein < budget.caloriesKcal * 0.80 {
            let calGap = budget.caloriesKcal - totalAfterProtein
            for (role, item) in combo where role == .carb {
                guard let m = item.macros, m.caloriesKcal > 0 else { continue }
                let extra = min(1, Int(round(calGap / m.caloriesKcal)))
                if extra >= 1 { result[item.id] = 1 + extra }
                break  // scale at most one carb item per combo
            }
        }

        return result
    }
}
