import Foundation

enum GoalType: String, Codable, CaseIterable, Identifiable {
    case lose, maintain, gain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lose: return "Lose weight"
        case .maintain: return "Maintain weight"
        case .gain: return "Gain weight"
        }
    }
    var systemImage: String {
        switch self {
        case .lose: return "arrow.down.circle.fill"
        case .maintain: return "equal.circle.fill"
        case .gain: return "arrow.up.circle.fill"
        }
    }
}

enum Pace: String, Codable, CaseIterable, Identifiable {
    case slow, medium, aggressive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .slow: return "Gradual"
        case .medium: return "Steady"
        case .aggressive: return "Fast"
        }
    }
    var subtitle: String {
        switch self {
        case .slow: return "~250 kcal adjustment / day"
        case .medium: return "~500 kcal adjustment / day"
        case .aggressive: return "~750 kcal adjustment / day"
        }
    }
}

enum ActivityLevel: String, Codable, CaseIterable, Identifiable {
    case sedentary, light, moderate, active
    case veryActive = "very-active"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sedentary: return "Sedentary"
        case .light: return "Lightly active"
        case .moderate: return "Moderately active"
        case .active: return "Active"
        case .veryActive: return "Very active"
        }
    }
    var subtitle: String {
        switch self {
        case .sedentary: return "Mostly sitting, desk work"
        case .light: return "Light walks, some standing"
        case .moderate: return "Regular exercise 3–5×/week"
        case .active: return "Daily workouts"
        case .veryActive: return "Intense daily training"
        }
    }
    var tdeeMultiplier: Double {
        switch self {
        case .sedentary: return 26
        case .light: return 28
        case .moderate: return 30
        case .active: return 33
        case .veryActive: return 36
        }
    }
}

struct UserGoal: Codable {
    var goalType: GoalType
    var pace: Pace
    var heightIn: Double
    var weightLbs: Double
    var activityLevel: ActivityLevel

    // Manual overrides — nil means "use calculated value"
    var manualCalories: Double? = nil
    var manualProteinG: Double? = nil
    var manualCarbsG: Double? = nil
    var manualFatG: Double? = nil

    var isManualMode: Bool { manualCalories != nil }

    private var weightKg: Double { weightLbs * 0.453592 }

    // Pure calculated values (always from profile, ignores manual overrides)
    var computedCalories: Double {
        let base = weightKg * activityLevel.tdeeMultiplier
        let delta: Double
        switch goalType {
        case .maintain: delta = 0
        case .lose:
            switch pace {
            case .slow: delta = -250
            case .medium: delta = -500
            case .aggressive: delta = -750
            }
        case .gain:
            switch pace {
            case .slow: delta = 250
            case .medium: delta = 400
            case .aggressive: delta = 600
            }
        }
        return max(1200, base + delta)
    }
    var computedProteinG: Double { weightLbs * 0.8 }
    var computedCarbsG: Double { computedCalories * 0.45 / 4 }
    var computedFatG: Double { computedCalories * 0.30 / 9 }

    // Final targets — manual if set, else calculated
    var targetCalories: Double { manualCalories ?? computedCalories }
    var targetProteinG: Double { manualProteinG ?? computedProteinG }
    var targetCarbsG: Double   { manualCarbsG   ?? computedCarbsG   }
    var targetFatG: Double     { manualFatG     ?? computedFatG     }
}

struct LoggedMeal: Codable, Identifiable {
    let id: UUID
    let date: String
    let hallTitle: String
    let mealTitle: String
    let itemNames: [String]
    let macros: Macros
    let loggedAt: Date
}

struct WeightEntry: Codable, Identifiable {
    let id: UUID
    let date: String
    let weightLbs: Double
    let loggedAt: Date

    var displayDate: Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return fmt.date(from: date) ?? loggedAt
    }
}
