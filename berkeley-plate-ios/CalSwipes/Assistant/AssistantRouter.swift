import Foundation
import Observation
import os

private let routerLog = Logger(subsystem: "CalSwipes", category: "AssistantRouter")

/// Decides which tier answers each message, cheapest first:
///   Tier 1 (local)    chips and simple keyword intents -> LocalAssistantEngine. Free, instant, offline.
///   Tier 2 (onDevice) free text, when Apple Intelligence is available -> Foundation Models + local tools.
///   Tier 3 (cloud)    tray scans, allergen/policy/dining-info questions, complex multi-step requests,
///                     or anything Tier 2 declined -> CalSwipes backend (counts against daily quota).
@Observable @MainActor
final class AssistantRouter {
    enum Route: Equatable {
        case local(QuickAction)
        case onDevice
        case cloud(reason: String)
    }

    private(set) var messages: [ChatMessage] = []
    private(set) var isThinking = false
    private(set) var thinkingLabel = "Thinking…"
    /// Cloud answers left today (from the server), nil until the first cloud call.
    private(set) var cloudRemaining: Int?
    private(set) var cloudLimit: Int?
    /// Set when the server says the user hit their daily cap; the chat view shows the CalSwipes+ paywall.
    var showPaywall = false
    /// Apple guideline 5.1.2(i): ask before sending questions/photos to a third-party AI (Google Gemini).
    var showConsent = false
    private var pendingCloud: (() async -> Void)?
    private static let consentKey = "cloudAIConsent.v1"
    var hasCloudConsent: Bool { UserDefaults.standard.bool(forKey: Self.consentKey) }

    func grantConsent() {
        UserDefaults.standard.set(true, forKey: Self.consentKey)
        showConsent = false
        let work = pendingCloud
        pendingCloud = nil
        if let work { Task { await work() } }
    }

    func declineConsent() {
        showConsent = false
        pendingCloud = nil
        messages.append(ChatMessage(role: .system, text: "No problem. The quick buttons above still work without sending anything to AI."))
    }
    var context: AssistantContext = .none

    private let store: AppStore
    private let daily: DailyStore
    private let subscription: SubscriptionStore
    private let cloud = CloudAssistantClient()

    init(store: AppStore, daily: DailyStore, subscription: SubscriptionStore) {
        self.store = store
        self.daily = daily
        self.subscription = subscription
    }

    var onDeviceAvailable: Bool { OnDeviceAssistant.isAvailable }

    var quickActions: [QuickAction] {
        let hall = context.hall ?? store.selectedHall
        let meal = context.meal ?? store.selectedMeal
        return [.bestProtein(hall), .suggestMeal(hall, meal), .planMyDay(hall), .whatsOpenNow, .scanTray]
    }

    /// Chips shown when the chat was opened from a specific meal card.
    var mealQuestions: [String] {
        guard context.mealSummary != nil else { return [] }
        return ["Is this high in protein?", "How do I cut 200 calories from this?", "Any allergens I should know about?"]
    }

    func open(with context: AssistantContext) {
        if context != self.context {
            self.context = context
            messages = []
        }
    }

    // MARK: Classification (pure, unit-tested)

    nonisolated static func classify(_ text: String, onDeviceAvailable: Bool, defaultHall: Hall,
                                      hasMealContext: Bool = false) -> Route {
        let t = text.lowercased()
        let cloudTriggers = ["allerg", "cross-contact", "cross contact", "celiac", "gluten-free", "gluten free",
                             "nut-free", "nut free", "safe for", "safe to eat", "epipen", "policy", "label mean",
                             "why", "explain", "compare", "difference between", "how does calswipes",
                             "meal plan", "meal swipe", "swipes", "flex dollars", "refund"]
        if t.count > 220 || cloudTriggers.contains(where: { t.contains($0) }) {
            return .cloud(reason: "needs dining info or safety guidance")
        }
        if !hasMealContext, let chip = LocalAssistantEngine.quickAction(for: t, defaultHall: defaultHall) {
            return chip == .scanTray ? .cloud(reason: "scan") : .local(chip)
        }
        return onDeviceAvailable ? .onDevice : .cloud(reason: "on-device AI unavailable")
    }

