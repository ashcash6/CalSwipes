import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Tier 2: Apple's on-device model (Foundation Models framework, iOS 26+).
///
/// The model turns free text into tool calls (searchMenu / recommendMeal / planDay). The tools run
/// LocalAssistantEngine on cached menus, so numbers come from Berkeley Dining data and never from
/// the model's imagination. Questions it shouldn't answer locally (allergen policy, tray scans,
/// dining-info questions) come back as the sentinel NEEDS_CLOUD and the router escalates to Tier 3.
///
/// Verified against developer.apple.com (Nov 2026): `Tool` (name, description, @Generable Arguments,
/// `call(arguments:) async throws -> Output` where Output: PromptRepresentable, String works),
/// `@Guide(description:)`, `LanguageModelSession(tools:instructions:)`, `respond(to:)`.
/// NOT verified in this build (couldn't fetch the page): the exact shape of
/// `SystemLanguageModel.default.availability`. Only `.available` is matched here, so other cases
/// just fall through to "unavailable". Compile on Xcode 26 to confirm.
enum OnDeviceAssistant {
    static let needsCloud = "NEEDS_CLOUD"

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Returns nil when the model is unavailable, failed, or asked for the cloud.
    static func answer(_ question: String, context: AssistantContext, snap: MenuSnapshot) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable {
            return await OnDeviceSession.answer(question, context: context, snap: snap)
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum OnDeviceSession {
    static let instructions = """
    You are CalSwipes, a UC Berkeley dining hall assistant. Always use the tools to get menu items, \
    nutrition and meal plans; never make up foods or numbers. Halls: Crossroads, Cafe 3, Foothill, Clark Kerr. \
    Meals: breakfast, lunch, dinner. Keep answers under 80 words.
    If the user asks about allergen safety or cross-contact, dining policies, hours for a specific day, \
    scanning a photo, or anything the tools can't answer, reply with exactly: \(OnDeviceAssistant.needsCloud)
    """

    static func answer(_ question: String, context: AssistantContext, snap: MenuSnapshot) async -> String? {
        let session = LanguageModelSession(
            tools: [SearchMenuTool(snap: snap), RecommendMealTool(snap: snap), PlanDayTool(snap: snap)],
            instructions: instructions
        )
        var prompt = question
        if let summary = context.mealSummary {
            prompt = "The user is looking at this meal: \(summary)\nQuestion: \(question)"
        }
        do {
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text.contains(OnDeviceAssistant.needsCloud) ? nil : text
        } catch {
            return nil   // guardrail violations, context overflow, etc. -> let the router fall back
        }
    }
}

@available(iOS 26.0, *)
private func parseHall(_ s: String, default d: Hall) -> Hall {
    let t = s.lowercased()
    return Hall.allCases.first { t.contains($0.title.lowercased()) || t == $0.rawValue
        || t.contains($0.rawValue.replacingOccurrences(of: "-", with: " ")) } ?? d
}

@available(iOS 26.0, *)
private func parseMeal(_ s: String) -> Meal? {
    let t = s.lowercased()
    return Meal.allCases.first { t.contains($0.title.lowercased()) }
}

@available(iOS 26.0, *)
struct SearchMenuTool: Tool {
    let name = "searchMenu"
    let description = "Search today's dining hall menu for items by keyword. Returns protein and calories per serving."
    let snap: MenuSnapshot

    @Generable
    struct Arguments {
        @Guide(description: "Food keyword like tofu or chicken, or empty for everything")
        var query: String
        @Guide(description: "Hall name: Crossroads, Cafe 3, Foothill or Clark Kerr. Empty for all halls")
        var hall: String
        @Guide(description: "breakfast, lunch or dinner. Empty for any")
        var meal: String
    }

    func call(arguments: Arguments) async throws -> String {
        let hall: Hall? = arguments.hall.isEmpty ? nil : parseHall(arguments.hall, default: snap.defaultHall)
        let hits = LocalAssistantEngine.searchMenu(snap, query: arguments.query, hall: hall,
                                                   meal: parseMeal(arguments.meal), limit: 8)
        if hits.isEmpty { return "No matching items in the loaded menus." }
        return hits.map { h, m, i in
            "\(i.name) at \(h.title) \(m.title): \(Int(i.macros?.caloriesKcal ?? 0)) kcal, \(Int(i.macros?.proteinG ?? 0))g protein"
        }.joined(separator: "\n")
    }
}

@available(iOS 26.0, *)
struct RecommendMealTool: Tool {
    let name = "recommendMeal"
    let description = "Build the best meal at one hall for a calorie and protein target using the user's goals and allergies."
    let snap: MenuSnapshot

    @Generable
    struct Arguments {
        @Guide(description: "Hall name: Crossroads, Cafe 3, Foothill or Clark Kerr")
        var hall: String
        @Guide(description: "breakfast, lunch or dinner")
        var meal: String
        @Guide(description: "Calorie target for this meal, or 0 to use the user's goal")
        var calories: Int
        @Guide(description: "Protein target in grams, or 0 to use the user's goal")
        var proteinGrams: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let hall = parseHall(arguments.hall, default: snap.defaultHall)
        let meal = parseMeal(arguments.meal) ?? BerkeleyClock.suggestedMeal()
        var budget = LocalAssistantEngine.mealBudget(goal: snap.goal, todayCalories: snap.todayCalories)
        if arguments.calories > 0 || arguments.proteinGrams > 0 {
            budget = PlanBudget(caloriesKcal: arguments.calories > 0 ? Double(arguments.calories) : budget.caloriesKcal,
                                proteinG: arguments.proteinGrams > 0 ? Double(arguments.proteinGrams) : budget.proteinG,
                                carbsG: budget.carbsG, fatG: budget.fatG)
        }
        guard let combo = LocalAssistantEngine.bestCombo(snap, hall: hall, meal: meal, budget: budget) else {
            return "No published \(meal.title) menu at \(hall.title)."
        }
        return "\(hall.title) \(meal.title): \(LocalAssistantEngine.describe(combo))"
    }
}

@available(iOS 26.0, *)
struct PlanDayTool: Tool {
    let name = "planDay"
    let description = "Plan breakfast, lunch and dinner at one hall that together fit the user's daily targets."
    let snap: MenuSnapshot

    @Generable
    struct Arguments {
        @Guide(description: "Hall name: Crossroads, Cafe 3, Foothill or Clark Kerr")
        var hall: String
    }

    func call(arguments: Arguments) async throws -> String {
        LocalAssistantEngine.answer(.planMyDay(parseHall(arguments.hall, default: snap.defaultHall)), snap: snap)
    }
}
#endif
