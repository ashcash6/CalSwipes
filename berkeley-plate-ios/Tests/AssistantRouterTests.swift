import XCTest
@testable import CalSwipes

/// Pure routing + Tier 1 tests (no network, no Foundation Models needed).
final class AssistantRouterTests: XCTestCase {

    private func route(_ text: String, onDevice: Bool = true, mealContext: Bool = false) -> AssistantRouter.Route {
        AssistantRouter.classify(text, onDeviceAvailable: onDevice, defaultHall: .crossroads, hasMealContext: mealContext)
    }

    func testChipsStayLocal() {
        XCTAssertEqual(route("plan my day at foothill"), .local(.planMyDay(.foothill)))
        XCTAssertEqual(route("what's open now?"), .local(.whatsOpenNow))
        XCTAssertEqual(route("best protein at cafe 3"), .local(.bestProtein(.cafe3)))
    }

    func testSafetyAndPolicyGoToCloud() {
        for q in ["is the tofu safe for my peanut allergy", "is there cross-contact with gluten",
                  "why is the beets calorie count so high", "what does the vegetarian label mean"] {
            guard case .cloud = route(q) else { return XCTFail("expected cloud for: \(q)") }
        }
    }

    func testScanGoesToCloud() {
        guard case .cloud = route("scan my tray") else { return XCTFail() }
    }

    func testFreeTextUsesOnDeviceWhenAvailable() {
        XCTAssertEqual(route("something light with chicken for dinner"), .onDevice)
        guard case .cloud = route("something light with chicken for dinner", onDevice: false) else { return XCTFail() }
    }

    func testMealContextSkipsChipShortcut() {
        // "protein" would normally map to a chip; with a meal card open we want the model to answer about that meal.
        XCTAssertEqual(route("is this high in protein?", mealContext: true), .onDevice)
    }

    func testBudgetMatchesMakeMyMealRule() {
        let b = LocalAssistantEngine.mealBudget(goal: nil, todayCalories: 0)
        XCTAssertEqual(b.caloriesKcal, 700, accuracy: 0.01)        // 2100 / 3
        let late = LocalAssistantEngine.mealBudget(goal: nil, todayCalories: 1900)
        XCTAssertEqual(late.caloriesKcal, 200, accuracy: 0.01)     // only what's left
    }

    func testBestProteinUsesLoadedMenu() throws {
        let url = Bundle(for: Self.self).url(forResource: "menu", withExtension: "json")!
        let menu = try JSONCoding.decoder().decode(MenuEnvelope.self, from: Data(contentsOf: url))
        let snap = MenuSnapshot(menus: [MenuSnapshot.key(menu.hall, menu.meal): menu], goal: nil, todayCalories: 0,
                                defaultHall: menu.hall, availableMeals: [menu.meal])
        let hits = LocalAssistantEngine.searchMenu(snap, query: "", hall: menu.hall, meal: menu.meal, limit: 5)
        let proteins = hits.map { $0.2.macros?.proteinG ?? 0 }
        XCTAssertEqual(proteins, proteins.sorted(by: >))
        XCTAssertTrue(hits.allSatisfy { $0.2.nutritionStatus == "published" })
    }

    func testSmallTalkStaysOnPhone() {
        for t in ["hi", "Hey!", "thanks", "what can you do?", "ok cool"] {
            XCTAssertEqual(route(t), .smallTalk, t)
            XCTAssertEqual(route(t, onDevice: false), .smallTalk, t)
        }
        XCTAssertNotEqual(route("vegan lunch?"), .smallTalk)
    }
}
