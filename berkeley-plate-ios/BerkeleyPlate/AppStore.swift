import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var selectedHall: Hall = .crossroads
    @Published var selectedMeal: Meal = BerkeleyClock.suggestedMeal()
    @Published var serviceDate = BerkeleyClock.serviceDate()
    @Published var menu: MenuEnvelope?
    @Published var isLoading = false
    @Published var menuError: String?
    @Published var isOffline = false
    @Published var cacheSaved = true
    @Published var selectedItemIds = Set<String>()
    /// True once `foreground()` has run its available-meals check and set
    /// the correct meal. Used to gate MenuScreen's task so the initial render
    /// never loads with a meal that might not be published for this hall.
    @Published private(set) var mealValidated = false
    private let api: APIClient
    private let menus: MenuRepository
    private var activeKey: MenuKey?
    private var loadGeneration = UUID()

    var key: MenuKey { MenuKey(hall: selectedHall, date: serviceDate, meal: selectedMeal) }

    init() {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String) ?? ""
        let api = APIClient(baseURL: URL(string: configured) ?? URL(string: "https://api.example.invalid")!)
        self.api = api
        self.menus = MenuRepository(api: api)
    }

    func foreground() async {
        serviceDate = BerkeleyClock.serviceDate()
        let natural = BerkeleyClock.suggestedMeal()
        let available = (try? await fetchAvailableMeals(hall: selectedHall, date: serviceDate)) ?? []
        selectedMeal = BerkeleyClock.closestMeal(to: natural, among: available)
        mealValidated = true
        await loadMenu()
    }

    /// Changes the hall and recalculates the best meal for the new hall's
    /// published periods. Both properties are set before returning so
    /// the key change fires only once, avoiding a double menu load.
    func selectHall(_ hall: Hall) async {
        guard hall != selectedHall else { return }
        let natural = BerkeleyClock.suggestedMeal()
        let available = (try? await fetchAvailableMeals(hall: hall, date: serviceDate)) ?? []
        let best = BerkeleyClock.closestMeal(to: natural, among: available)
        // Assign both synchronously so the computed key changes in one SwiftUI cycle.
        selectedMeal = best
        selectedHall = hall
    }

    private func fetchAvailableMeals(hall: Hall, date: String) async throws -> [Meal] {
        let result = try await api.send(
            path: "v1/available-meals",
            query: [URLQueryItem(name: "hall", value: hall.rawValue),
                    URLQueryItem(name: "date", value: date)]
        )
        return try JSONCoding.decoder().decode(AvailableMealsResponse.self, from: result.data).available
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
