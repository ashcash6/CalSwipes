import XCTest
@testable import BerkeleyPlate

// MARK: - Fixtures

private func makeItem(
    id: String,
    name: String,
    categories: [String] = [],
    calories: Double,
    protein: Double,
    carbs: Double,
    fat: Double,
    allergens: [String] = [],
    dietaryTags: [String] = [],
    nutritionStatus: String = "published"
) -> MenuItem {
    MenuItem(
        id: id, name: name, categories: categories,
        serving: Serving(quantity: 1, unit: "serving", description: nil, weightG: nil, weightBasis: "estimated"),
        macros: Macros(caloriesKcal: calories, proteinG: protein, carbsG: carbs, fatG: fat),
        nutritionStatus: nutritionStatus,
        referenceImageUrl: nil, warnings: [],
        allergens: allergens, dietaryTags: dietaryTags
    )
}

private func makeItemWithUnit(
    id: String, name: String, unit: String,
    calories: Double, protein: Double, carbs: Double, fat: Double,
    categories: [String] = []
) -> MenuItem {
    MenuItem(
        id: id, name: name, categories: categories,
        serving: Serving(quantity: 1, unit: unit, description: nil, weightG: nil, weightBasis: "estimated"),
        macros: Macros(caloriesKcal: calories, proteinG: protein, carbsG: carbs, fatG: fat),
        nutritionStatus: "published",
        referenceImageUrl: nil, warnings: [], allergens: [], dietaryTags: []
    )
}

private func makeItemNoMacros(id: String, name: String, allergens: [String] = []) -> MenuItem {
    MenuItem(
        id: id, name: name, categories: [],
        serving: Serving(quantity: 1, unit: "serving", description: nil, weightG: nil, weightBasis: "estimated"),
        macros: nil, nutritionStatus: "published",
        referenceImageUrl: nil, warnings: [], allergens: allergens, dietaryTags: []
    )
}

/// A representative dining-hall menu with protein, carbs, and produce items.
private let richMenu: [MenuItem] = [
    makeItem(id: "p1", name: "Grilled Chicken Breast",  calories: 170, protein: 30, carbs: 0,  fat: 4),
    makeItem(id: "p2", name: "Baked Salmon",             calories: 220, protein: 25, carbs: 0,  fat: 12),
    makeItem(id: "p3", name: "Tofu Scramble",            calories: 180, protein: 14, carbs: 8,  fat: 10,
             dietaryTags: ["Vegan Option", "Vegetarian Option"]),
    makeItem(id: "p4", name: "Hard-Boiled Eggs",         calories: 155, protein: 13, carbs: 1,  fat: 11),
    makeItem(id: "c1", name: "Steamed Brown Rice",       calories: 210, protein: 5,  carbs: 44, fat: 2),
    makeItem(id: "c2", name: "Roasted Potatoes",         calories: 180, protein: 3,  carbs: 38, fat: 3),
    makeItem(id: "c3", name: "Whole Wheat Pasta",        calories: 220, protein: 8,  carbs: 43, fat: 2),
    makeItem(id: "c4", name: "Quinoa Pilaf",             calories: 185, protein: 7,  carbs: 34, fat: 3,
             dietaryTags: ["Vegan Option", "Vegetarian Option"]),
    makeItem(id: "v1", name: "Steamed Broccoli",         calories: 55,  protein: 4,  carbs: 10, fat: 1,
             dietaryTags: ["Vegan Option", "Vegetarian Option"]),
    makeItem(id: "v2", name: "Mixed Green Salad",        calories: 25,  protein: 2,  carbs: 4,  fat: 0),
    makeItem(id: "v3", name: "Roasted Vegetables",       calories: 80,  protein: 2,  carbs: 15, fat: 2),
    makeItem(id: "v4", name: "Sliced Fruit",             calories: 70,  protein: 1,  carbs: 18, fat: 0),
    makeItem(id: "f1", name: "Avocado Slices",           calories: 90,  protein: 1,  carbs: 5,  fat: 8),
    makeItem(id: "f2", name: "Hummus",                   calories: 100, protein: 5,  carbs: 12, fat: 5),
]

