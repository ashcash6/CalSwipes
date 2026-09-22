import Foundation
import Observation
import SwiftUI
import os

private let appLog = Logger(subsystem: "BerkeleyPlate", category: "AppStore")

/// Task identity for MenuScreen's task(id:) modifier.
/// Including `validated` ensures the task fires when mealValidated first becomes true.
/// Including `version` ensures foreground() always triggers a reload even on same-day
/// re-entry where hall/date/meal are unchanged.
struct MenuLoadTrigger: Hashable {
    let key: MenuKey
    let validated: Bool
    let version: Int
}

@Observable @MainActor
final class AppStore {
    var selectedHall: Hall = .crossroads
    var selectedMeal: Meal = BerkeleyClock.suggestedMeal()
    var serviceDate = BerkeleyClock.serviceDate()
    var menu: MenuEnvelope?
    var isLoading = false
    var menuError: String?
    var isOffline = false
    var cacheSaved = true
    /// True once foreground() has confirmed the correct meal for this hall.
    private(set) var mealValidated = false
    private(set) var availableMeals: [Meal] = []
    /// Incremented on every foreground() call so task(id: menuLoadTrigger) always fires,
    /// including same-day re-foreground where hall/date/meal haven't changed.
    private(set) var loadVersion = 0
    private let api: APIClient
    private let menus: MenuRepository
    private var activeKey: MenuKey?
    private var loadGeneration = UUID()
    private var foregroundInProgress = false
    /// In-flight available-meals background fetch. Cancelled before spawning a newer one
    /// so stale results for an old hall/date cannot overwrite current state.
    private var availableMealsTask: Task<Void, Never>?

    var key: MenuKey { MenuKey(hall: selectedHall, date: serviceDate, meal: selectedMeal) }
    var menuLoadTrigger: MenuLoadTrigger { .init(key: key, validated: mealValidated, version: loadVersion) }

