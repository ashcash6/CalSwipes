import SwiftUI

/// CalSwipes+ paywall, shown when a free user hits the daily cloud-AI cap.
struct CalSwipesPlusPaywall: View {
    var subscription: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: CP.sp20) {
            Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(CP.navy).padding(.top, CP.sp32)
            Text("CalSwipes+").font(.title.weight(.bold))
            Text("More AI help every day. Quick actions and meal plans stay free forever.")
                .font(.subheadline).foregroundStyle(CP.textSec).multilineTextAlignment(.center)
                .padding(.horizontal, CP.sp24)

            VStack(alignment: .leading, spacing: CP.sp12) {
                Row(icon: "bubble.left.and.text.bubble.right", text: "30 cloud AI answers a day (free: 3)")
                Row(icon: "camera.viewfinder", text: "5 tray scans a day (free: 1)")
                Row(icon: "iphone", text: "On-device answers stay unlimited")
            }
            .padding(.horizontal, CP.sp24)

            Spacer()

            if subscription.promoActive {
                Text("Everyone gets CalSwipes+ limits free during the launch promo.")
                    .font(.footnote).foregroundStyle(CP.textSec).multilineTextAlignment(.center)
            }
            if let error = subscription.purchaseError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button {
                Task {
                    await subscription.purchase()
                    if subscription.hasActiveSubscription { dismiss() }
                }
            } label: {
                Text(subscription.hasActiveSubscription ? "You're subscribed" : "Subscribe for \(subscription.displayPrice)/month")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, CP.sp14)
            }
            .buttonStyle(.borderedProminent).tint(CP.navy)
            .disabled(subscription.isPurchasing || subscription.hasActiveSubscription)
            .padding(.horizontal, CP.sp24)

            HStack(spacing: CP.sp20) {
                Button("Restore purchases") { Task { await subscription.restore() } }
                Button("Not now") { dismiss() }
            }
            .font(.subheadline).foregroundStyle(CP.textSec)

            Text("Renews monthly until cancelled. Manage or cancel anytime in Settings > Apple ID > Subscriptions.")
                .font(.caption2).foregroundStyle(CP.textSec).multilineTextAlignment(.center)
                .padding(.horizontal, CP.sp24).padding(.bottom, CP.sp20)
        }
        .background(CP.bg)
        .task { if subscription.product == nil { await subscription.load() } }
    }

    private struct Row: View {
        let icon: String
        let text: String
        var body: some View {
            HStack(spacing: CP.sp12) {
                Image(systemName: icon).foregroundStyle(CP.navy).frame(width: 24)
                Text(text).font(.subheadline)
            }
        }
    }
}
