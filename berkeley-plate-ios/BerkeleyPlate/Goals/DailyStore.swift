import Foundation
import Observation
import os

private let storeLog = Logger(subsystem: "BerkeleyPlate", category: "DailyStore")

@Observable @MainActor
final class DailyStore {
    private(set) var goal: UserGoal?
    private(set) var logs: [LoggedMeal] = []
    private(set) var weightEntries: [WeightEntry] = []
    private(set) var recurringFoods: [RecurringFood] = []
    var hasCompletedOnboarding = false

    // Cached streak — computed once on data change, not on every view render
    private(set) var currentStreak: Int = 0

    private let goalKey           = "userGoal_v1"
    private let logsKey           = "mealLogs_v1"
    private let weightKey         = "weightEntries_v1"
    private let onboardingKey     = "onboardingDone_v1"
    private let recurringFoodsKey = "recurringFoods_v1"

    init() { load() }

    var todayDate: String { BerkeleyClock.serviceDate() }

    // Cached: recomputed only when logs mutate, not on every view render pass
    private(set) var todayLogs: [LoggedMeal] = []
    private(set) var todayCalories: Double = 0
    private(set) var todayProtein: Double  = 0
    private(set) var todayCarbs: Double    = 0
    private(set) var todayFat: Double      = 0

    // MARK: - Weekly totals (rolling 7 days including today)

    var weeklyDaysLogged: Int {
        let cal = BerkeleyClock.calendar
        return (0..<7).filter { offset in
            guard let d = cal.date(byAdding: .day, value: -offset, to: Date()) else { return false }
            return !logsForDate(BerkeleyClock.serviceDate(d)).isEmpty
        }.count
    }
    var weeklyCalories: Double { weeklySum(\.caloriesKcal) }
    var weeklyProtein: Double  { weeklySum(\.proteinG) }
    var weeklyCarbs: Double    { weeklySum(\.carbsG) }
    var weeklyFat: Double      { weeklySum(\.fatG) }

    private func weeklySum(_ kp: KeyPath<Macros, Double>) -> Double {
        let cal = BerkeleyClock.calendar
        return (0..<7).reduce(0.0) { total, offset in
            guard let d = cal.date(byAdding: .day, value: -offset, to: Date()) else { return total }
            return total + logsForDate(BerkeleyClock.serviceDate(d)).reduce(0.0) { $0 + $1.macros[keyPath: kp] }
        }
    }

    var recentWeightEntries: [WeightEntry] {
        let cal = BerkeleyClock.calendar
        guard let cutoff = cal.date(byAdding: .day, value: -29, to: Date()) else {
            return weightEntries.sorted { $0.date < $1.date }
        }
        let cutoffStr = BerkeleyClock.serviceDate(cutoff)
        return weightEntries
            .filter { $0.date >= cutoffStr }
            .sorted { $0.date < $1.date }
    }

    func logMeal(result: ScanResult, menu: MenuEnvelope) {
        let meal = LoggedMeal(
            id: UUID(),
            date: todayDate,
            hallTitle: menu.hall.title,
            mealTitle: menu.meal.title,
            itemNames: result.lines.map(\.item.name),
            macros: result.total,
            loggedAt: Date()
        )
        logs.append(meal)
        updateTodayCache()
        saveLogs()
        updateStreak()
    }

    func logManualMeal(name: String, macros: Macros) {
        let meal = LoggedMeal(
            id: UUID(), date: todayDate,
            hallTitle: "Packaged Food", mealTitle: "Label Scan",
            itemNames: [name], macros: macros, loggedAt: Date()
        )
        logs.append(meal)
        updateTodayCache()
        saveLogs()
        updateStreak()
    }

    func deleteLog(id: UUID) {
        logs.removeAll { $0.id == id }
        updateTodayCache()
        saveLogs()
        updateStreak()
    }

    func updateLog(id: UUID, name: String, macros: Macros) {
        guard let index = logs.firstIndex(where: { $0.id == id }) else { return }
        let existing = logs[index]
        logs[index] = LoggedMeal(
            id: existing.id,
            date: existing.date,
            hallTitle: existing.hallTitle,
            mealTitle: existing.mealTitle,
            itemNames: [name],
            macros: macros,
            loggedAt: existing.loggedAt
        )
        updateTodayCache()
        saveLogs()
        updateStreak()
    }

    func logWeight(_ weightLbs: Double) {
        weightEntries.removeAll { $0.date == todayDate }
        weightEntries.append(WeightEntry(id: UUID(), date: todayDate, weightLbs: weightLbs, loggedAt: Date()))
        saveWeights()
    }

    func deleteWeightEntry(id: UUID) {
        weightEntries.removeAll { $0.id == id }
        saveWeights()
    }

    func updateWeightEntry(id: UUID, weightLbs: Double) {
        guard let idx = weightEntries.firstIndex(where: { $0.id == id }) else { return }
        let existing = weightEntries[idx]
        weightEntries[idx] = WeightEntry(id: existing.id, date: existing.date,
                                         weightLbs: weightLbs, loggedAt: existing.loggedAt)
        saveWeights()
    }

