import Foundation

enum APIError: LocalizedError {
    case configuration, invalidResponse, expiredMenu
    case server(Int, String)
    var errorDescription: String? {
        switch self {
        case .configuration: return "Set your HTTPS backend address in Config/Local.xcconfig, then rebuild the app."
        case .invalidResponse: return "The menu service returned an unexpected response. Please try again."
        case .expiredMenu: return "This downloaded menu has expired. Connect to refresh it."
        case .server(_, let message): return message
        }
    }
    var isUnauthorized: Bool {
        if case .server(401, _) = self { return true }
        return false
    }
}

struct HTTPResult {
    let data: Data
    let response: HTTPURLResponse
}

actor APIClient {
    nonisolated let origin: String
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.origin = baseURL.absoluteString
        self.session = session
    }

    func send(path: String, method: String = "GET", body: Data? = nil,
              token: String? = nil, query: [URLQueryItem] = [], etag: String? = nil) async throws -> HTTPResult {
        guard baseURL.scheme == "https", let host = baseURL.host,
              !host.hasSuffix(".invalid"), baseURL.user == nil, baseURL.password == nil else {
            throw APIError.configuration
        }
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.configuration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 304 else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = object?["detail"] as? String
            let domain = (object?["error"] as? [String: Any])?["message"] as? String
            let fallback = http.statusCode == 404 ? "No menu has been published for this selection yet." : "The service is temporarily unavailable. Please try again."
            throw APIError.server(http.statusCode, detail ?? domain ?? fallback)
        }
        return HTTPResult(data: data, response: http)
    }

    func challenge() async throws -> AuthChallenge {
        let result = try await send(path: "v1/auth/challenge", method: "POST")
        return try JSONCoding.decoder().decode(AuthChallenge.self, from: result.data)
    }

    func signIn(identityToken: String, challengeId: String) async throws -> AuthResult {
        let body = try JSONSerialization.data(withJSONObject: ["challenge_id":challengeId, "identity_token":identityToken])
        let result = try await send(path: "v1/auth/apple", method: "POST", body: body)
        return try JSONCoding.decoder().decode(AuthResult.self, from: result.data)
    }

    func account(token: String) async throws -> Account {
        let result = try await send(path: "v1/auth/me", token: token)
        return try JSONCoding.decoder().decode(Account.self, from: result.data)
    }

    func logout(token: String) async throws {
        _ = try await send(path: "v1/auth/logout", method: "POST", token: token)
    }
}
