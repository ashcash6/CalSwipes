import Foundation

enum APIError: LocalizedError {
    case configuration, invalidResponse, expiredMenu
    case server(Int, String)
    var errorDescription: String? {
        switch self {
        case .configuration: return "Update API_BASE_URL in Config/App.xcconfig with your hosting URL, then rebuild the app."
        case .invalidResponse: return "The menu service returned an unexpected response. Please try again."
        case .expiredMenu: return "This downloaded menu has expired. Connect to refresh it."
        case .server(_, let message): return message
        }
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

    func send(path: String, query: [URLQueryItem] = [], etag: String? = nil) async throws -> HTTPResult {
        guard baseURL.scheme == "https", let host = baseURL.host,
              !host.hasSuffix(".invalid"), baseURL.user == nil, baseURL.password == nil else {
            throw APIError.configuration
        }
        // Split path on "/" so each segment is appended safely as its own path component.
        let withPath = path.split(separator: "/", omittingEmptySubsequences: true)
            .reduce(baseURL) { $0.appendingPathComponent(String($1)) }
        var components = URLComponents(url: withPath, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.configuration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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

    func post<Body: Encodable>(path: String, body: Body) async throws -> HTTPResult {
        guard baseURL.scheme == "https", let host = baseURL.host,
              !host.hasSuffix(".invalid"), baseURL.user == nil, baseURL.password == nil else {
            throw APIError.configuration
        }
        let withPath = path.split(separator: "/", omittingEmptySubsequences: true)
            .reduce(baseURL) { $0.appendingPathComponent(String($1)) }
        var request = URLRequest(url: withPath, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONCoding.encoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let domain = (object?["error"] as? [String: Any])?["message"] as? String
            let fallback = "The service is temporarily unavailable. Please try again."
            throw APIError.server(http.statusCode, domain ?? fallback)
        }
        return HTTPResult(data: data, response: http)
    }
}