private let vegetarianMenu: [MenuItem] = [
    makeItem(id: "vg1", name: "Tofu Stir-Fry",          calories: 200, protein: 15, carbs: 10, fat: 10,
             dietaryTags: ["Vegan Option", "Vegetarian Option"]),
    makeItem(id: "vg2", name: "Black Bean Burrito Bowl", calories: 350, protein: 14, carbs: 55, fat: 7,
             dietaryTags: ["Vegetarian Option"]),
    makeItem(id: "vg3", name: "Quinoa",                  calories: 185, protein: 7,  carbs: 34, fat: 3,
             dietaryTags: ["Vegan Option", "Vegetarian Option"]),
    makeItem(id: "vg4", name: "Steamed Broccoli",        calories: 55,  protein: 4,  carbs: 10, fat: 1,
             dietaryTags: ["Vegan Option", "Vegetarian Option"]),
    makeItem(id: "vg5", name: "Caesar Salad",            calories: 180, protein: 4,  carbs: 12, fat: 14,
             dietaryTags: ["Vegetarian Option"]),
    makeItem(id: "non1", name: "Grilled Chicken",        calories: 170, protein: 30, carbs: 0,  fat: 4),
]

private let typicalBudget = PlanBudget(caloriesKcal: 600, proteinG: 35, carbsG: 70, fatG: 20)

// MARK: - Tests

final class RecommenderTests: XCTestCase {

    // 1. Normal menu: verify we get 3 complete combos each with ≥2 distinct items
    func testNormalMenuReturnThreeCombos() {
        let result = LocalRecommender.recommend(
            from: richMenu, meal: .dinner, goal: nil, budget: typicalBudget
        )
        XCTAssertEqual(result.count, 3, "Expected exactly 3 meal options")
        for combo in result {
            XCTAssertGreaterThanOrEqual(combo.components.count, 2, "Each combo should have ≥2 components")
            let ids = combo.components.map(\.itemId)
            XCTAssertEqual(ids.count, Set(ids).count, "No duplicate items within a combo")
        }
    }

    // 2. Vegetarian preference: all results must use only vegetarian-tagged items (hard filter)
    func testVegetarianPreferenceBoostsTaggedItems() {
        var goal = UserGoal(goalType: .maintain, pace: .medium, heightIn: 68,
                            weightLbs: 160, activityLevel: .moderate)
        goal.dietaryTags = ["Vegetarian"]

        let result = LocalRecommender.recommend(
            from: richMenu, meal: .lunch, goal: goal, budget: typicalBudget
        )
        XCTAssertGreaterThan(result.count, 0)
        // Dietary tags are a hard filter — every component must have the Vegetarian tag
        for combo in result {
            for comp in combo.components {
                XCTAssertTrue(
                    comp.dietaryTags.contains("Vegetarian Option"),
                    "All components must be vegetarian-tagged when Vegetarian is a hard requirement. '\(comp.itemName)' is not."
                )
            }
        }
    }

    // 3. Vegan restriction: all combos must use vegan items only
    func testVeganPreferenceResultsInVeganItems() {
        var goal = UserGoal(goalType: .maintain, pace: .medium, heightIn: 68,
                            weightLbs: 160, activityLevel: .moderate)
        goal.dietaryTags = ["Vegan"]

        let result = LocalRecommender.recommend(
            from: vegetarianMenu, meal: .dinner, goal: goal, budget: typicalBudget
        )
        XCTAssertGreaterThan(result.count, 0)
        for combo in result {
            for comp in combo.components {
                let isVegan = comp.dietaryTags.contains("Vegan Option")
                XCTAssertTrue(isVegan,
                              "With vegan hard requirement, every component must be vegan. '\(comp.itemName)' is not.")
            }
        }
    }

