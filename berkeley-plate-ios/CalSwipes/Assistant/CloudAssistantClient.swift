import Foundation

/// Tier 3: the CalSwipes backend's /assistant endpoints (which forward to the private agent service).
/// Each call counts against the user's daily quota on the server.
struct CloudAssistantClient {
    let baseURL: URL?

    init(bundle: Bundle = .main) {
        let configured = (bundle.object(forInfoDictionaryKey: "APIBaseURL") as? String) ?? ""
        let url = URL(string: configured)
        baseURL = (url?.scheme == "https" && !(url?.host?.hasSuffix(".invalid") ?? true)) ? url : nil
    }

    struct AskResponse: Decodable {
        let answer: String
        let citations: [String]?
        let cached: Bool?
        let quota: Quota?
    }
    struct ScanResponse: Decodable {
        let matches: [ScanMatch]
        let quota: Quota?
    }
    struct Quota: Decodable {
        let tier: String
        let limit: Int
        let remaining: Int
    }
    private struct AskBody: Encodable {
        let question: String
        let hall: String
        let meal: String
        let date: String
    }

    func ask(_ question: String, context: AssistantContext, entitlement: EntitlementHeaders) async throws -> AskResponse {
        guard let baseURL else { throw CloudAssistantError.notConfigured }
        var q = question
        if let summary = context.mealSummary { q = "About this meal: \(summary)\n\(question)" }
        var req = URLRequest(url: baseURL.appendingPathComponent("assistant").appendingPathComponent("ask"),
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        entitlement.apply(to: &req)
        req.httpBody = try JSONEncoder().encode(AskBody(question: String(q.prefix(1000)),
                                                        hall: context.hall?.rawValue ?? "",
                                                        meal: context.meal?.rawValue ?? "",
                                                        date: BerkeleyClock.serviceDate()))
        return try await send(req, as: AskResponse.self)
    }

    func scan(jpeg: Data, hall: Hall, meal: Meal, entitlement: EntitlementHeaders) async throws -> ScanResponse {
        guard let baseURL else { throw CloudAssistantError.notConfigured }
        let boundary = "calswipes-\(UUID().uuidString)"
        var req = URLRequest(url: baseURL.appendingPathComponent("assistant").appendingPathComponent("scan"),
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        entitlement.apply(to: &req)
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("hall", hall.rawValue)
        field("meal", meal.rawValue)
        field("date", BerkeleyClock.serviceDate())
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"tray.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        return try await send(req, as: ScanResponse.self)
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if (200..<300).contains(http.statusCode) { return try decoder.decode(T.self, from: data) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let err = obj?["error"] as? [String: Any]
        let message = (err?["message"] as? String) ?? "The assistant is temporarily unavailable. Please try again."
        let tier = ((obj?["quota"] as? [String: Any])?["tier"] as? String) ?? "free"
        switch (http.statusCode, err?["code"] as? String) {
        case (429, "user_cap"?): throw CloudAssistantError.quotaExceeded(message: message, tier: tier)
        case (503, "spend_cap"?): throw CloudAssistantError.budgetExhausted(message: message)
        default: throw CloudAssistantError.server(message)
        }
    }
}

/// Headers that tell the backend who's asking and whether they claim CalSwipes+.
/// The server ignores the premium claim until it verifies the signed transaction (see IOS_ASSISTANT.md).
struct EntitlementHeaders {
    var isSubscriber: Bool
    var signedTransaction: String?

    func apply(to req: inout URLRequest) {
        req.setValue(DeviceIdentity.id, forHTTPHeaderField: "X-CalSwipes-Device")
        if isSubscriber {
            req.setValue("premium", forHTTPHeaderField: "X-CalSwipes-Entitlement")
            if let jws = signedTransaction { req.setValue(jws, forHTTPHeaderField: "X-CalSwipes-Transaction") }
        }
    }
}
