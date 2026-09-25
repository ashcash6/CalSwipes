import SwiftUI

/// Paywall for the "Scan your meal" feature.
/// Currently never shown (AppStore.scanPaywallActive == false).
/// Wire the Subscribe button to StoreKit when you're ready to go live.
struct ScanPaywallSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: CP.sp12) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(CP.navy)
                    .padding(.top, CP.sp40)

                Text("Unlock Meal Scanning")
                    .font(.title2.weight(.bold))

                Text("Take a photo of your dining hall tray and AI identifies every item — matched directly to today's menu.")
                    .font(.subheadline)
                    .foregroundStyle(CP.textSec)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, CP.sp24)
            }
            .padding(.bottom, CP.sp32)

            // Feature list
            VStack(alignment: .leading, spacing: CP.sp16) {
                PaywallFeatureRow(icon: "sparkles",        text: "AI identifies food from your photo")
                PaywallFeatureRow(icon: "list.bullet",     text: "Matches against today's live menu")
                PaywallFeatureRow(icon: "checkmark.seal",  text: "Nutrition straight from Berkeley Dining")
                PaywallFeatureRow(icon: "arrow.triangle.2.circlepath", text: "Correct mistakes with one tap")
            }
            .padding(.horizontal, CP.sp24)
            .padding(.bottom, CP.sp32)

            Spacer()

            // CTA — wire to StoreKit purchase when activating
            VStack(spacing: CP.sp12) {
                Button {
                    // TODO: initiate StoreKit purchase here
                } label: {
                    Text("Subscribe to Premium")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CP.sp14)
                }
                .buttonStyle(.borderedProminent)
                .tint(CP.navy)
                .padding(.horizontal, CP.sp24)

                Button("Maybe later") { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(CP.textSec)
            }
            .padding(.bottom, CP.sp32)
        }
        .background(CP.bg)
    }
}

private struct PaywallFeatureRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: CP.sp12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CP.navy)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }
}