    // 4. Shellfish allergen when no shellfish items exist — should not remove any items
    func testShellfishAllergenWithNoShellfishItems() {
        var goal = UserGoal(goalType: .maintain, pace: .medium, heightIn: 68,
                            weightLbs: 160, activityLevel: .moderate)
        goal.allergens = ["Shellfish"]

        // richMenu has no shellfish allergen items
        let result = LocalRecommender.recommend(
            from: richMenu, meal: .dinner, goal: goal, budget: typicalBudget
        )
        XCTAssertEqual(result.count, 3,
                       "Shellfish restriction should not reduce results when no shellfish items exist")
    }

    // 5. Multiple simultaneous restrictions: Gluten + Shellfish
    func testMultipleAllergenRestrictions() {
        var goal = UserGoal(goalType: .maintain, pace: .medium, heightIn: 68,
                            weightLbs: 160, activityLevel: .moderate)
        goal.allergens = ["Gluten", "Shellfish"]

        let menuWithAllergens: [MenuItem] = [
            makeItem(id: "a1", name: "Gluten Pasta",        calories: 300, protein: 10, carbs: 55, fat: 3, allergens: ["Gluten"]),
            makeItem(id: "a2", name: "Shrimp Dish",         calories: 150, protein: 20, carbs: 3,  fat: 5, allergens: ["Shellfish"]),
            makeItem(id: "a3", name: "Grilled Chicken",     calories: 170, protein: 30, carbs: 0,  fat: 4),
            makeItem(id: "a4", name: "Brown Rice",          calories: 210, protein: 5,  carbs: 44, fat: 2),
            makeItem(id: "a5", name: "Steamed Vegetables",  calories: 60,  protein: 3,  carbs: 12, fat: 1),
        ]

        let result = LocalRecommender.recommend(
            from: menuWithAllergens, meal: .dinner, goal: goal, budget: typicalBudget
        )
        XCTAssertGreaterThan(result.count, 0)
        for combo in result {
            for comp in combo.components {
                let itemAllergens = menuWithAllergens.first(where: { $0.id == comp.itemId })?.allergens ?? []
                XCTAssertFalse(itemAllergens.contains("Gluten"),   "Gluten item must not appear in result")
                XCTAssertFalse(itemAllergens.contains("Shellfish"), "Shellfish item must not appear in result")
            }
        }
    }

    // 6. Menu with missing nutrition data: should still return combos
    func testMenuWithMissingNutritionData() {
        let sparseMenu: [MenuItem] = [
            makeItemNoMacros(id: "n1", name: "Grilled Chicken"),
            makeItemNoMacros(id: "n2", name: "Brown Rice"),
            makeItemNoMacros(id: "n3", name: "Broccoli"),
        ]

        let result = LocalRecommender.recommend(
            from: sparseMenu, meal: .lunch, goal: nil, budget: typicalBudget
        )
        XCTAssertGreaterThan(result.count, 0, "Should return combos even when macros are missing")
    }

    // 7. Very few menu items (only 2 total)
    func testMenuWithVeryFewItems() {
        let tinyMenu: [MenuItem] = [
            makeItem(id: "t1", name: "Chicken", calories: 170, protein: 30, carbs: 0, fat: 4),
            makeItem(id: "t2", name: "Rice",    calories: 200, protein: 5,  carbs: 44, fat: 2),
        ]

        let result = LocalRecommender.recommend(
            from: tinyMenu, meal: .dinner, goal: nil, budget: typicalBudget
        )
        XCTAssertGreaterThan(result.count, 0, "Should return at least 1 combo from 2 items")
        let firstCombo = result[0]
        XCTAssertEqual(firstCombo.components.count, 2)
    }

