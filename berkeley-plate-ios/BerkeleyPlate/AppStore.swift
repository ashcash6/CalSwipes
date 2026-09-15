import AuthenticationServices
import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var session: SavedSession?
    @Published var isRestoring = true
    @Published var challenge: AuthChallenge?
    @Published var isSigningIn = false
    @Published var authError: String?
    @Published var selectedHall: Hall = .crossroads
    @Published var selectedMeal: Meal = BerkeleyClock.suggestedMeal()
    @Published var serviceDate = BerkeleyClock.serviceDate()
    @Published var menu: MenuEnvelope?
    @Published var isLoading = false
    @Published var menuError: String?
    @Published var isOffline = false
    @Published var cacheSaved = true
    @Published var selectedItemIds = Set<String>()
    private let api: APIClient
    private let menus: MenuRepository
    private let vault = SessionVault()
    private var activeKey: MenuKey?
    private var attemptedChallenge: AuthChallenge?
    private var preparing = false
    private var loadGeneration = UUID()

    var key: MenuKey { MenuKey(hall: selectedHall, date: serviceDate, meal: selectedMeal) }

    init() {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String) ?? ""
        let api = APIClient(baseURL: URL(string: configured) ?? URL(string: "https://api.example.invalid")!)
        self.api = api
        self.menus = MenuRepository(api: api)
    }

    func restore() async {
        defer { isRestoring = false }
        do {
            if let saved = try vault.load(), saved.expiresAt > Date(), saved.apiOrigin == api.origin {
                session = saved
                await checkCredential()
            } else { try vault.clear() }
        } catch { authError = error.localizedDescription }
        if session == nil { await prepareSignIn() }
    }

    func prepareSignIn() async {
        guard !preparing, !isSigningIn else { return }
        if let challenge, challenge.expiresAt.timeIntervalSinceNow > 30 { return }
        preparing = true
        defer { preparing = false }
        authError = nil
        challenge = nil
        do { challenge = try await api.challenge() }
        catch { authError = error.localizedDescription }
    }

    func configure(_ request: ASAuthorizationAppleIDRequest) {
        attemptedChallenge = challenge
        request.requestedScopes = [] // An account identifier is sufficient; no email/name collection.
        request.nonce = challenge?.nonce
        request.state = challenge?.challengeId
        isSigningIn = true
        authError = nil
    }

    func complete(_ result: Result<ASAuthorization, Error>) async {
        defer {
            isSigningIn = false
            attemptedChallenge = nil
            challenge = nil
        }
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let requested = attemptedChallenge,
                  credential.state == requested.challengeId,
                  requested.expiresAt > Date(),
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                throw APIError.server(401, "Your sign-in request expired. Please try again.")
            }
            let result = try await api.signIn(identityToken: identityToken, challengeId: requested.challengeId)
            let saved = SavedSession(accessToken: result.accessToken, expiresAt: result.expiresAt,
                                     account: result.user, appleUserId: credential.user, apiOrigin: api.origin)
            do { try vault.save(saved) }
            catch {
                try? await api.logout(token: saved.accessToken)
                throw error
            }
            session = saved
        } catch let error as ASAuthorizationError where error.code == .canceled {
            authError = nil
        } catch { authError = error.localizedDescription }
    }

    func checkCredential() async {
        guard let saved = session else { return }
        do {
            let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: saved.appleUserId)
            guard session?.accessToken == saved.accessToken else { return }
            if state != .authorized || saved.expiresAt <= Date() {
                try? await api.logout(token: saved.accessToken)
                try vault.clear()
                session = nil
                selectedItemIds = []
                return
            }
            _ = try await api.account(token: saved.accessToken)
        } catch let error as APIError where error.isUnauthorized {
            try? vault.clear()
            session = nil
            selectedItemIds = []
        } catch {
            // Preserve a still-valid on-device session during a network outage.
            // The backend independently enforces its expiry and revocation for protected requests.
            if saved.expiresAt <= Date() {
                try? vault.clear()
                session = nil
            }
        }
    }

    func foreground() async {
        serviceDate = BerkeleyClock.serviceDate()
        await checkCredential()
        if session == nil { await prepareSignIn() }
        else { await loadMenu() }
    }

    func signOut() async {
        guard let saved = session else { return }
        do {
            do { try await api.logout(token: saved.accessToken) }
            catch let error as APIError where error.isUnauthorized { /* Already revoked. */ }
            try vault.clear()
            session = nil
            menu = nil
            selectedItemIds = []
            await prepareSignIn()
        } catch { authError = "Connect to finish signing out securely. \(error.localizedDescription)" }
    }

    func loadMenu() async {
        let generation = UUID()
        loadGeneration = generation
        let requestedKey = key
        if activeKey != requestedKey { selectedItemIds = [] }
        activeKey = requestedKey
        menu = nil
        menuError = nil
        isLoading = true
        defer { if loadGeneration == generation { isLoading = false } }
        do {
            let result = try await menus.load(requestedKey)
            guard !Task.isCancelled, key == requestedKey, loadGeneration == generation else { return }
            menu = result.menu
            isOffline = result.isOffline
            cacheSaved = result.cacheSaved
            selectedItemIds.formIntersection(Set(result.menu.items.map(\.id)))
        } catch {
            guard !Task.isCancelled, key == requestedKey, loadGeneration == generation else { return }
            menuError = error.localizedDescription
        }
    }

    func toggle(_ id: String) {
        if selectedItemIds.contains(id) { selectedItemIds.remove(id) }
        else { selectedItemIds.insert(id) }
    }
}
