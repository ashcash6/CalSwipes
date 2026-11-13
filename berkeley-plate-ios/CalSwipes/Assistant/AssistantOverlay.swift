import SwiftUI

/// Floating "Ask" button shown on every main tab, plus the environment plumbing so any card can
/// offer "Ask about this meal".
struct AssistantOverlay: ViewModifier {
    let router: AssistantRouter
    let subscription: SubscriptionStore
    @State private var showChat = false

    func body(content: Content) -> some View {
        content
            .environment(router)
            .environment(subscription)
            .overlay(alignment: .bottomTrailing) {
                Button {
                    router.open(with: .none)
                    showChat = true
                } label: {
                    Image(systemName: "sparkles")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(CP.onAccent)
                        .frame(width: 56, height: 56)
                        .background(CP.navy, in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                }
                .accessibilityLabel("Ask CalSwipes assistant")
                .padding(.trailing, CP.sp20)
                .padding(.bottom, 64)   // sit above the tab bar
            }
            .sheet(isPresented: $showChat) {
                AssistantChatView(router: router, subscription: subscription)
                    .presentationDetents([.medium, .large])
            }
    }
}

extension View {
    func assistantOverlay(router: AssistantRouter, subscription: SubscriptionStore) -> some View {
        modifier(AssistantOverlay(router: router, subscription: subscription))
    }
}

/// "Ask about this meal" button for meal/plan cards. Presents its own chat sheet so it also works
/// inside other sheets (e.g. Make My Meal). Hidden if the assistant isn't in the environment.
struct AskAboutMealButton: View {
    let combo: MealCombo
    var hall: Hall? = nil
    var meal: Meal? = nil
    @Environment(AssistantRouter.self) private var router: AssistantRouter?
    @Environment(SubscriptionStore.self) private var subscription: SubscriptionStore?
    @State private var showChat = false

    var body: some View {
        if let router, let subscription {
            Button {
                router.open(with: .combo(combo, hall: hall, meal: meal))
                showChat = true
            } label: {
                Label("Ask about this meal", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(CP.navy)
            .sheet(isPresented: $showChat) {
                AssistantChatView(router: router, subscription: subscription)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}
