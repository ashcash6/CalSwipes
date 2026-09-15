# Berkeley Plate — Phase 4 guided segmentation

SwiftUI app for iOS 17+ with native Sign in with Apple, revocable backend sessions, real menu nutrition, offline caching, photo capture and tap-guided MobileSAM plate/food outlines. It connects to the Phase 2 backend. See [Phase 4](PHASE4.md) for model provenance, conversion commands and device acceptance checks.

**Status:** Segmentation source and pretrained packages are supplied; on-device acceptance is pending. Model integrity, original prompt-weight equality and PyTorch export traces were checked on Windows. Xcode builds, XCTests, Apple sign-in, CoreML execution and iPhone performance have not been run. Syntax parsing does not verify SDK types or rendering. Classification, depth/portions and meal logging remain later phases.

## Configure the backend

In the backend's `.env`, keep the Phase 1 database/scraper settings and add:

```dotenv
APPLE_BUNDLE_ID=edu.yourorganization.BerkeleyPlate
SESSION_SECRET=your-random-secret-at-least-32-characters-long
```

Generate a secret locally with `python -c "import secrets; print(secrets.token_urlsafe(48))"`. Do not put it in the iOS project. Rebuild/restart the backend with `docker compose up --build -d`; migration `0002` adds accounts, one-use challenges and sessions. Without Docker, install the updated `requirements.lock`, set the environment variables and run `alembic upgrade head` before starting the API.

The iPhone needs a reachable **HTTPS** API URL. The supplied backend Compose port is localhost-only and does not publish or host a service for you. Use your own HTTPS deployment/reverse proxy. Do not weaken App Transport Security to send Apple tokens over plaintext. Authentication routes return 503 until both auth settings are configured.

## Create the Xcode project on a Mac

Requires Xcode 16 or newer with an iOS 17+ SDK and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig
# Edit Local.xcconfig: your App ID, Developer Team and HTTPS API address.
xcodegen generate
open BerkeleyPlate.xcodeproj
```

`Local.xcconfig` is ignored by Git. The `$()` in `https:/$()/...` is intentional: it prevents the double slash from starting an xcconfig comment. The resulting build setting is an ordinary HTTPS URL. The default `.invalid` URL fails explicitly; it is not a demonstration backend.

In your Apple Developer account, register an explicit App ID matching `APP_BUNDLE_ID` and enable **Sign in with Apple**. Select that signing team in Xcode and let Xcode obtain the provisioning profile. The project supplies the Sign in with Apple entitlement. `APPLE_BUNDLE_ID` on the server must match the app's bundle ID exactly. No Apple client secret/private key is required for this phase's native ID-token validation flow; refresh-token exchange/revocation is not implemented.

Choose a supported iPhone and Run. For UI/build tests, an iPhone simulator may open the shell with a clear simulator label. It is not evidence of camera/depth support. Physical devices are checked at launch for iPhone form factor and LiDAR or at least two physical rear cameras. The latter is only the spec's coarse shell gate; metric-depth feasibility is still a Phase C prerequisite.

## Run tests

```sh
xcodegen generate
xcodebuild -list -project BerkeleyPlate.xcodeproj
xcrun simctl list devices available
# Replace the placeholder with an available iPhone simulator UUID:
xcodebuild test \
  -project BerkeleyPlate.xcodeproj \
  -scheme BerkeleyPlate \
  -destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-UUID' \
  CODE_SIGNING_ALLOWED=NO
