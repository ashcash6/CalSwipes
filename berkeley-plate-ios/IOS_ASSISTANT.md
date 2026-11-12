# CalSwipes assistant + CalSwipes+ (iOS)

What this adds to the app:

- **AI assistant everywhere**: a floating sparkles button on every tab opens the chat. Meal cards in Plan My Day and Make My Meal get an **Ask about this meal** button.
- **Three-tier routing** (`Assistant/AssistantRouter.swift`), cheapest first:
  1. **Instant (no AI)**: chips like "Best protein at Crossroads", "Plan my day", "What's open now?", "Suggest lunch". Answered from cached menus + `LocalRecommender`. Free, offline.
  2. **On-device AI**: Apple Foundation Models (iOS 26, Apple Intelligence devices). The model calls local tools (`searchMenu`, `recommendMeal`, `planDay`) that run `LocalRecommender` on cached menus, so numbers always come from Berkeley Dining data. Free and private.
  3. **Cloud AI**: tray scans, allergen/policy/dining-info questions, complex requests, or anything the on-device model declines. Calls `POST /assistant/ask` / `POST /assistant/scan` on the CalSwipes API, which forwards to the agent service. Counts against the daily quota.
- **CalSwipes+** (`Subscription/`): StoreKit 2 monthly subscription scaffold ($1.99/mo placeholder) with a paywall that appears when a free user hits the daily cloud cap.

Daily cloud limits (enforced by the server): free 3 asks + 1 scan, CalSwipes+ 30 asks + 5 scans. During the launch promo (`PROMO_FREE_UNTIL`) everyone gets CalSwipes+ limits. Tier 1 and Tier 2 are unlimited.

Nothing was removed from the app. Quick Meal (Make My Meal), Plan My Day, Menu, scanning, logging and history all work exactly as before.

## Files

New (all under `CalSwipes/`, so XcodeGen picks them up automatically):

| File | What it does |
|---|---|
| `Assistant/AssistantModels.swift` | Chat message, quick actions, tiers, context, errors |
| `Assistant/AssistantRouter.swift` | Picks the tier, runs the request, loads menus cache-first |
| `Assistant/LocalAssistantEngine.swift` | Tier 1 answers + the logic behind Tier 2 tools |
| `Assistant/OnDeviceAssistant.swift` | Tier 2: Foundation Models session + tools (guarded by `#if canImport` and `#available(iOS 26)`) |
| `Assistant/CloudAssistantClient.swift` | Tier 3 HTTP client for `/assistant/ask` and `/assistant/scan` |
| `Assistant/DeviceIdentity.swift` | Random per-install id in the Keychain (for server-side caps) |
| `Assistant/AssistantChatView.swift` | Chat UI, chips, photo picker for tray scans |
| `Assistant/AssistantOverlay.swift` | Floating button + `AskAboutMealButton` |
| `Subscription/SubscriptionStore.swift` | StoreKit 2 products, purchase, entitlements, promo |
| `Subscription/CalSwipesPlusPaywall.swift` | CalSwipes+ paywall |
| `Tests/AssistantRouterTests.swift` | Routing + Tier 1 unit tests (test target) |

Edited (small, additive):

| File | Change |
|---|---|
| `CalSwipesApp.swift` | `MainTabView` creates `SubscriptionStore` + `AssistantRouter`, mounts the floating button |
| `Goals/PlanMyDayScreen.swift` | `MealComboCard` gets optional `hall`/`meal` and an "Ask about this meal" button |
| `Goals/DashboardScreen.swift` | Make My Meal combo detail gets an "Ask about this meal" button |
| `Config/Info.plist`, `project.yml`, `Config/App.xcconfig` | `CalSwipesPlusProductID` and `PromoFreeUntil` keys |

## Xcode steps

1. **Pull the branch** and regenerate the project (the repo uses XcodeGen, which includes everything under `CalSwipes/` and `Tests/`):
   ```bash
   git checkout cloud-run-agent
   cd berkeley-plate-ios
   xcodegen generate
   ```
   If you don't use XcodeGen: drag the `CalSwipes/Assistant` and `CalSwipes/Subscription` folders into the project (check **CalSwipes** target membership, "Create groups"), and add `Tests/AssistantRouterTests.swift` to **CalSwipesTests**.
