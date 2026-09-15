import XCTest
@testable import BerkeleyPlate

final class MenuTests: XCTestCase {
    func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "menu", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testRealBackendContract() throws {
        let menu = try JSONCoding.decoder().decode(MenuEnvelope.self, from: fixture())
        XCTAssertEqual(menu.hall, .foothill)
        XCTAssertEqual(menu.date, "2026-09-14")
        XCTAssertEqual(menu.items.count, 17)
        let croissant = try XCTUnwrap(menu.items.first { $0.id == "1542" })
        XCTAssertEqual(croissant.macros?.caloriesKcal, 173.18)
        XCTAssertEqual(croissant.macros?.proteinG, 4.25)
        XCTAssertEqual(try XCTUnwrap(croissant.serving.weightG), 42.5242846875, accuracy: 0.0001)
        XCTAssertTrue(menu.isFresh(at: menu.fetchedAt))
        XCTAssertFalse(menu.isFresh(at: menu.expiresAt))
    }

    func testBerkeleyDateAcrossUTCMidnight() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-15T01:00:00Z"))
        XCTAssertEqual(BerkeleyClock.serviceDate(instant), "2026-09-14")
        XCTAssertEqual(BerkeleyClock.suggestedMeal(instant), .dinner)
    }

    func testCacheRoundTripAndKeyIsolation() throws {
        let menu = try JSONCoding.decoder().decode(MenuEnvelope.self, from: fixture())
        let cached = CachedMenu(menu: menu, etag: "\"test\"")
        let data = try JSONCoding.encoder().encode(cached)
        let decoded = try JSONCoding.decoder().decode(CachedMenu.self, from: data)
        XCTAssertEqual(decoded.etag, cached.etag)
        XCTAssertTrue(decoded.menu.matches(MenuKey(hall: .foothill, date: "2026-09-14", meal: .breakfast)))
        XCTAssertFalse(decoded.menu.matches(MenuKey(hall: .crossroads, date: "2026-09-14", meal: .breakfast)))
        XCTAssertFalse(decoded.menu.matches(MenuKey(hall: .foothill, date: "2026-09-15", meal: .breakfast)))
    }

    func testNullableNutritionAndWeight() throws {
        let data = Data("""
        {"id":"unknown","name":"Side dish","categories":[],"serving":{"quantity":1,"unit":"cup","weight_g":null,"description":null,"weight_basis":"unknown"},"macros":null,"nutrition_status":"missing","reference_image_url":null,"warnings":["serving_weight_unknown"]}
        """.utf8)
        let item = try JSONCoding.decoder().decode(MenuItem.self, from: data)
        XCTAssertNil(item.macros)
        XCTAssertNil(item.serving.weightG)
    }

    func testSessionVaultCodingDoesNotDropAppleID() throws {
        let saved = SavedSession(accessToken: "test", expiresAt: Date(timeIntervalSince1970: 1900000000),
            account: Account(id: "account", createdAt: Date(timeIntervalSince1970: 1800000000)),
            appleUserId: "apple-user", apiOrigin: "https://api.example.com")
        let decoded = try JSONCoding.decoder().decode(SavedSession.self, from: JSONCoding.encoder().encode(saved))
        XCTAssertEqual(decoded.appleUserId, saved.appleUserId)
        XCTAssertEqual(decoded.expiresAt, saved.expiresAt)
        XCTAssertEqual(decoded.apiOrigin, saved.apiOrigin)
    }
}
