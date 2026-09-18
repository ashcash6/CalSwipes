import Foundation

enum Hall: String, Codable, CaseIterable, Identifiable {
    case crossroads
    case cafe3 = "cafe-3"
    case foothill
    case clarkKerr = "clark-kerr"
    case goldenBear = "golden-bear"
    case bearMarket = "bear-market"
    case cubMarket = "cub-market"
    case localXDesign = "local-x-design"
    case theDen = "the-den"
    case qualcommCafe = "qualcomm-cafe"
    case gatewayCafe = "gateway-cafe"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .crossroads: return "Crossroads"
        case .cafe3: return "Café 3"
        case .foothill: return "Foothill"
        case .clarkKerr: return "Clark Kerr"
        case .goldenBear: return "Golden Bear Café"
        case .bearMarket: return "Bear Market"
        case .cubMarket: return "Cub Market"
        case .localXDesign: return "Local x Design"
        case .theDen: return "The Den"
        case .qualcommCafe: return "Qualcomm Café"
        case .gatewayCafe: return "Gateway Café"
        }
    }
}

enum Meal: String, Codable, CaseIterable, Identifiable {
    case breakfast, brunch, lunch, allDay = "all-day", dinner, lateNight = "late-night"
    var id: String { rawValue }
    var title: String { rawValue.replacingOccurrences(of: "-", with: " ").capitalized }
    var typicalHours: String {
        switch self {
        case .breakfast: return "7:00 – 10:00 AM"
        case .brunch:    return "10:00 AM – 2:00 PM"
        case .lunch:     return "11:00 AM – 3:00 PM"
        case .allDay:    return "All day"
        case .dinner:    return "5:00 – 9:00 PM"
        case .lateNight: return "9:00 PM – 12:00 AM"
        }
    }
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
        let minute = calendar.component(.minute, from: instant)
        if hour >= 7 && hour < 11 { return .breakfast }
        if hour >= 11 && (hour < 16 || (hour == 16 && minute < 30)) { return .lunch }
        return .dinner
    }

    /// Returns the best meal from `available` for the current time.
    /// Prefers `natural` if it's available; otherwise picks the available meal
    /// whose representative time is closest to the current time.
    static func closestMeal(to natural: Meal, among available: [Meal], at instant: Date = Date()) -> Meal {
        guard !available.isEmpty else { return natural }
        if available.contains(natural) { return natural }
        let current = calendar.component(.hour, from: instant) * 60
                    + calendar.component(.minute, from: instant)
        return available.min(by: { abs(mealMinutes($0) - current) < abs(mealMinutes($1) - current) }) ?? natural
    }

    private static func mealMinutes(_ meal: Meal) -> Int {
        switch meal {
        case .breakfast: return 8 * 60 + 30
        case .brunch:    return 10 * 60 + 30
        case .lunch:     return 12 * 60 + 30
        case .allDay:    return 12 * 60
        case .dinner:    return 18 * 60 + 30
        case .lateNight: return 22 * 60
        }
    }
}

struct AvailableMealsResponse: Decodable {
    let available: [Meal]
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
    let allergens: [String]
    let dietaryTags: [String]
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