    // 8. Multi-role items: beans count as both protein and carb
    func testMultiCategoryItemsClassifiedCorrectly() {
        let roles = LocalRecommender.classifyRoles(
            makeItem(id: "b1", name: "Black Beans", calories: 150, protein: 9, carbs: 27, fat: 1)
        )
        // Black beans: protein ratio = 9*4/150 = 24% ≥ 20%, AND carb ratio = 27*4/150 = 72% ≥ 45%
        XCTAssertTrue(roles.contains(.protein), "Black beans should be classified as protein")
        XCTAssertTrue(roles.contains(.carb),    "Black beans should be classified as carb")
    }

    func testEggsAreProteinAndMayBeFat() {
        let roles = LocalRecommender.classifyRoles(
            makeItem(id: "e1", name: "Scrambled Eggs", calories: 180, protein: 12, carbs: 2, fat: 13)
        )
        XCTAssertTrue(roles.contains(.protein), "Eggs should be classified as protein")
    }

    // 9. User with calorie target: combo calories should not wildly exceed budget
    func testComboCaloriesRespectBudget() {
        let tightBudget = PlanBudget(caloriesKcal: 400, proteinG: 25, carbsG: 50, fatG: 15)

        let result = LocalRecommender.recommend(
            from: richMenu, meal: .lunch, goal: nil, budget: tightBudget
        )
        XCTAssertGreaterThan(result.count, 0)
        let topCombo = result[0]
        let totalCal = topCombo.totalMacros.caloriesKcal
        XCTAssertLessThan(totalCal, tightBudget.caloriesKcal * 3,
                          "Top combo calories (\(Int(totalCal))) should not wildly exceed budget")
    }

    // 10. User without calorie target (budget = 0 / not meaningful): should still return combos
    func testNoBudgetStillReturnsResults() {
        let zeroBudget = PlanBudget(caloriesKcal: 0, proteinG: 0, carbsG: 0, fatG: 0)

        let result = LocalRecommender.recommend(
            from: richMenu, meal: .lunch, goal: nil, budget: zeroBudget
        )
        XCTAssertGreaterThan(result.count, 0, "Should return combos even with a zero budget")
    }

    // 11. Swap candidates: should return alternatives for a given role, excluding current item
    func testSwapCandidatesExcludeCurrentItem() {
        let currentProteinId = "p1"  // Grilled Chicken

        let candidates = LocalRecommender.swapCandidates(
            from: richMenu,
            role: .protein,
            excluding: [currentProteinId],
            goal: nil
        )

        let candidateIds = candidates.map(\.itemId)
        XCTAssertFalse(candidateIds.contains(currentProteinId),
                       "Current item should not appear as a swap candidate")
        XCTAssertGreaterThan(candidates.count, 0, "Should have at least one swap candidate")
        for candidate in candidates {
            XCTAssertEqual(candidate.role, .protein, "Swap candidates should all be of the requested role")
        }
    }

    func testSwapCandidatesRespectAllergens() {
        var goal = UserGoal(goalType: .maintain, pace: .medium, heightIn: 68,
                            weightLbs: 160, activityLevel: .moderate)
        goal.allergens = ["Shellfish"]

        let menuWithShrimp: [MenuItem] = [
            makeItem(id: "s1", name: "Shrimp",   calories: 150, protein: 18, carbs: 3, fat: 4, allergens: ["Shellfish"]),
            makeItem(id: "s2", name: "Salmon",   calories: 220, protein: 25, carbs: 0, fat: 12),
            makeItem(id: "s3", name: "Chicken",  calories: 170, protein: 30, carbs: 0, fat: 4),
        ]

        let candidates = LocalRecommender.swapCandidates(
            from: menuWithShrimp, role: .protein, excluding: ["s1"], goal: goal
        )
        XCTAssertFalse(candidates.map(\.itemId).contains("s1"),
                       "Allergen-blocked item should not appear as swap candidate")
    }