    func saveGoal(_ goal: UserGoal) {
        let prevCalories = self.goal?.targetCalories
        self.goal = goal
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: onboardingKey)
        // Skip streak recompute when only dietary restrictions changed — allergens/tags
        // don't affect targetCalories, so the streak result would be identical.
        if prevCalories != goal.targetCalories {
            updateStreak()
        }
        let key = goalKey
        Task.detached(priority: .utility) {
            if let data = try? JSONCoding.encoder().encode(goal) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    func skipOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: onboardingKey)
    }

    func logsForDate(_ date: String) -> [LoggedMeal] {
        logs.filter { $0.date == date }
    }

    func caloriesForDate(_ date: String) -> Double {
        logsForDate(date).reduce(0) { $0 + $1.macros.caloriesKcal }
    }

    func proteinForDate(_ date: String) -> Double {
        logsForDate(date).reduce(0) { $0 + $1.macros.proteinG }
    }

    func carbsForDate(_ date: String) -> Double {
        logsForDate(date).reduce(0) { $0 + $1.macros.carbsG }
    }

    func fatForDate(_ date: String) -> Double {
        logsForDate(date).reduce(0) { $0 + $1.macros.fatG }
    }

    // MARK: - Recurring Foods

    func addRecurringFood(_ food: RecurringFood) {
        recurringFoods.append(food)
        saveRecurringFoods()
    }

    func updateRecurringFood(_ food: RecurringFood) {
        guard let idx = recurringFoods.firstIndex(where: { $0.id == food.id }) else { return }
        recurringFoods[idx] = food
        saveRecurringFoods()
    }

    func deleteRecurringFood(id: UUID) {
        recurringFoods.removeAll { $0.id == id }
        saveRecurringFoods()
    }

    // MARK: - Today cache

    private func updateTodayCache() {
        let date = todayDate
        var cal = 0.0, pro = 0.0, carb = 0.0, fat = 0.0
        let filtered = logs.filter { $0.date == date }
        for m in filtered {
            cal  += m.macros.caloriesKcal
            pro  += m.macros.proteinG
            carb += m.macros.carbsG
            fat  += m.macros.fatG
        }
        todayLogs     = filtered
        todayCalories = cal
        todayProtein  = pro
        todayCarbs    = carb
        todayFat      = fat
    }

    // MARK: - Streak (computed in background, result written back on main)

    private func updateStreak() {
        guard let goal, goal.targetCalories > 0 else { currentStreak = 0; return }
        let target = goal.targetCalories
        let logsCopy = logs  // snapshot value types on main before going background
        Task {
            let t0 = Date()
            let streak = await Task.detached(priority: .utility) {
                DailyStore.computeStreak(logs: logsCopy, target: target)
            }.value
            self.currentStreak = streak
            storeLog.debug("updateStreak=\(streak) in \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 1))ms")
        }
    }

    private nonisolated static func computeStreak(logs: [LoggedMeal], target: Double) -> Int {
        let cal = BerkeleyClock.calendar
        var date = cal.startOfDay(for: Date())
        var streak = 0
        for _ in 0..<365 {
            let parts = cal.dateComponents([.year, .month, .day], from: date)
            let dateStr = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
            let dayLogs = logs.filter { $0.date == dateStr }
            if dayLogs.isEmpty {
                if cal.isDateInToday(date) {
                    date = cal.date(byAdding: .day, value: -1, to: date) ?? date
                    continue
                } else { break }
            }
            let calories = dayLogs.reduce(0.0) { $0 + $1.macros.caloriesKcal }
            if abs(calories - target) / target <= 0.05 { streak += 1 } else { break }
            date = cal.date(byAdding: .day, value: -1, to: date) ?? date
        }
        return streak
    }

    private func load() {
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: onboardingKey)
        if let data = UserDefaults.standard.data(forKey: goalKey),
           let saved = try? JSONCoding.decoder().decode(UserGoal.self, from: data) {
            goal = saved
        }
        if let data = UserDefaults.standard.data(forKey: logsKey),
           let saved = try? JSONCoding.decoder().decode([LoggedMeal].self, from: data) {
            logs = saved
        }
        updateTodayCache()
        if let data = UserDefaults.standard.data(forKey: weightKey),
           let saved = try? JSONCoding.decoder().decode([WeightEntry].self, from: data) {
            weightEntries = saved
        }
        if let data = UserDefaults.standard.data(forKey: recurringFoodsKey),
           let saved = try? JSONCoding.decoder().decode([RecurringFood].self, from: data) {
            recurringFoods = saved
        }
        updateStreak()
    }

    private func saveLogs() {
        let snapshot = logs
        let key = logsKey
        Task.detached(priority: .utility) {
            if let data = try? JSONCoding.encoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private func saveWeights() {
        let snapshot = weightEntries
        let key = weightKey
        Task.detached(priority: .utility) {
            if let data = try? JSONCoding.encoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private func saveRecurringFoods() {
        let snapshot = recurringFoods
        let key = recurringFoodsKey
        Task.detached(priority: .utility) {
            if let data = try? JSONCoding.encoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
}