    // MARK: Sending

    func tap(_ action: QuickAction) async {
        messages.append(ChatMessage(role: .user, text: action.title))
        if action == .scanTray {
            messages.append(ChatMessage(role: .assistant, text: "Take a photo of your tray and I'll match it to today's menu.",
                                        tier: .local))
            return
        }
        let snap = await snapshot(focus: action)
        messages.append(ChatMessage(role: .assistant, text: LocalAssistantEngine.answer(action, snap: snap), tier: .local))
    }

    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        messages.append(ChatMessage(role: .user, text: text))
        thinkingLabel = "Thinking…"
        isThinking = true
        defer { isThinking = false }

        let route = Self.classify(text, onDeviceAvailable: onDeviceAvailable,
                                  defaultHall: context.hall ?? store.selectedHall,
                                  hasMealContext: context.mealSummary != nil)
        routerLog.info("route=\(String(describing: route), privacy: .public)")
        switch route {
        case .local(let action):
            let snap = await snapshot(focus: action)
            messages.append(ChatMessage(role: .assistant, text: LocalAssistantEngine.answer(action, snap: snap), tier: .local))
        case .onDevice:
            let snap = await snapshot()
            if let answer = await OnDeviceAssistant.answer(text, context: context, snap: snap) {
                messages.append(ChatMessage(role: .assistant, text: answer, tier: .onDevice))
            } else {
                thinkingLabel = "Checking today's menus…"
                await askCloud(text)   // model declined (NEEDS_CLOUD) or failed
            }
        case .cloud:
            thinkingLabel = "Checking today's menus…"
            await askCloud(text)
        }
    }

    func scan(jpeg: Data) async {
        guard hasCloudConsent else {
            pendingCloud = { [weak self] in await self?.scan(jpeg: jpeg) }
            showConsent = true
            return
        }
        let hall = context.hall ?? store.selectedHall
        let meal = context.meal ?? store.selectedMeal
        messages.append(ChatMessage(role: .user, text: "📷 Tray photo (\(hall.title), \(meal.title))"))
        isThinking = true
        defer { isThinking = false }
        do {
            let r = try await cloud.scan(jpeg: jpeg, hall: hall, meal: meal, entitlement: entitlementHeaders)
            let text = r.matches.isEmpty
                ? "I couldn't match anything on the tray to today's \(meal.title.lowercased()) menu at \(hall.title)."
                : "Here's what I see. Check the items and servings, then tap Log meal:"
            track(r.quota)
            messages.append(ChatMessage(role: .assistant, text: text + quotaNote(r.quota), tier: .cloud, scanMatches: r.matches))
        } catch {
            handle(error)
        }
    }

    // MARK: Helpers

    private var entitlementHeaders: EntitlementHeaders {
        // During the promo everyone is premium server-side anyway; only real subscribers send the claim.
        EntitlementHeaders(isSubscriber: subscription.hasActiveSubscription,
                           signedTransaction: subscription.latestSignedTransaction)
    }

    private func askCloud(_ text: String) async {
        guard hasCloudConsent else {
            pendingCloud = { [weak self] in
                guard let self else { return }
                self.thinkingLabel = "Checking today's menus…"
                self.isThinking = true
                defer { self.isThinking = false }
                await self.askCloud(text)
            }
            showConsent = true
            return
        }
        do {
            let r = try await cloud.ask(text, context: context, entitlement: entitlementHeaders)
            track(r.quota)
            messages.append(ChatMessage(role: .assistant, text: r.answer + quotaNote(r.quota), tier: .cloud,
                                        citations: r.citations ?? []))
        } catch {
            // Offline or capped: still try to be useful with a local answer.
            if let chip = LocalAssistantEngine.quickAction(for: text, defaultHall: context.hall ?? store.selectedHall),
               chip != .scanTray {
                let snap = await snapshot(focus: chip)
                messages.append(ChatMessage(role: .assistant, text: LocalAssistantEngine.answer(chip, snap: snap), tier: .local))
            }
            handle(error)
        }
    }

    private func quotaNote(_ quota: CloudAssistantClient.Quota?) -> String {
        guard let q = quota, q.remaining <= 1 else { return "" }
        return q.remaining == 0 ? "\n\n(That was your last cloud answer for today.)" : "\n\n(1 cloud answer left today.)"
    }

    /// Logs the confirmed tray items. `picks` = (match, servings). Returns false if nothing had nutrition.
    @discardableResult
    func logScan(_ picks: [(ScanMatch, Double)]) -> Bool {
        let usable = picks.filter { $0.1 > 0 && $0.0.macros != nil }
        guard !usable.isEmpty else { return false }
        func sum(_ k: KeyPath<Macros, Double>) -> Double { usable.reduce(0) { $0 + $1.0.macros![keyPath: k] * $1.1 } }
        let total = Macros(caloriesKcal: sum(\.caloriesKcal), proteinG: sum(\.proteinG),
                           carbsG: sum(\.carbsG), fatG: sum(\.fatG))
        let hall = context.hall ?? store.selectedHall
        let meal = context.meal ?? store.selectedMeal
        let name = usable.map { $0.1 == 1 ? $0.0.name : "\($0.0.name) ×\($0.1.formatted())" }.joined(separator: ", ")
        daily.logDiningItem(name: name, macros: total, hallTitle: hall.title, mealTitle: meal.title)
        messages.append(ChatMessage(role: .system, text: "Logged \(Int(total.caloriesKcal.rounded())) kcal, \(Int(total.proteinG.rounded()))g protein."))
        return true
    }

    private func track(_ quota: CloudAssistantClient.Quota?) {
        guard let quota else { return }
        cloudRemaining = quota.remaining
        cloudLimit = quota.limit
    }

    private func handle(_ error: Error) {
        var message = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach the assistant. Check your connection."
        if case CloudAssistantError.quotaExceeded = error {
            cloudRemaining = 0
            message = "You've used all your AI answers for today. The quick buttons above the text box still work, free and unlimited. AI answers reset tomorrow."
        }
        messages.append(ChatMessage(role: .system, text: message))
        if case CloudAssistantError.quotaExceeded(_, let tier) = error, tier == "free", !subscription.isPremium {
            showPaywall = true
        }
    }

    /// Loads the menus a request needs, cache-first (MenuRepository returns cached menus without network).
    private func snapshot(focus: QuickAction? = nil) async -> MenuSnapshot {
        let hall = context.hall ?? store.selectedHall
        var keys: [(Hall, Meal)] = []
        switch focus {
        case .planMyDay(let h)?:
            keys = [Meal.breakfast, .lunch, .dinner].map { (h, $0) }
        case .bestProtein(let h)?:
            keys = [(h, BerkeleyClock.closestMeal(to: BerkeleyClock.suggestedMeal(), among: store.availableMeals))]
        case .suggestMeal(let h, let m)?:
            keys = [(h, m)]
        case .whatsOpenNow?:
            let m = BerkeleyClock.closestMeal(to: BerkeleyClock.suggestedMeal(), among: store.availableMeals)
            keys = Hall.allCases.filter(\.isDiningHall).map { ($0, m) }
        default:
            keys = [Meal.breakfast, .lunch, .dinner].map { (hall, $0) }
                + Hall.allCases.filter { $0.isDiningHall && $0 != hall }.map { ($0, store.selectedMeal) }
        }
        var menus: [String: MenuEnvelope] = [:]
        for (h, m) in keys {
            if let menu = await store.fetchMenu(hall: h, meal: m) { menus[MenuSnapshot.key(h, m)] = menu }
        }
        return MenuSnapshot(menus: menus, goal: daily.goal, todayCalories: daily.todayCalories,
                            defaultHall: hall, availableMeals: store.availableMeals)
    }
}