    // 12. Three suggestions are meaningfully different (no two identical item sets)
    func testThreeSuggestionsAreDiverse() {
        let result = LocalRecommender.recommend(
            from: richMenu, meal: .dinner, goal: nil, budget: typicalBudget
        )
        XCTAssertEqual(result.count, 3)

        let combo0Ids = Set(result[0].components.map(\.itemId))
        let combo1Ids = Set(result[1].components.map(\.itemId))
        let combo2Ids = Set(result[2].components.map(\.itemId))

        XCTAssertNotEqual(combo0Ids, combo1Ids, "Option 1 and Option 2 should not be identical")
        XCTAssertNotEqual(combo0Ids, combo2Ids, "Option 1 and Option 3 should not be identical")
        XCTAssertNotEqual(combo1Ids, combo2Ids, "Option 2 and Option 3 should not be identical")

        // The diversity constraint: at most 1 shared item between any two chosen combos
        let shared01 = combo0Ids.intersection(combo1Ids).count
        let shared02 = combo0Ids.intersection(combo2Ids).count
        let shared12 = combo1Ids.intersection(combo2Ids).count
        XCTAssertLessThanOrEqual(shared01, 1, "Options 1 and 2 share too many items")
        XCTAssertLessThanOrEqual(shared02, 1, "Options 1 and 3 share too many items")
        XCTAssertLessThanOrEqual(shared12, 1, "Options 2 and 3 share too many items")
    }

    // Bonus: all allergen-violating items are excluded — never just penalised
    func testAllergenViolationIsHardExclusion() {
        var goal = UserGoal(goalType: .maintain, pace: .medium, heightIn: 68,
                            weightLbs: 160, activityLevel: .moderate)
        goal.allergens = ["Milk"]

        let menuWithDairy: [MenuItem] = [
            makeItem(id: "d1", name: "Mac and Cheese",   calories: 400, protein: 15, carbs: 60, fat: 12,
                     allergens: ["Milk", "Gluten"]),
            makeItem(id: "d2", name: "Yogurt Parfait",   calories: 200, protein: 12, carbs: 28, fat: 4,
                     allergens: ["Milk"]),
            makeItem(id: "d3", name: "Grilled Chicken",  calories: 170, protein: 30, carbs: 0,  fat: 4),
            makeItem(id: "d4", name: "Brown Rice",       calories: 210, protein: 5,  carbs: 44, fat: 2),
            makeItem(id: "d5", name: "Steamed Broccoli", calories: 55,  protein: 4,  carbs: 10, fat: 1),
        ]

        let result = LocalRecommender.recommend(
            from: menuWithDairy, meal: .dinner, goal: goal, budget: typicalBudget
        )
        XCTAssertGreaterThan(result.count, 0)
        for combo in result {
            for comp in combo.components {
                let itemAllergens = menuWithDairy.first(where: { $0.id == comp.itemId })?.allergens ?? []
                XCTAssertFalse(itemAllergens.contains("Milk"),
                               "Dairy item '\(comp.itemName)' must never appear when Milk is blocked")
            }
        }
    }

    // Score breakdown: completeness should be 100 when all three core roles are present
    func testScoreBreakdownCompletenessWhenAllRolesPresent() {
        let result = LocalRecommender.recommend(
            from: richMenu, meal: .dinner, goal: nil, budget: typicalBudget
        )
        guard let topCombo = result.first else { return XCTFail("No result") }
        let hasProtein = topCombo.components.contains { $0.role == .protein }
        let hasCarb    = topCombo.components.contains { $0.role == .carb }
        let hasProduce = topCombo.components.contains { $0.role == .produce }

        if hasProtein && hasCarb && hasProduce {
            XCTAssertEqual(topCombo.scoreBreakdown.completenessScore, 100,
                           "Completeness should be 100 when all three core roles are present")
        }
    }

    // MARK: - New tests (accessory filtering + chronological ordering)