```

Debug XCTests cover menu/auth/cache contracts, capture, pipeline validation, cancellation, SAM geometry, normalized padding, RGB orientation, prompt parity and trained CoreML execution. Missing trained models fail the integration test. The separate grayscale diagnostic skips if not generated; follow [its export instructions](MODEL_INTEGRATION.md). These tests do not replace physical camera testing. The macOS CI verifies model integrity, generates the diagnostic, runs tests and builds Release; it has not been dispatched here.

## App files

```text
BerkeleyPlate/
  BerkeleyPlateApp.swift  Entry point and runtime hardware gate
  Views.swift            Onboarding, menu cards, search, selection and account
  AppStore.swift         Apple flow, session restoration and screen state
  APIClient.swift        HTTPS API requests and typed errors
  Models.swift           Version 1 menu/auth contracts and Berkeley clock
  MenuRepository.swift   ETag revalidation and freshness-bounded disk cache
  SessionVault.swift     Device-only Keychain credentials
  Camera/                Capture session, preview and image preparation
  Inference/             Stage contracts and CoreML runtime
  Scan/                  Camera review, progress, result and cancellation UI
Config/                  Local build settings, generated plist/entitlements
Tests/                   XCTest suite and real backend response fixture
project.yml              Reproducible XcodeGen project definition
```

There are no third-party iOS runtime libraries. The app uses Apple frameworks, including SwiftUI, AuthenticationServices, AVFoundation, ImageIO and CoreML. Pretrained MobileSAM packages and prompt weights are bundled under Resources/Models, with licenses and a file-hash lock. An optional untrained diagnostic remains test-only.

## Behavior and scope

- The native Apple button receives a server nonce and state, and the app exchanges Apple's ID token for a seven-day backend JWT. Keychain credentials are device-only and available while unlocked. No email/name scope is requested.
- Apple credential state and server session validity are checked on foreground. During a connection failure, a still-valid saved session can display fresh cached public menus. A confirmed expired/revoked session sends the user back to onboarding.
- Sign-out calls the backend first. If offline, the UI asks the user to reconnect to complete server revocation; it does not falsely claim that the server session was revoked.
- Hall/meal changes clear preselection. Search filters the real menu. Selecting an item only marks an expected food; it does not log a meal or imply a measured portion.
- Menus are isolated by API origin, schema, hall, Berkeley service date and meal. HTTP 304 reuses the validated document. Connection failures can use a fresh saved menu, but an explicit 404/503 never becomes a cached success. Expired menus are not presented as current.
- App foreground advances the service date in America/Los_Angeles. Meal choice initially follows a time-based suggestion and remains user-controlled. Location access is not requested.
- The camera captures RGB stills and retains prepared photos only in memory. Capture/review works offline with a fresh downloaded menu. Closing/retaking cancels analysis and discards its state. Model downloading and durable deferred processing are not implemented yet.
- Production capture provides guided plate and food masks with user confirmation. It does not identify foods or estimate portions. Debug builds expose a separately labeled one-serving example using preselected items; it is never described as a measured photo estimate or saved to history/HealthKit.
- Missing meal periods, missing nutrition and unknown serving weights remain explicit. Displayed numbers are per source serving. Font scaling, VoiceOver labels and light/dark colors are supported in source; visual/accessibility review on a device is still required.
- A public privacy/support URL, account deletion with Apple revocation, server-to-server Apple notifications, App Store icon/screenshots and signed TestFlight delivery remain release work. Do not submit this development shell as a finished App Store app.

## Device acceptance checks

1. Confirm the API endpoint is HTTPS, configured with the same App ID, and currently serving all halls.
2. Sign in with a real Apple account; cancel once, then retry successfully. Relaunch and confirm Keychain restoration.
3. Switch all four halls/meal periods; confirm per-serving nutrition against Berkeley's menu and no cross-menu selection leakage.
4. Download one menu, enable airplane mode and reopen that menu. Confirm the offline label and that uncached menus fail clearly.
5. Simulate expired data; confirm it is not silently presented as fresh. Restore network and refresh.
6. Sign out; confirm the old JWT is rejected by `/v1/auth/me` and the device returns to onboarding.
7. Revoke Sign in with Apple in system account settings; foreground the app and confirm logout behavior.
8. Check large text, VoiceOver, light/dark appearance and supported/unsupported physical hardware.
