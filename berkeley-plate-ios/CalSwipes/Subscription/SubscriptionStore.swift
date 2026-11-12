import Foundation
import Observation
import StoreKit
import os

private let subLog = Logger(subsystem: "CalSwipes", category: "Subscription")

/// CalSwipes+ (auto-renewing monthly subscription) via StoreKit 2.
///
/// Product id comes from Info.plist key `CalSwipesPlusProductID` (set PLUS_PRODUCT_ID in
/// Config/App.xcconfig). It must match the product you create in App Store Connect.
/// Promo: Info.plist key `PromoFreeUntil` (YYYY-MM-DD, from PROMO_FREE_UNTIL). Until that date
/// (inclusive, Berkeley time) everyone is treated as premium in the app. The backend has its own
/// PROMO_FREE_UNTIL; keep them the same.
///
/// The app's entitlement check is only a UI hint. The server decides real limits, and it
/// doesn't trust the premium claim until it verifies the signed transaction (TODO, see IOS_ASSISTANT.md).
@Observable @MainActor
final class SubscriptionStore {
    static let placeholderProductID = "com.ashkon.calswipes.plus.monthly"

    let productID: String
    let promoFreeUntil: String?
    private(set) var product: Product?
    private(set) var hasActiveSubscription = false
    /// JWS of the latest verified transaction, sent to the backend for server-side verification.
    private(set) var latestSignedTransaction: String?
    private(set) var purchaseError: String?
    private(set) var isPurchasing = false
    private var updatesTask: Task<Void, Never>?

    init(bundle: Bundle = .main) {
        let configured = (bundle.object(forInfoDictionaryKey: "CalSwipesPlusProductID") as? String) ?? ""
        productID = configured.isEmpty || configured.hasPrefix("$(") ? Self.placeholderProductID : configured
        let promo = (bundle.object(forInfoDictionaryKey: "PromoFreeUntil") as? String) ?? ""
        promoFreeUntil = promo.isEmpty || promo.hasPrefix("$(") ? nil : promo
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let tx) = update { await tx.finish() }
                await self?.refreshEntitlements()
            }
        }
    }

    /// True during the promo window (string compare works for YYYY-MM-DD).
    var promoActive: Bool {
        guard let promoFreeUntil else { return false }
        return BerkeleyClock.serviceDate() <= promoFreeUntil
    }

    var isPremium: Bool { hasActiveSubscription || promoActive }

    var displayPrice: String { product?.displayPrice ?? "$1.99" }

    func load() async {
        do {
            product = try await Product.products(for: [productID]).first
            if product == nil { subLog.error("Product \(self.productID, privacy: .public) not found in App Store Connect / StoreKit config") }
        } catch {
            subLog.error("Product load failed: \(error.localizedDescription, privacy: .public)")
        }
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        var active = false
        var jws: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result, tx.productID == productID, tx.revocationDate == nil else { continue }
            if let expiry = tx.expirationDate, expiry < Date() { continue }
            active = true
            jws = result.jwsRepresentation
        }
        hasActiveSubscription = active
        latestSignedTransaction = jws
    }

    func purchase() async {
        guard let product else {
            purchaseError = "CalSwipes+ isn't available right now. Try again later."
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let tx) = verification {
                    await tx.finish()
                    await refreshEntitlements()
                } else {
                    purchaseError = "Apple couldn't verify the purchase."
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func restore() async {
        // Qualified: the app has its own `AppStore` class.
        try? await StoreKit.AppStore.sync()
        await refreshEntitlements()
    }
}