    // 17. isAccessoryItem correctly flags condiments, dressings, and sauces
    func testIsAccessoryItemIdentifiesCondiments() {
        // Name-based detection
        let ranchDressing = makeItem(id: "r1", name: "Ranch Dressing",
                                     calories: 130, protein: 1, carbs: 2, fat: 13)
        let ketchup       = makeItem(id: "k1", name: "Ketchup",
                                     calories: 20, protein: 0, carbs: 5, fat: 0)
        let hotSauce      = makeItem(id: "h1", name: "Hot Sauce",
                                     calories: 5, protein: 0, carbs: 1, fat: 0)

        // Unit-based detection (tbsp serving)
        let tbspDressing  = makeItemWithUnit(id: "t1", name: "Italian Dressing", unit: "tbsp",
                                             calories: 70, protein: 0, carbs: 2, fat: 7)

        // Category-based detection
        let condimentItem = makeItem(id: "cond1", name: "Dijon Mustard",
                                     categories: ["Condiments"],
                                     calories: 15, protein: 0, carbs: 1, fat: 0)

        // Items that are NOT accessories
        let chicken = makeItem(id: "c1", name: "Grilled Chicken",
                               calories: 170, protein: 30, carbs: 0, fat: 4)
        let avocado = makeItem(id: "a1", name: "Avocado Slices",
                               calories: 90, protein: 1, carbs: 5, fat: 8)
        let hummus  = makeItem(id: "h2", name: "Hummus",
                               calories: 100, protein: 5, carbs: 12, fat: 5)

        XCTAssertTrue(LocalRecommender.isAccessoryItem(ranchDressing),
                      "Ranch Dressing should be detected as an accessory item")
        XCTAssertTrue(LocalRecommender.isAccessoryItem(ketchup),
                      "Ketchup should be detected as an accessory item")
        XCTAssertTrue(LocalRecommender.isAccessoryItem(hotSauce),
                      "Hot Sauce should be detected as an accessory item")
        XCTAssertTrue(LocalRecommender.isAccessoryItem(tbspDressing),
                      "Tablespoon-unit item should be detected as an accessory item")
        XCTAssertTrue(LocalRecommender.isAccessoryItem(condimentItem),
                      "Item categorized as Condiments should be detected as an accessory item")

        XCTAssertFalse(LocalRecommender.isAccessoryItem(chicken),
                       "Grilled Chicken must NOT be flagged as an accessory")
        XCTAssertFalse(LocalRecommender.isAccessoryItem(avocado),
                       "Avocado Slices must NOT be flagged as an accessory")
        XCTAssertFalse(LocalRecommender.isAccessoryItem(hummus),
                       "Hummus must NOT be flagged as an accessory")
    }

    // 18. Condiment/dressing items must never occupy a primary combo slot
    func testAccessoryItemsExcludedFromCombos() {
        let menuWithCondiments: [MenuItem] = [
            makeItem(id: "p1", name: "Grilled Chicken",  calories: 170, protein: 30, carbs: 0,  fat: 4),
            makeItem(id: "c1", name: "Brown Rice",        calories: 210, protein: 5,  carbs: 44, fat: 2),
            makeItem(id: "v1", name: "Steamed Broccoli",  calories: 55,  protein: 4,  carbs: 10, fat: 1),
            makeItem(id: "rn", name: "Ranch Dressing",    calories: 130, protein: 1,  carbs: 2,  fat: 13),
            makeItem(id: "kt", name: "Ketchup",           calories: 20,  protein: 0,  carbs: 5,  fat: 0),
            makeItem(id: "hs", name: "Hot Sauce",         calories: 5,   protein: 0,  carbs: 1,  fat: 0),
        ]

        let result = LocalRecommender.recommend(
            from: menuWithCondiments, meal: .dinner, goal: nil, budget: typicalBudget
        )
        XCTAssertGreaterThan(result.count, 0, "Should produce combos from the non-condiment items")
        for combo in result {
            for comp in combo.components {
                XCTAssertFalse(["rn", "kt", "hs"].contains(comp.itemId),
                               "'\(comp.itemName)' is a condiment/dressing and must never appear as a combo component")
            }
        }
    }

