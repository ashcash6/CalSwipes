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
        selectedMeal = BerkeleyClock.suggestedMeal()
        await loadMenu()
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
