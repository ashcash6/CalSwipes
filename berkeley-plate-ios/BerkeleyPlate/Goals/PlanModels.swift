import Foundation

// MARK: - Food Role

/// The nutritional role a menu item fills within a meal combination.
enum FoodRole: String, Codable, CaseIterable, Identifiable {
    case protein
    case carb
    case produce
    case fat     // dairy, healthy fat, oil-based sauce
    case other   // dessert, condiment, beverage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .protein: return "Protein"
        case .carb:    return "Carb"
        case .produce: return "Produce"
        case .fat:     return "Extra"
        case .other:   return "Side"
        }
    }

    var systemImage: String {
        switch self {
        case .protein: return "flame.fill"
        case .carb:    return "bolt.fill"
        case .produce: return "leaf.fill"
        case .fat:     return "drop.fill"
        case .other:   return "fork.knife"
        }
    }
}

// MARK: - Component Serving

/// Base serving definition from the source MenuItem, stored alongside the component
/// so physical quantity can be shown without looking up the original menu item.
struct ComponentServing: Codable {
    let quantity: Double   // amount per one serving (e.g. 3.0 for "3 oz")
    let unit: String       // e.g. "oz", "cup", "piece", "each", "bar"
}

// MARK: - Meal Component

/// One food item occupying a specific nutritional role inside a MealCombo.
struct MealComponent: Codable, Identifiable {
    var id: String { itemId }
    let itemId: String
    let itemName: String
    let role: FoodRole
    /// Total macros for `servingCount` servings — already multiplied.
    var macros: PlanMacros?
    let categories: [String]
    let dietaryTags: [String]
    /// Quality score within its role (0–10 scale, for swap-list ranking).
    let itemScore: Double
    /// Number of servings (supports 0.25 increments). Macros above are pre-scaled.
    var servingCount: Double
    /// Physical serving size from the source menu item (e.g. 3 oz, 1 cup).
    /// Used to display a human-readable quantity alongside the serving count.
    let baseServing: ComponentServing?

    init(itemId: String, itemName: String, role: FoodRole, macros: PlanMacros?,
         categories: [String], dietaryTags: [String], itemScore: Double,
         servingCount: Double = 1.0, baseServing: ComponentServing? = nil) {
        self.itemId       = itemId
        self.itemName     = itemName
        self.role         = role
        self.macros       = macros
        self.categories   = categories
        self.dietaryTags  = dietaryTags
        self.itemScore    = itemScore
        self.servingCount = servingCount
        self.baseServing  = baseServing
    }

    private enum CodingKeys: String, CodingKey {
        case itemId, itemName, role, macros, categories, dietaryTags, itemScore, servingCount, baseServing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId       = try c.decode(String.self,   forKey: .itemId)
        itemName     = try c.decode(String.self,   forKey: .itemName)
        role         = try c.decode(FoodRole.self, forKey: .role)
        macros       = try c.decodeIfPresent(PlanMacros.self, forKey: .macros)
        categories   = try c.decode([String].self, forKey: .categories)
        dietaryTags  = try c.decode([String].self, forKey: .dietaryTags)
        itemScore    = try c.decode(Double.self,   forKey: .itemScore)
        // Backward-compat: old data stored Int; Double decodes both fine.
        servingCount = try c.decodeIfPresent(Double.self,           forKey: .servingCount) ?? 1.0
        baseServing  = try c.decodeIfPresent(ComponentServing.self, forKey: .baseServing)
    }
}

// MARK: - Score Breakdown

/// Explainable score for a complete meal combination.
struct MealScoreBreakdown: Codable {
    let nutritionScore: Double    // 0–100
    let completenessScore: Double // 0–100
    let preferenceScore: Double   // 0–100
    let mealPeriodScore: Double   // 0–100
    let varietyScore: Double      // 0–100

    /// Weighted final score (0–100).
    var final: Double {
        nutritionScore    * 0.35
        + completenessScore * 0.30
        + preferenceScore   * 0.15
        + mealPeriodScore   * 0.10
        + varietyScore      * 0.10
    }

    var debugDescription: String {
        String(format: "Nutrition: %.0f | Completeness: %.0f | Preference: %.0f | Period: %.0f | Variety: %.0f → Final: %.1f",
               nutritionScore, completenessScore, preferenceScore,
               mealPeriodScore, varietyScore, final)
    }
}

// MARK: - Meal Combo

/// A complete meal suggestion composed of multiple food components.
struct MealCombo: Codable, Identifiable {
    let id: String
    var components: [MealComponent]
    var scoreBreakdown: MealScoreBreakdown

    var totalMacros: PlanMacros {
        components.compactMap(\.macros).reduce(.zero, +)
    }

    var finalScore: Double { scoreBreakdown.final }