2. **Use Xcode 26.** Foundation Models needs the iOS 26 SDK. The deployment target can stay iOS 17: on older iOS (or devices without Apple Intelligence) Tier 2 is skipped automatically. On Xcode 16 the `#if canImport(FoundationModels)` blocks compile out, so the app still builds, just without Tier 2.
3. **Add the In-App Purchase capability**: target CalSwipes → Signing & Capabilities → + Capability → In-App Purchase.
4. **Local StoreKit testing** (optional, before App Store Connect is set up): File → New → File → StoreKit Configuration File → name it `CalSwipesPlus.storekit` → + → Add Auto-Renewable Subscription → group "CalSwipes+", product id `com.ashkon.calswipes.plus.monthly`, price 1.99, duration 1 month. Then Product → Scheme → Edit Scheme → Run → Options → StoreKit Configuration → `CalSwipesPlus.storekit`.
5. **Build and run tests** (⌘U). `AssistantRouterTests` should pass.
6. **Try it**: tap the sparkles button → tap "Plan my day" (instant), type "something high protein for dinner" (on-device on an iOS 26 Apple Intelligence device, otherwise cloud), tap "Scan my tray" (cloud).

## App Store Connect setup

1. My Apps → CalSwipes → Monetization → **Subscriptions** → create group **CalSwipes+**.
2. Add subscription: reference name "CalSwipes+ Monthly", **product id** `com.ashkon.calswipes.plus.monthly` (or your own; then set `PLUS_PRODUCT_ID` in `Config/App.xcconfig` to match), duration 1 month, price $1.99 (tier), localized display name + description, review screenshot of the paywall.
3. Agreements, Tax, and Banking must be active (Paid Apps agreement) before subscriptions work outside the sandbox.
4. Submit the subscription **with** the app version that contains the paywall (first subscriptions must be reviewed alongside a build).
5. Add a link to your Terms of Use (EULA) and Privacy Policy in the app description / paywall metadata. Apple requires both for auto-renewable subscriptions. The CalSwipes website repo is the natural place for them.
6. Update the privacy policy and App Privacy labels: tray photos and questions are sent to the CalSwipes backend and Google's Gemini (Vertex AI) for processing.

## Launch promo

Set the same date in both places:
- App: `PROMO_FREE_UNTIL = 2026-12-31` in `Config/App.xcconfig` (shows promo copy on the paywall, treats everyone as premium in the UI).
- Server: `PROMO_FREE_UNTIL=2026-12-31` env var on `calswipes-api` (actually enforces premium limits for everyone).

## TODO before charging money

- **Server-side receipt verification.** The app sends `X-CalSwipes-Entitlement: premium` plus the signed transaction (`X-CalSwipes-Transaction`, a JWS). The server currently **ignores** the claim (`TRUST_CLIENT_ENTITLEMENT=0`), so paying users get free limits outside the promo. Add verification with Apple's App Store Server Library (Python: `app-store-server-library`): verify the JWS chain, check `productId`, `expiresDate`, `revocationDate`, then call `gate.reserve(..., premium_verified=True)`. Also handle App Store Server Notifications v2 for renewals/refunds.
- **Stronger user identity.** Caps are keyed on a Keychain device id, which a determined user could reset. Options: App Attest (DeviceCheck framework) to prove requests come from the real app, or wire the backend's existing Sign in with Apple sessions (`app/auth.py`, not yet mounted in `app/main.py`). Until then, the per-IP cap and the global daily spend cap (default $1/day) bound abuse.
- **Logging scanned items.** Scan results show matches + confidence in the chat. Wiring "confirm, set servings, log" into `DailyStore` (and saving confirmations as eval labels, see `agent/evals/scan/README.md`) is the next step.

## Unverified (couldn't compile Swift in the build environment)

- None of this has been compiled. Expect a few small fixes on first build.
- Foundation Models: `Tool`, `@Generable`, `@Guide(description:)`, `LanguageModelSession(tools:instructions:)` and `respond(to:)` were checked against developer.apple.com. `SystemLanguageModel.default.availability` / `.available` was **not** re-checked; only the `.available` case is matched.
- `Tool.call(arguments:)` is declared `@concurrent` in Apple's docs; the tools here use a plain `async throws` method. If Xcode 26 complains, add `@concurrent` (or `nonisolated`).
- StoreKit 2 calls (`Product.products(for:)`, `purchase()`, `Transaction.currentEntitlements`, `Transaction.updates`, `AppStore.sync()`) are standard since iOS 15. `StoreKit.AppStore` is fully qualified because the app has its own `AppStore` class.
