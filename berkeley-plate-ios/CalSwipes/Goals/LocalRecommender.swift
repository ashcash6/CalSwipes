import Foundation
import os

private let recLog = Logger(subsystem: "CalSwipes", category: "LocalRecommender")

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
        topN: Int = 3,
        fixedPortions: Bool = false
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

        // Non-dining-hall venues (cafés, markets): serve one fixed dish per order — no combinations.
        // Skip pool-building and combo generation entirely; just pick the best single item per profile.
        if fixedPortions {
            return selectBestSingleItems(from: candidates, budget: budget,
                                         preferredTags: preferredTags, topN: topN)
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

        // 5-7. Weighted portion optimization + diverse selection across 3 objective profiles
        return selectDiverse(from: rawCombos, pools: pools, preferredTags: preferredTags,
                             budget: budget, topN: topN, fixedPortions: fixedPortions)
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

    /// Re-runs portion optimisation for an already-assembled combo — call this after a component swap.
    ///
    /// - Parameter profileIndex: 0 = Best Match, 1 = High Protein, 2 = High Carb
    static func optimizeCombo(
        _ items: [(FoodRole, MenuItem)],
        budget: PlanBudget,
        profileIndex: Int
    ) -> MealCombo {
        let profiles: [ObjectiveWeights] = [.bestMatch, .highProtein, .highCarb]
        let weights = profiles[min(profileIndex, profiles.count - 1)]
        let effectiveBudget: PlanBudget
        switch profileIndex {
        case 1:
            effectiveBudget = PlanBudget(caloriesKcal: budget.caloriesKcal,
                                          proteinG: budget.proteinG * 1.5,
                                          carbsG:   budget.carbsG   * 0.5, fatG: budget.fatG)
        case 2:
            effectiveBudget = PlanBudget(caloriesKcal: budget.caloriesKcal,
                                          proteinG: budget.proteinG * 0.7,
                                          carbsG:   budget.carbsG   * 1.5, fatG: budget.fatG)
        default:
            effectiveBudget = budget
        }
        let (portions, score, _) = findBestPortions(combo: items, budget: effectiveBudget,
                                                     weights: weights, profileIndex: profileIndex)
        let components = items.map { role, item -> MealComponent in
            let count = portions[item.id] ?? 1.0
            let scaled = item.macros.map { m in
                PlanMacros(caloriesKcal: m.caloriesKcal * count, proteinG: m.proteinG * count,
                           carbsG: m.carbsG * count, fatG: m.fatG * count)
            }
            return MealComponent(
                itemId: item.id, itemName: item.name, role: role, macros: scaled,
                categories: item.categories, dietaryTags: item.dietaryTags,
                itemScore: 0, servingCount: count,
                baseServing: ComponentServing(quantity: item.serving.quantity, unit: item.serving.unit))
        }
        let breakdown = MealScoreBreakdown(
            nutritionScore: max(0, min(100, (1.0 - score) * 100)).rounded(),
            completenessScore: Double(items.count) / 3.0 * 100,
            preferenceScore: 70, mealPeriodScore: 70, varietyScore: 70
        )
        return MealCombo(id: UUID().uuidString, components: components, scoreBreakdown: breakdown)
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
            "cottage cheese", "ricotta", "hemp seed",
            "yogurt", "greek yogurt", "kefir", "quark",
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
        // Only grant carb role via keywords when the item isn't fat-dominant (≥50% fat calories).
        // This prevents items like nut butters from landing in the carb pool solely because
        // they're co-located with bagels/bread at the dining station.
        let fatDominant = (item.macros.map { ($0.fatG * 9) / max($0.caloriesKcal, 1) } ?? 0) >= 0.50
        if !fatDominant && carbWords.contains(where: { combined.contains($0) }) { roles.insert(.carb) }
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

// MARK: - Diverse Selection (Weighted Whole-Meal Optimizer)

extension LocalRecommender {

    // Objective weights for 3 suggestion profiles.
    // These are error contribution weights — lower total weighted error = better meal.
    // Each profile sums to 1.0.
    private struct ObjectiveWeights {
        let cal: Double
        let pro: Double
        let carb: Double
        let fat: Double

        // Option 1: Best Match — calorie and protein equally weighted
        static let bestMatch   = ObjectiveWeights(cal: 0.35, pro: 0.35, carb: 0.20, fat: 0.10)
        // Option 2: High Protein — protein reward is dominant; calorie accuracy is relaxed because
        // protein sources are calorie-dense and we genuinely want the user to eat more protein.
        static let highProtein = ObjectiveWeights(cal: 0.10, pro: 0.65, carb: 0.15, fat: 0.10)
        // Option 3: High Carb — carb accuracy elevated for energy-focused meals
        static let highCarb    = ObjectiveWeights(cal: 0.30, pro: 0.20, carb: 0.40, fat: 0.10)
    }

    // Portion multiplier ranges per food role, per objective profile.
    // Ascending order is required — the grid search breaks early once the calorie cap is exceeded.
    private static func allowedPortions(for role: FoodRole, profileIndex: Int) -> [Double] {
        switch role {
        case .protein:
            if profileIndex == 1 { return [0.75, 1.0, 1.5, 2.0, 2.5, 3.0] } // High Protein: max meat
            if profileIndex == 2 { return [0.5, 0.75, 1.0] }                 // High Carb: cap protein
            return [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        case .carb:
            if profileIndex == 1 { return [0.5, 0.75, 1.0] }                 // High Protein: cap carbs
            if profileIndex == 2 { return [0.75, 1.0, 1.5, 2.0, 2.5, 3.0] } // High Carb: max carbs
            return [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        case .produce:
            if profileIndex == 1 { return [0.5, 1.0] }                       // High Protein: small veg
            return [0.5, 1.0, 1.5, 2.0]
        case .fat:
            return [0.25, 0.5, 0.75, 1.0, 1.25, 1.5]
        case .other:
            return [1.0]
        }
    }

    /// Per-component debug breakdown — logged to Xcode Console, never shown in UI.
    private struct ScoreDetail {
        let calErr: Double;  let proErr: Double;  let carbErr: Double;  let fatErr: Double
        let calPenalty: Double;  let proPenalty: Double
        let fatPenalty: Double;  let proteinSanityPenalty: Double
        let efficiencyBonus: Double;  let finalScore: Double
    }

    /// Grid-search over per-item portion multipliers.
    ///
    /// Finds the portion combination that minimises the weighted macro error for the given objective.
    /// Score is LOWER = BETTER (0.0 = perfect match). Explicit penalties push the score above the
    /// base weighted error. Hard prune at 1.35× calorie cap prevents runaway combinations.
    private static func findBestPortions(
        combo: [(FoodRole, MenuItem)],
        budget: PlanBudget,
        weights: ObjectiveWeights,
        profileIndex: Int = 0,
        fixedPortions: Bool = false
    ) -> (portions: [String: Double], score: Double, detail: ScoreDetail?) {

        // Non-dining-hall venues: every item is served in a fixed single portion.
        // Skip the grid search entirely and evaluate the combo at 1× for everything.
        if fixedPortions {
            let fixed = Dictionary(uniqueKeysWithValues: combo.map { ($0.1.id, 1.0) })
            var fCal = 0.0, fPro = 0.0, fCarb = 0.0, fFat = 0.0
            for (_, item) in combo {
                fCal  += item.macros?.caloriesKcal ?? 0
                fPro  += item.macros?.proteinG     ?? 0
                fCarb += item.macros?.carbsG       ?? 0
                fFat  += item.macros?.fatG         ?? 0
            }
            // Re-use evaluate once it's defined below — evaluated inline here instead.
            let calErr = min(1.0, abs(fCal - max(budget.caloriesKcal, 50)) / max(budget.caloriesKcal, 50))
            let proErr = min(1.0, abs(fPro - max(budget.proteinG, 5)) / max(budget.proteinG, 5))
            let carbErr = min(1.0, abs(fCarb - max(budget.carbsG, 5)) / max(budget.carbsG, 5))
            let fatErr = min(1.0, abs(fFat - max(budget.fatG, 5)) / max(budget.fatG, 5))
            let s = weights.cal * calErr + weights.pro * proErr + weights.carb * carbErr + weights.fat * fatErr
            let detail = ScoreDetail(calErr: calErr, proErr: proErr, carbErr: carbErr, fatErr: fatErr,
                                     calPenalty: 0, proPenalty: 0, fatPenalty: 0, proteinSanityPenalty: 0,
                                     efficiencyBonus: 0, finalScore: s)
            return (fixed, s, detail)
        }

        // High Protein gets extra calorie headroom since more meat = more calories
        let calCap        = budget.caloriesKcal * (profileIndex == 1 ? 1.50 : 1.35)
        var bestScore     = Double.infinity          // lower = better
        var bestPortions: [String: Double] = [:]
        var bestDetail: ScoreDetail? = nil

        // Evaluate a fully-portioned meal and return (score, breakdown).
        func evaluate(_ cal: Double, _ pro: Double, _ carb: Double, _ fat: Double) -> (Double, ScoreDetail) {
            let tCal  = max(budget.caloriesKcal, 50)
            let tPro  = max(budget.proteinG,      5)
            let tCarb = max(budget.carbsG,         5)
            let tFat  = max(budget.fatG,           5)

            let calErr = min(1.0, abs(cal - tCal) / tCal)
            let fatErr = min(1.0, abs(fat - tFat) / tFat)

            // High Protein: reward-based — more protein = lower score = better (bounded at 2×).
            // All other profiles: symmetric error.
            let proErr: Double
            let proContrib: Double
            if profileIndex == 1 {
                proErr     = 0  // not meaningful; actual protein shown in debug log
                proContrib = -weights.pro * min(2.0, pro / max(tPro, 1))
            } else {
                proErr     = min(1.0, abs(pro - tPro) / tPro)
                proContrib = weights.pro * proErr
            }

            // High Carb: mirror of High Protein — reward-based carb term (bounded at 2×).
            // All other profiles: symmetric error.
            let carbErr: Double
            let carbContrib: Double
            if profileIndex == 2 {
                carbErr    = 0  // not meaningful; actual carbs shown in debug log
                carbContrib = -weights.carb * min(2.0, carb / max(tCarb, 1))
            } else {
                carbErr     = min(1.0, abs(carb - tCarb) / tCarb)
                carbContrib = weights.carb * carbErr
            }

            var score = weights.cal * calErr + proContrib + carbContrib + weights.fat * fatErr

            // Calorie excess penalty: High Protein (1) and High Carb (2) get a higher threshold (1.40×)
            // because loading up on a macro naturally adds calories. Best Match uses 1.10×.
            let calExcessThreshold = profileIndex == 0 ? 1.10 : 1.40
            var calPenalty = 0.0
            if cal > budget.caloriesKcal * calExcessThreshold {
                let overage = (cal - budget.caloriesKcal * calExcessThreshold) / max(budget.caloriesKcal * 0.10, 1)
                calPenalty  = 0.30 * min(1.0, overage)
                score      += calPenalty
            }

            // Protein deficiency penalty: flat +0.20 when protein < 80% of target.
            // Skipped for High Protein — the reward term already maximises protein, and
            // effectiveBudget.proteinG is 1.5× the real target, making the 80% threshold
            // (~1.2× real protein) impossible to reach without blowing the calorie budget.
            var proPenalty = 0.0
            if profileIndex != 1 && pro < budget.proteinG * 0.80 {
                proPenalty = 0.20
                score     += proPenalty
            }

            // Protein sanity penalty: skip for High Carb — carb-heavy meals naturally have
            // a lower protein fraction (pasta, rice, bread combos) and would be unfairly penalised.
            var proteinSanityPenalty = 0.0
            if profileIndex != 2 && (pro * 4) / max(cal, 1) < 0.12 && budget.proteinG > 15 {
                proteinSanityPenalty = 0.25
                score               += proteinSanityPenalty
            }

            // Excessive fat penalty — skipped for High Protein because protein sources (eggs, meat)
            // inherently carry fat; penalising this profile for fat would block the best protein picks.
            var fatPenalty = 0.0
            if profileIndex != 1 && fat * 9 > budget.fatG * 9 * 1.50 {
                fatPenalty = 0.10
                score     += fatPenalty
            }

            // Density tiebreaker: much stronger for the specialised profiles (15% vs 2%)
            // so the optimizer genuinely prefers the most protein/carb-dense portion available.
            let efficiencyBonus: Double
            switch profileIndex {
            case 1: efficiencyBonus = 0.15 * (pro  / max(cal, 1.0))
            case 2: efficiencyBonus = 0.15 * (carb / max(cal, 1.0))
            default: efficiencyBonus = 0.02 * (pro  / max(cal, 1.0))
            }
            score -= efficiencyBonus

            return (score, ScoreDetail(
                calErr: calErr, proErr: proErr, carbErr: carbErr, fatErr: fatErr,
                calPenalty: calPenalty, proPenalty: proPenalty,
                fatPenalty: fatPenalty, proteinSanityPenalty: proteinSanityPenalty,
                efficiencyBonus: efficiencyBonus, finalScore: score))
        }

        func search(_ idx: Int, _ cal: Double, _ pro: Double, _ carb: Double, _ fat: Double,
                    _ acc: [(String, Double)]) {
            if idx == combo.count {
                let (s, detail) = evaluate(cal, pro, carb, fat)
                if s < bestScore { bestScore = s; bestPortions = Dictionary(uniqueKeysWithValues: acc); bestDetail = detail }
                return
            }
            let (role, item) = combo[idx]
            let baseCal = item.macros?.caloriesKcal ?? 0
            for mult in allowedPortions(for: role, profileIndex: profileIndex) {
                // Portions are ascending — safe to break once the calorie cap is exceeded
                if cal + baseCal * mult > calCap { break }
                search(idx + 1,
                       cal  + baseCal                      * mult,
                       pro  + (item.macros?.proteinG ?? 0) * mult,
                       carb + (item.macros?.carbsG   ?? 0) * mult,
                       fat  + (item.macros?.fatG     ?? 0) * mult,
                       acc + [(item.id, mult)])
            }
        }

        search(0, 0, 0, 0, 0, [])

        if bestPortions.isEmpty {
            // All portion paths exceeded the calorie cap — fall back to 1× for every item
            bestPortions = Dictionary(uniqueKeysWithValues: combo.map { ($0.1.id, 1.0) })
            var fCal = 0.0, fPro = 0.0, fCarb = 0.0, fFat = 0.0
            for (_, item) in combo {
                fCal  += item.macros?.caloriesKcal ?? 0
                fPro  += item.macros?.proteinG     ?? 0
                fCarb += item.macros?.carbsG       ?? 0
                fFat  += item.macros?.fatG         ?? 0
            }
            let (s, detail) = evaluate(fCal, fPro, fCarb, fFat)
            bestScore = s; bestDetail = detail
        }
        return (bestPortions, bestScore, bestDetail)
    }

    // MARK: - Meal-Scored Swaps

    /// A swap alternative ranked by how well the **complete meal** (with this item substituted in)
    /// matches the user's targets under the active recommendation profile.
    struct SwapOption: Identifiable {
        var id: String { item.id }
        let item: MenuItem
        let serving: Double          // best portion multiplier for this item in this slot
        let scaledMacros: PlanMacros // item macros × serving
        let deltaMacros: PlanMacros  // scaledMacros − current component macros (what changes in the meal)
    }

    /// Returns ranked swap alternatives for one component in a recommended meal.
    ///
    /// Each candidate is scored by simulating the **full meal** with that item swapped in —
    /// i.e., keeping all other components unchanged and finding the best portion for the new item.
    /// This means a protein replacement is ranked by how the whole meal improves, not just the item itself.
    static func swapsForComponent(
        _ component: MealComponent,
        in combo: MealCombo,
        from items: [MenuItem],
        budget: PlanBudget,
        profileIndex: Int,
        goal: UserGoal?,
        topN: Int = 6,
        fixedPortions: Bool = false
    ) -> [SwapOption] {
        let blocked       = Set(goal?.allergens ?? [])
        let preferredTags = Set((goal?.dietaryTags ?? []).map { dietaryTagToBackend[$0] ?? $0 })
        let currentIds    = Set(combo.components.map(\.itemId))

        let effectiveBudget: PlanBudget
        switch profileIndex {
        case 1:
            effectiveBudget = PlanBudget(caloriesKcal: budget.caloriesKcal,
                                          proteinG: budget.proteinG * 1.5,
                                          carbsG:   budget.carbsG   * 0.5, fatG: budget.fatG)
        case 2:
            effectiveBudget = PlanBudget(caloriesKcal: budget.caloriesKcal,
                                          proteinG: budget.proteinG * 0.7,
                                          carbsG:   budget.carbsG   * 1.5, fatG: budget.fatG)
        default:
            effectiveBudget = budget
        }
        let weights = [ObjectiveWeights.bestMatch, .highProtein, .highCarb][min(profileIndex, 2)]
        let calCap  = effectiveBudget.caloriesKcal * (profileIndex == 0 ? 1.35 : 1.50)

        // Base macros of the full meal with the current component removed
        var baseCal = 0.0, basePro = 0.0, baseCarb = 0.0, baseFat = 0.0
        for c in combo.components where c.itemId != component.itemId {
            baseCal  += c.macros?.caloriesKcal ?? 0
            basePro  += c.macros?.proteinG     ?? 0
            baseCarb += c.macros?.carbsG       ?? 0
            baseFat  += c.macros?.fatG         ?? 0
        }

        let candidates = items.filter { item in
            guard item.nutritionStatus == "published" else { return false }
            guard !currentIds.contains(item.id) else { return false }
            guard !isAccessoryItem(item) else { return false }
            guard !item.allergens.contains(where: { blocked.contains($0) }) else { return false }
            if !preferredTags.isEmpty {
                guard item.dietaryTags.contains(where: { preferredTags.contains($0) }) else { return false }
            }
            return classifyRoles(item).contains(component.role)
        }

        let options: [SwapOption] = candidates.compactMap { item in
            guard let m = item.macros, m.caloriesKcal > 0 else { return nil }

            // Find the portion that produces the best complete-meal score
            var bestScore   = Double.infinity
            var bestServing = 1.0
            let mults = fixedPortions ? [1.0] : allowedPortions(for: component.role, profileIndex: profileIndex)
            for mult in mults {
                let totCal = baseCal + m.caloriesKcal * mult
                if !fixedPortions && totCal > calCap { break }
                let s = quickScore(cal: totCal, pro: basePro + m.proteinG * mult,
                                   carb: baseCarb + m.carbsG * mult, fat: baseFat + m.fatG * mult,
                                   budget: effectiveBudget, weights: weights, profileIndex: profileIndex)
                if s < bestScore { bestScore = s; bestServing = mult }
            }

            let scaled = PlanMacros(caloriesKcal: m.caloriesKcal * bestServing,
                                     proteinG:     m.proteinG     * bestServing,
                                     carbsG:       m.carbsG       * bestServing,
                                     fatG:         m.fatG         * bestServing)
            let old    = component.macros ?? .zero
            let delta  = PlanMacros(caloriesKcal: scaled.caloriesKcal - old.caloriesKcal,
                                     proteinG:     scaled.proteinG     - old.proteinG,
                                     carbsG:       scaled.carbsG       - old.carbsG,
                                     fatG:         scaled.fatG         - old.fatG)
            return SwapOption(item: item, serving: bestServing, scaledMacros: scaled, deltaMacros: delta)
        }

        return options
            .sorted { a, b in
                quickScore(cal: baseCal + a.scaledMacros.caloriesKcal,
                           pro: basePro + a.scaledMacros.proteinG,
                           carb: baseCarb + a.scaledMacros.carbsG,
                           fat: baseFat + a.scaledMacros.fatG,
                           budget: effectiveBudget, weights: weights, profileIndex: profileIndex) <
                quickScore(cal: baseCal + b.scaledMacros.caloriesKcal,
                           pro: basePro + b.scaledMacros.proteinG,
                           carb: baseCarb + b.scaledMacros.carbsG,
                           fat: baseFat + b.scaledMacros.fatG,
                           budget: effectiveBudget, weights: weights, profileIndex: profileIndex)
            }
            .prefix(topN)
            .map { $0 }
    }

    /// Lightweight scoring used for swap-candidate ranking.
    /// Must stay in sync with the nested `evaluate` inside `findBestPortions`.
    private static func quickScore(
        cal: Double, pro: Double, carb: Double, fat: Double,
        budget: PlanBudget, weights: ObjectiveWeights, profileIndex: Int
    ) -> Double {
        let tCal  = max(budget.caloriesKcal, 50)
        let tPro  = max(budget.proteinG,      5)
        let tCarb = max(budget.carbsG,         5)
        let tFat  = max(budget.fatG,           5)

        let calErr = min(1.0, abs(cal - tCal) / tCal)
        let fatErr = min(1.0, abs(fat - tFat) / tFat)

        let proContrib: Double = profileIndex == 1
            ? -weights.pro  * min(2.0, pro  / max(tPro,  1))
            : weights.pro   * min(1.0, abs(pro  - tPro)  / tPro)

        let carbContrib: Double = profileIndex == 2
            ? -weights.carb * min(2.0, carb / max(tCarb, 1))
            : weights.carb  * min(1.0, abs(carb - tCarb) / tCarb)

        var score = weights.cal * calErr + proContrib + carbContrib + weights.fat * fatErr

        let threshold = profileIndex == 0 ? 1.10 : 1.40
        if cal > budget.caloriesKcal * threshold {
            let overage = (cal - budget.caloriesKcal * threshold) / max(budget.caloriesKcal * 0.10, 1)
            score += 0.30 * min(1.0, overage)
        }
        if profileIndex != 1 && pro < budget.proteinG * 0.80 { score += 0.20 }
        if profileIndex != 2 && (pro * 4) / max(cal, 1) < 0.12 && budget.proteinG > 15 { score += 0.25 }
        if profileIndex != 1 && fat * 9 > budget.fatG * 9 * 1.50 { score += 0.10 }

        switch profileIndex {
        case 1: score -= 0.15 * (pro  / max(cal, 1.0))
        case 2: score -= 0.15 * (carb / max(cal, 1.0))
        default: score -= 0.02 * (pro  / max(cal, 1.0))
        }
        return score
    }

    // MARK: - Single-Item Selection (non-dining-hall venues)

    /// For cafés and markets where you order one dish: pick the best single item per objective
    /// profile, ensuring all three recommendations are distinct.
    private static func selectBestSingleItems(
        from candidates: [CandidateItem],
        budget: PlanBudget,
        preferredTags: Set<String>,
        topN: Int
    ) -> [MealCombo] {
        let eligible = candidates.filter { $0.item.macros != nil }
        guard !eligible.isEmpty else { return [] }

        let profileSetups: [(ObjectiveWeights, PlanBudget, Int, String)] = [
            (.bestMatch,
             budget,
             0, "Best Match"),
            (.highProtein,
             PlanBudget(caloriesKcal: budget.caloriesKcal,
                        proteinG: budget.proteinG * 1.5, carbsG: budget.carbsG * 0.5, fatG: budget.fatG),
             1, "High Protein"),
            (.highCarb,
             PlanBudget(caloriesKcal: budget.caloriesKcal,
                        proteinG: budget.proteinG * 0.7, carbsG: budget.carbsG * 1.5, fatG: budget.fatG),
             2, "High Carb"),
        ]

        var results: [MealCombo] = []
        var usedIds: Set<String> = []

        for (weights, effBudget, profileIdx, label) in profileSetups.prefix(topN) {
            let scored = eligible
                .filter { !usedIds.contains($0.item.id) }
                .map { cand -> (CandidateItem, Double) in
                    let m = cand.item.macros!
                    let s = quickScore(cal: m.caloriesKcal, pro: m.proteinG,
                                       carb: m.carbsG, fat: m.fatG,
                                       budget: effBudget, weights: weights, profileIndex: profileIdx)
                    return (cand, s)
                }
                .sorted { $0.1 < $1.1 }

            guard let (best, score) = scored.first else { continue }
            usedIds.insert(best.item.id)

            recLog.debug("[\(label)] \(best.item.name)")
            if let m = best.item.macros {
                recLog.debug("  \(Int(m.caloriesKcal)) kcal / \(String(format: "%.1f", m.proteinG))g P / \(String(format: "%.1f", m.carbsG))g C / score=\(score, format: .fixed(precision: 4))")
            }

            let role = [FoodRole.protein, .carb, .produce, .fat, .other]
                .first { best.roles.contains($0) } ?? .other
            let comp = MealComponent(
                itemId: best.item.id, itemName: best.item.name, role: role,
                macros: best.item.macros.map { toPlanMacros($0) },
                categories: best.item.categories, dietaryTags: best.item.dietaryTags,
                itemScore: best.itemScore, servingCount: 1.0,
                baseServing: ComponentServing(quantity: best.item.serving.quantity,
                                              unit: best.item.serving.unit)
            )
            let breakdown = MealScoreBreakdown(
                nutritionScore: max(0, min(100, (1.0 - score) * 100)).rounded(),
                completenessScore: 100, preferenceScore: 70, mealPeriodScore: 70, varietyScore: 70
            )
            results.append(MealCombo(id: UUID().uuidString, components: [comp], scoreBreakdown: breakdown))
        }
        return results
    }

    private static func selectDiverse(
        from rawCombos: [[(FoodRole, MenuItem)]],
        pools: [FoodRole: [CandidateItem]],
        preferredTags: Set<String>,
        budget: PlanBudget,
        topN: Int,
        fixedPortions: Bool = false
    ) -> [MealCombo] {
        let profileLabels = ["Best Match", "High Protein", "High Carb"]
        let profiles: [ObjectiveWeights] = [.bestMatch, .highProtein, .highCarb]

        struct Scored {
            let combo: [(FoodRole, MenuItem)]
            let portions: [String: Double]
            let score: Double
            let detail: ScoreDetail?
        }
        struct ProfileResult { let idx: Int; let combo: MealCombo }

        // Run High Protein (1) FIRST — it gets unconstrained first pick of the best protein combo.
        // Best Match (0) runs second — finds the best balanced combo diverse from High Protein.
        // High Carb (2) runs last — finds the best carb-focused combo diverse from both.
        // Results are re-sorted into display order [0, 1, 2] at the end.
        let runOrder = [1, 0, 2]

        var profileResults: [ProfileResult] = []
        var chosenItemSets: [Set<String>] = []

        for profileIdx in runOrder.prefix(topN) {
            let weights = profiles[profileIdx]
            let label   = profileLabels[profileIdx]

            // Effective budget: inflate the targeted macro and deflate the competing one so the
            // optimizer genuinely pushes past the real daily target for the highlighted nutrient.
            let effectiveBudget: PlanBudget
            switch profileIdx {
            case 1: // High Protein — more protein, fewer carbs
                effectiveBudget = PlanBudget(caloriesKcal: budget.caloriesKcal,
                                              proteinG: budget.proteinG * 1.5,
                                              carbsG:   budget.carbsG   * 0.5, fatG: budget.fatG)
            case 2: // High Carb — more carbs, less protein
                effectiveBudget = PlanBudget(caloriesKcal: budget.caloriesKcal,
                                              proteinG: budget.proteinG * 0.7,
                                              carbsG:   budget.carbsG   * 1.5, fatG: budget.fatG)
            default:
                effectiveBudget = budget
            }

            // Score every combo with this profile's weights, then sort ascending (lower = better)
            let ranked: [Scored] = rawCombos.map { combo -> Scored in
                let (portions, score, detail) = findBestPortions(combo: combo, budget: effectiveBudget,
                                                                  weights: weights, profileIndex: profileIdx,
                                                                  fixedPortions: fixedPortions)
                var finalScore = score
                if Set(combo.map { $0.0 }).count == 1 { finalScore += 0.15 }
                return Scored(combo: combo, portions: portions, score: finalScore, detail: detail)
            }.sorted { $0.score < $1.score }

            // Prefer combos that share ≤1 item with already-chosen results
            var pick: Scored? = ranked.first { cand in
                let ids = Set(cand.combo.map { $0.1.id })
                return !chosenItemSets.contains { ids.intersection($0).count >= 2 }
            }
            if pick == nil {
                pick = ranked.first { cand in
                    let ids = Set(cand.combo.map { $0.1.id })
                    return !chosenItemSets.contains { $0 == ids }
                } ?? ranked.first
            }
            guard let chosen = pick else { continue }

            chosenItemSets.append(Set(chosen.combo.map { $0.1.id }))

            var tCal = 0.0, tPro = 0.0, tCarb = 0.0, tFat = 0.0
            for (_, item) in chosen.combo {
                let m = chosen.portions[item.id] ?? 1.0
                tCal  += (item.macros?.caloriesKcal ?? 0) * m
                tPro  += (item.macros?.proteinG     ?? 0) * m
                tCarb += (item.macros?.carbsG       ?? 0) * m
                tFat  += (item.macros?.fatG         ?? 0) * m
            }
            let names = chosen.combo.map { _, item -> String in
                let m = chosen.portions[item.id] ?? 1.0
                return m != 1.0 ? "\(item.name) ×\(String(format: "%.2g", m))" : item.name
            }.joined(separator: " + ")

            recLog.debug("[\(label)] \(names)")
            recLog.debug("  Target: \(Int(budget.caloriesKcal))kcal / \(Int(budget.proteinG))P / \(Int(budget.carbsG))C / \(Int(budget.fatG))F")
            recLog.debug("  Actual: \(Int(tCal))kcal / \(Int(tPro))P / \(Int(tCarb))C / \(Int(tFat))F")
            if let d = chosen.detail {
                recLog.debug("  Errors:    cal=\(d.calErr, format: .fixed(precision: 3)) pro=\(d.proErr, format: .fixed(precision: 3)) carb=\(d.carbErr, format: .fixed(precision: 3)) fat=\(d.fatErr, format: .fixed(precision: 3))")
                recLog.debug("  Penalties: calOver=\(d.calPenalty, format: .fixed(precision: 3)) proLow=\(d.proPenalty, format: .fixed(precision: 3)) fatHigh=\(d.fatPenalty, format: .fixed(precision: 3)) sanity=\(d.proteinSanityPenalty, format: .fixed(precision: 3))")
                recLog.debug("  Bonus/Score: efficiency=\(d.efficiencyBonus, format: .fixed(precision: 4)) finalScore=\(chosen.score, format: .fixed(precision: 4)) (lower=better)")
            }

            let components = chosen.combo.map { role, item -> MealComponent in
                let count = chosen.portions[item.id] ?? 1.0
                let scaledMacros = item.macros.map { m in
                    PlanMacros(caloriesKcal: m.caloriesKcal * count,
                               proteinG:     m.proteinG     * count,
                               carbsG:       m.carbsG       * count,
                               fatG:         m.fatG         * count)
                }
                let iScore = pools[role]?.first { $0.item.id == item.id }?.itemScore
                    ?? baseItemScore(item, preferredTags: preferredTags)
                return MealComponent(
                    itemId: item.id, itemName: item.name, role: role,
                    macros: scaledMacros,
                    categories: item.categories, dietaryTags: item.dietaryTags,
                    itemScore: iScore, servingCount: count,
                    baseServing: ComponentServing(quantity: item.serving.quantity, unit: item.serving.unit)
                )
            }

            let breakdown = MealScoreBreakdown(
                nutritionScore: max(0, min(100, (1.0 - chosen.score) * 100)).rounded(),
                completenessScore: Double(chosen.combo.count) / 3.0 * 100,
                preferenceScore: 70, mealPeriodScore: 70,
                varietyScore: profileIdx == 0 ? 100 : 60
            )

            profileResults.append(ProfileResult(idx: profileIdx,
                combo: MealCombo(id: UUID().uuidString, components: components, scoreBreakdown: breakdown)))
        }

        // Return in display order: index 0 = Best Match, 1 = High Protein, 2 = High Carb
        return profileResults.sorted { $0.idx < $1.idx }.map { $0.combo }
    }

}