    init() {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String) ?? ""
        let api = APIClient(baseURL: URL(string: configured) ?? URL(string: "https://api.example.invalid")!)
        self.api = api
        self.menus = MenuRepository(api: api)
    }

    func foreground() async {
        guard !foregroundInProgress else {
            appLog.info("foreground() skipped — already in progress")
            return
        }
        foregroundInProgress = true
        defer { foregroundInProgress = false }

        let t0 = Date()
        appLog.info("foreground() started at \(t0.timeIntervalSinceReferenceDate, format: .fixed(precision: 3))")

        let prevDate = serviceDate
        let prevHall = selectedHall
        serviceDate = BerkeleyClock.serviceDate()

        let tLoc = Date()
        if let detected = await LocationService.shared.nearestHall() {
            selectedHall = detected
        }
        appLog.info("foreground() location: \(Date().timeIntervalSince(tLoc) * 1000, format: .fixed(precision: 0))ms → hall=\(self.selectedHall.rawValue)")

        // Restore cached available-meals for the current hall/date so the picker is
        // correct immediately without waiting for a network round-trip.
        // If no cache exists and context changed, clear stale data from the old hall/date.
        if let cached = cachedAvailableMeals(hall: selectedHall, date: serviceDate) {
            availableMeals = cached
        } else if serviceDate != prevDate || selectedHall != prevHall {
            availableMeals = []
        }

        // Unblock the menu immediately — do NOT wait for available-meals.
        // closestMeal falls back to `natural` when availableMeals is empty, which is safe.
        // On subsequent foreground calls availableMeals still holds the last fetched value,
        // so the initial meal guess is correct without a network round-trip.
        let natural = BerkeleyClock.suggestedMeal()
        selectedMeal = BerkeleyClock.closestMeal(to: natural, among: availableMeals)
        mealValidated = true
        loadVersion += 1  // Guarantees task(id: menuLoadTrigger) fires even on identical key
        // task(id: menuLoadTrigger) fires here → loadMenu() starts without waiting

        // Fetch available-meals in background with a short timeout.
        // SUCCESS: update availableMeals and correct selectedMeal if the server's answer
        //          differs from the locally-inferred guess.
        // FAILURE: leave availableMeals and selectedMeal exactly as they are.
        //          We do NOT write [] on failure — that would incorrectly imply a successful
        //          "zero available meals" response rather than a network error.
        let hall = selectedHall
        let date = serviceDate
        availableMealsTask?.cancel()
        availableMealsTask = Task {
            let tMeals = Date()
            do {
                let available = try await fetchAvailableMeals(hall: hall, date: date, timeout: 4)
                guard !Task.isCancelled else { return }
                cacheAvailableMeals(available, hall: hall, date: date)
                availableMeals = available
                appLog.info("foreground() bg available-meals (\(Date().timeIntervalSince(tMeals) * 1000, format: .fixed(precision: 0))ms): [\(available.map(\.rawValue).joined(separator: ", "))]")
                let best = BerkeleyClock.closestMeal(to: natural, among: available)
                if best != selectedMeal {
                    // Only redirect if the current menu isn't already published for this hall/date.
                    // This prevents a redundant reload when the inferred meal was already correct.
                    let currentIsGood = menu?.hall == selectedHall
                        && menu?.date == serviceDate
                        && menu?.status == "published"
                    if !currentIsGood {
                        selectedMeal = best
                    }
                }
            } catch {
                // Network timeout, server error, or task cancellation — preserve existing selection.
                appLog.error("foreground() bg available-meals failed (\(Date().timeIntervalSince(tMeals) * 1000, format: .fixed(precision: 0))ms): \(error.localizedDescription)")
            }
        }

        appLog.info("foreground() returned in \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 0))ms")
    }

    /// Changes the selected hall and starts loading its menu immediately.
    /// Available-meals for the new hall is fetched in the background; the menu load
    /// is NOT blocked on that response. On failure the clock-inferred meal is preserved.
    func selectHall(_ hall: Hall) async {
        guard hall != selectedHall else { return }
        let t0 = Date()
        selectedHall = hall
        // Restore cached meals for the new hall so the picker is correct before the
        // background fetch arrives. Falls back to [] when no cache entry exists yet.
        availableMeals = cachedAvailableMeals(hall: hall, date: serviceDate) ?? []
        // task(id: menuLoadTrigger) fires → loadMenu() starts immediately for the new hall

        let date = serviceDate
        let natural = BerkeleyClock.suggestedMeal()
        availableMealsTask?.cancel()
        availableMealsTask = Task {
            let tMeals = Date()
            do {
                let available = try await fetchAvailableMeals(hall: hall, date: date, timeout: 4)
                guard !Task.isCancelled else { return }
                cacheAvailableMeals(available, hall: hall, date: date)
                availableMeals = available
                appLog.info("selectHall available-meals (\(Date().timeIntervalSince(tMeals) * 1000, format: .fixed(precision: 0))ms) for \(hall.rawValue): [\(available.map(\.rawValue).joined(separator: ", "))]")
                let best = BerkeleyClock.closestMeal(to: natural, among: available)
                if best != selectedMeal {
                    selectedMeal = best
                }
            } catch {
                // Timeout/failure: leave availableMeals=[] and selectedMeal unchanged.
                appLog.error("selectHall available-meals failed (\(Date().timeIntervalSince(tMeals) * 1000, format: .fixed(precision: 0))ms): \(error.localizedDescription)")
            }
        }
        appLog.info("selectHall(\(hall.rawValue)) returned in \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 1))ms")
    }

    func selectMeal(_ meal: Meal) async {
        guard meal != selectedMeal else { return }
        selectedMeal = meal
        // task(id: menuLoadTrigger) fires → loadMenu()
    }

    private func cachedAvailableMeals(hall: Hall, date: String) -> [Meal]? {
        guard let strings = UserDefaults.standard.stringArray(forKey: "availMeals-\(hall.rawValue)-\(date)") else { return nil }
        let meals = strings.compactMap { Meal(rawValue: $0) }
        return meals.isEmpty ? nil : meals
    }

    private func cacheAvailableMeals(_ meals: [Meal], hall: Hall, date: String) {
        UserDefaults.standard.set(meals.map(\.rawValue), forKey: "availMeals-\(hall.rawValue)-\(date)")
    }

    /// Fetch available meal periods for any hall, using UserDefaults cache when warm.
    /// Called by CreatePlanSheet to pre-load all halls when the sheet opens.
    func cachedOrFetchMeals(for hall: Hall, date: String) async -> [Meal]? {
        if let cached = cachedAvailableMeals(hall: hall, date: date) { return cached }
        do {
            let meals = try await fetchAvailableMeals(hall: hall, date: date, timeout: 6)
            cacheAvailableMeals(meals, hall: hall, date: date)
            return meals
        } catch { return nil }
    }

    private func fetchAvailableMeals(hall: Hall, date: String, timeout: TimeInterval = 4) async throws -> [Meal] {
        let result = try await api.send(
            path: "v1/available-meals",
            query: [URLQueryItem(name: "hall", value: hall.rawValue),
                    URLQueryItem(name: "date", value: date)],
            timeout: timeout
        )
        return try JSONCoding.decoder().decode(AvailableMealsResponse.self, from: result.data).available
    }

    func loadMenu() async {
        let generation = UUID()
        loadGeneration = generation
        let requestedKey = key
        activeKey = requestedKey
        // Do NOT clear menu — keep the previous content visible while the replacement loads.
        // The view uses isLoading=true to show a subtle refresh indicator alongside the old menu
        // rather than blanking it with a spinner.
        menuError = nil
        isLoading = true
        let t0 = Date()
        appLog.info("loadMenu() started for \(requestedKey.hall.rawValue)/\(requestedKey.date)/\(requestedKey.meal.rawValue)")
        defer {
            if loadGeneration == generation {
                isLoading = false
                appLog.info("loadMenu() finished in \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 0))ms (gen match=true)")
            } else {
                appLog.info("loadMenu() superseded after \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 0))ms")
            }
        }
        do {
            let result = try await menus.load(requestedKey)
            guard !Task.isCancelled, key == requestedKey, loadGeneration == generation else { return }
            menu = result.menu
            isOffline = result.isOffline
            cacheSaved = result.cacheSaved
        } catch {
            guard !Task.isCancelled, key == requestedKey, loadGeneration == generation else { return }
            menuError = error.localizedDescription
            appLog.error("loadMenu() error: \(error.localizedDescription)")
        }
    }
}
