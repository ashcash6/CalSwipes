import Foundation

enum Hall: String, Codable, CaseIterable, Identifiable {
    case crossroads, cafe3 = "cafe-3", foothill, clarkKerr = "clark-kerr"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .crossroads: return "Crossroads"
        case .cafe3: return "Café 3"
        case .foothill: return "Foothill"
        case .clarkKerr: return "Clark Kerr"
        }
    }
}

enum Meal: String, Codable, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, lateNight = "late-night", brunch
    var id: String { rawValue }
    var title: String { rawValue.replacingOccurrences(of: "-", with: " ").capitalized }
}

struct MenuKey: Hashable {
    let hall: Hall
    let date: String
    let meal: Meal
    var cacheName: String { "v1-\(hall.rawValue)-\(date)-\(meal.rawValue)" }
}

enum BerkeleyClock {
    static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return result
    }
    static func serviceDate(_ instant: Date = Date()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func suggestedMeal(_ instant: Date = Date()) -> Meal {
        let hour = calendar.component(.hour, from: instant)
        if hour < 10 { return .breakfast }
        if hour < 16 { return .lunch }
        return .dinner
    }
}

struct Macros: Codable, Equatable {
    let caloriesKcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
}

struct Serving: Codable {
    let quantity: Double
    let unit: String
    let description: String?
    let weightG: Double?
    let weightBasis: String
    var label: String {
        let amount = quantity.formatted(.number.precision(.fractionLength(0...2)))
        let grams = weightG.map { " · \($0.formatted(.number.precision(.fractionLength(0...1)))) g" } ?? ""
        return "\(amount) \(unit)\(grams)"
    }
}

struct MenuItem: Codable, Identifiable {
    let id: String
    let name: String
    let categories: [String]
    let serving: Serving
    let macros: Macros?
    let nutritionStatus: String
    let referenceImageUrl: String?
    let warnings: [String]
}

struct MenuEnvelope: Codable {
    let schemaVersion: Int
    let hall: Hall
    let date: String
    let meal: Meal
    let status: String
    let sourceMealNames: [String]
    let items: [MenuItem]
    let revision: String
    let fetchedAt: Date
    let expiresAt: Date
    let sourceUrl: String
    let sourceSha256: String

    func matches(_ key: MenuKey) -> Bool {
        schemaVersion == 1 && hall == key.hall && date == key.date && meal == key.meal
    }
    func isFresh(at instant: Date = Date()) -> Bool {
        instant < expiresAt && expiresAt > fetchedAt && expiresAt.timeIntervalSince(fetchedAt) <= 36 * 3600
    }
}

struct AuthChallenge: Decodable {
    let challengeId: String
    let nonce: String
    let expiresAt: Date
}

struct Account: Codable {
    let id: String
    let createdAt: Date
}

struct AuthResult: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresAt: Date
    let user: Account
}

struct SavedSession: Codable {
    let accessToken: String
    let expiresAt: Date
    let account: Account
    let appleUserId: String
    let apiOrigin: String
}

enum JSONCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO date")
        }
        return decoder
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
