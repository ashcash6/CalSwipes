import Foundation

/// Which tier produced an answer. Shown as a small badge so it's clear when the cloud was used.
enum AssistantTier: String, Codable {
    case local      // Tier 1: deterministic, from cached menus + LocalRecommender. Free, instant, offline.
    case onDevice   // Tier 2: Apple Foundation Models on the phone. Free, private.
    case cloud      // Tier 3: CalSwipes backend -> Gemini. Counts against the daily quota.

    var label: String {
        switch self {
        case .local:    return "Instant"
        case .onDevice: return "On-device AI"
        case .cloud:    return "Cloud AI"
        }
    }
    var icon: String {
        switch self {
        case .local:    return "bolt.fill"
        case .onDevice: return "iphone"
        case .cloud:    return "cloud.fill"
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, system }
    let id = UUID()
    let role: Role
    var text: String
    var tier: AssistantTier? = nil
    var citations: [String] = []
    var scanMatches: [ScanMatch] = []
}

/// Quick-action chips. Every chip except `.scanTray` is answered without any AI.
enum QuickAction: Hashable, Identifiable {
    case bestProtein(Hall)
    case suggestMeal(Hall, Meal)
    case planMyDay(Hall)
    case whatsOpenNow
    case scanTray

    var id: String { title }
    var title: String {
        switch self {
        case .bestProtein(let h):    return "Best protein at \(h.title)"
        case .suggestMeal(let h, let m): return "Suggest \(m.title.lowercased()) at \(h.title)"
        case .planMyDay:             return "Plan my day"
        case .whatsOpenNow:          return "What's open now?"
        case .scanTray:              return "Scan my tray"
        }
    }
    var icon: String {
        switch self {
        case .bestProtein: return "flame.fill"
        case .suggestMeal: return "sparkles"
        case .planMyDay:   return "calendar"
        case .whatsOpenNow: return "clock"
        case .scanTray:    return "camera.viewfinder"
        }
    }
}

/// Context the chat was opened from (e.g. "Ask about this meal" on a combo card).
struct AssistantContext: Equatable {
    var hall: Hall?
    var meal: Meal?
    var mealSummary: String?   // human-readable list of items + macros

    static let none = AssistantContext()

    static func combo(_ combo: MealCombo, hall: Hall?, meal: Meal?) -> AssistantContext {
        let items = combo.components.map { c -> String in
            let kcal = c.macros.map { " (\(Int($0.caloriesKcal)) kcal, \(Int($0.proteinG))g protein)" } ?? ""
            return "\(c.itemName) x\(c.servingCount.formatted(.number.precision(.fractionLength(0...2))))\(kcal)"
        }
        let t = combo.totalMacros
        let summary = items.joined(separator: "; ")
            + ". Total \(Int(t.caloriesKcal)) kcal, \(Int(t.proteinG))g protein, \(Int(t.carbsG))g carbs, \(Int(t.fatG))g fat."
        return AssistantContext(hall: hall, meal: meal, mealSummary: summary)
    }
}

struct ScanMatch: Codable, Identifiable, Equatable {
    var id: String { menuItemId }
    let menuItemId: String
    let name: String
    let confidence: Double
}

/// Errors from Tier 3 that the UI turns into friendly messages (and maybe the paywall).
enum CloudAssistantError: LocalizedError {
    case quotaExceeded(message: String, tier: String)
    case budgetExhausted(message: String)
    case notConfigured
    case server(String)

    var errorDescription: String? {
        switch self {
        case .quotaExceeded(let m, _): return m
        case .budgetExhausted(let m):  return m
        case .notConfigured:           return "The cloud assistant isn't set up on this build yet."
        case .server(let m):           return m
        }
    }
}