    var componentFor: [FoodRole: MealComponent] {
        Dictionary(components.map { ($0.role, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - Plan Macros

struct PlanMacros: Codable {
    let caloriesKcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double

    static let zero = PlanMacros(caloriesKcal: 0, proteinG: 0, carbsG: 0, fatG: 0)

    static func + (lhs: PlanMacros, rhs: PlanMacros) -> PlanMacros {
        PlanMacros(
            caloriesKcal: lhs.caloriesKcal + rhs.caloriesKcal,
            proteinG:     lhs.proteinG     + rhs.proteinG,
            carbsG:       lhs.carbsG       + rhs.carbsG,
            fatG:         lhs.fatG         + rhs.fatG
        )
    }
}

// MARK: - Plan Slot

struct PlanSlot: Codable, Identifiable {
    let id: String
    let slotOrder: Int
    let hall: String
    let mealPeriod: String
    var status: String              // "pending" | "accepted" | "consumed_externally"
    var mealOptions: [MealCombo]    // up to 3 complete meal suggestions
    var acceptedComboId: String?
    var acceptedMacros: PlanMacros?

    var acceptedCombo: MealCombo? {
        mealOptions.first(where: { $0.id == acceptedComboId })
    }

    var hallTitle: String       { Hall(rawValue: hall)?.title ?? hall }
    var mealPeriodTitle: String { Meal(rawValue: mealPeriod)?.title ?? mealPeriod.capitalized }
    var isPending:  Bool { status == "pending" }
    var isAccepted: Bool { status == "accepted" }
    var isConsumed: Bool { status == "consumed_externally" }
}

// MARK: - Day Plan

struct DayPlan: Codable, Identifiable {
    let id: String
    let planDate: String
    let goalCalories: Double
    let goalProteinG: Double
    let goalCarbsG: Double
    let goalFatG: Double
    var lastRegeneratedAt: Date?
    var lastComputedBudget: PlanBudget?
    var confirmedAt: Date?
    var slots: [PlanSlot]
    /// Per-day toggle and macro overrides for recurring snack foods.
    /// Empty for plans created before this feature — those plans contribute zero snack macros.
    var snackOverrides: [DailySnackOverride]
    /// Calories the user wants to keep aside for meals eaten outside dining halls.
    /// Deducted from the per-slot budget before recommendations are generated.
    var savedOutsideKcal: Double

    var isConfirmed: Bool      { confirmedAt != nil }
    var allSlotsResolved: Bool { slots.allSatisfy { !$0.isPending } }

    // Custom Codable so new fields default gracefully when loading old saved plans.
    private enum CodingKeys: String, CodingKey {
        case id, planDate, goalCalories, goalProteinG, goalCarbsG, goalFatG
        case lastRegeneratedAt, lastComputedBudget, confirmedAt, slots, snackOverrides
        case savedOutsideKcal
    }

    init(id: String, planDate: String,
         goalCalories: Double, goalProteinG: Double, goalCarbsG: Double, goalFatG: Double,
         lastRegeneratedAt: Date? = nil, lastComputedBudget: PlanBudget? = nil,
         confirmedAt: Date? = nil, slots: [PlanSlot],
         snackOverrides: [DailySnackOverride] = [],
         savedOutsideKcal: Double = 0) {
        self.id                 = id;       self.planDate           = planDate
        self.goalCalories       = goalCalories
        self.goalProteinG       = goalProteinG
        self.goalCarbsG         = goalCarbsG
        self.goalFatG           = goalFatG
        self.lastRegeneratedAt  = lastRegeneratedAt
        self.lastComputedBudget = lastComputedBudget
        self.confirmedAt        = confirmedAt
        self.slots              = slots
        self.snackOverrides     = snackOverrides
        self.savedOutsideKcal   = savedOutsideKcal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                 = try c.decode(String.self,               forKey: .id)
        planDate           = try c.decode(String.self,               forKey: .planDate)
        goalCalories       = try c.decode(Double.self,               forKey: .goalCalories)
        goalProteinG       = try c.decode(Double.self,               forKey: .goalProteinG)
        goalCarbsG         = try c.decode(Double.self,               forKey: .goalCarbsG)
        goalFatG           = try c.decode(Double.self,               forKey: .goalFatG)
        lastRegeneratedAt  = try c.decodeIfPresent(Date.self,        forKey: .lastRegeneratedAt)
        lastComputedBudget = try c.decodeIfPresent(PlanBudget.self,  forKey: .lastComputedBudget)
        confirmedAt        = try c.decodeIfPresent(Date.self,        forKey: .confirmedAt)
        slots              = try c.decode([PlanSlot].self,           forKey: .slots)
        snackOverrides     = try c.decodeIfPresent([DailySnackOverride].self, forKey: .snackOverrides) ?? []
        savedOutsideKcal   = try c.decodeIfPresent(Double.self,      forKey: .savedOutsideKcal) ?? 0
    }

    /// Total macros contributed by all enabled snacks for this plan day.
    /// Uses each override's per-day macro values, falling back to the recurring default.
    func snackMacros(recurringFoods: [RecurringFood]) -> PlanMacros {
        guard !snackOverrides.isEmpty else { return .zero }
        let lookup = Dictionary(uniqueKeysWithValues: recurringFoods.map { ($0.id, $0) })
        return snackOverrides.reduce(.zero) { total, ov in
            guard let food = lookup[ov.foodId] else { return total }
            return total + ov.effectiveMacros(food: food)
        }
    }
}

// MARK: - Plan Budget

struct PlanBudget: Codable {
    let caloriesKcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
}

// MARK: - Input

struct PlanSlotInput: Encodable {
    let hall: String
    let mealPeriod: String?
}