    // 19. Meal periods sort into canonical chronological order (breakfast → lunch → dinner)
    func testMealOrderIsChronological() {
        let input: [Meal] = [.dinner, .breakfast, .lunch]
        let sorted = input.sorted { a, b in
            let ia = Meal.allCases.firstIndex(of: a) ?? 99
            let ib = Meal.allCases.firstIndex(of: b) ?? 99
            return ia < ib
        }
        XCTAssertEqual(sorted, [.breakfast, .lunch, .dinner],
                       "Meals should sort chronologically: breakfast → lunch → dinner")
    }

    // 20. All six meal periods sort into the correct canonical order
    func testChronologicalOrderAllMealPeriods() {
        let input: [Meal] = [.dinner, .lateNight, .breakfast, .lunch, .brunch]
        let sorted = input.sorted { a, b in
            let ia = Meal.allCases.firstIndex(of: a) ?? 99
            let ib = Meal.allCases.firstIndex(of: b) ?? 99
            return ia < ib
        }
        XCTAssertEqual(sorted, [.breakfast, .brunch, .lunch, .dinner, .lateNight],
                       "Five meal periods should sort correctly according to canonical meal order")
    }

    // 21. PlanStore.createPlan sorts slots chronologically regardless of input order
    @MainActor
    func testPlanStoreCreatePlanSortsChronologically() async {
        let store = PlanStore()
        let goal = UserGoal(goalType: .maintain, pace: .medium, heightIn: 68,
                            weightLbs: 160, activityLevel: .moderate)
        // Submit deliberately out of order: dinner first, then breakfast, then lunch
        let inputs = [
            PlanSlotInput(hall: "crossroads", mealPeriod: "dinner"),
            PlanSlotInput(hall: "crossroads", mealPeriod: "breakfast"),
            PlanSlotInput(hall: "crossroads", mealPeriod: "lunch"),
        ]
        await store.createPlan(date: "2099-01-01", goal: goal, slots: inputs, logs: [])
        guard let plan = store.plan else {
            return XCTFail("Plan should have been created")
        }
        // Slots must be in chronological order regardless of input order
        let mealPeriods = plan.slots.map { $0.mealPeriod }
        XCTAssertEqual(mealPeriods, ["breakfast", "lunch", "dinner"],
                       "createPlan must sort slots chronologically: breakfast → lunch → dinner")
    }

    // 22. Dietary tags are a hard requirement — non-tagged items never appear in results
    func testDietaryTagsAreHardRequirement() {
        let mixedMenu: [MenuItem] = [
            makeItem(id: "vg1", name: "Tofu Bowl",      calories: 200, protein: 15, carbs: 20, fat: 8,
                     dietaryTags: ["Vegan Option"]),
            makeItem(id: "om1", name: "Chicken Breast", calories: 170, protein: 30, carbs: 0,  fat: 4),
            makeItem(id: "om2", name: "Brown Rice",     calories: 200, protein: 5,  carbs: 44, fat: 2),
        ]
        var goal = UserGoal(goalType: .maintain, pace: .medium, heightIn: 68,
                            weightLbs: 160, activityLevel: .moderate)
        goal.dietaryTags = ["Vegan"]

        let result = LocalRecommender.recommend(
            from: mixedMenu, meal: .lunch, goal: goal, budget: typicalBudget
        )
        // Even if no full combo is possible, non-vegan items must not appear
        for combo in result {
            for comp in combo.components {
                XCTAssertFalse(["om1", "om2"].contains(comp.itemId),
                               "Non-vegan '\(comp.itemName)' must not appear when Vegan is a hard dietary requirement")
            }
        }
    }
}
