import Foundation

@MainActor
final class DailyStore: ObservableObject {
    @Published private(set) var goal: UserGoal?
    @Published private(set) var logs: [LoggedMeal] = []
    @Published private(set) var weightEntries: [WeightEntry] = []
    @Published var hasCompletedOnboarding = false

    private let goalKey = "userGoal_v1"
    private let logsKey = "mealLogs_v1"
    private let weightKey = "weightEntries_v1"
    private let onboardingKey = "onboardingDone_v1"

    init() { load() }

    var todayDate: String { BerkeleyClock.serviceDate() }
    var todayLogs: [LoggedMeal] { logs.filter { $0.date == todayDate } }
    var todayCalories: Double { todayLogs.reduce(0) { $0 + $1.macros.caloriesKcal } }
    var todayProtein: Double { todayLogs.reduce(0) { $0 + $1.macros.proteinG } }
    var todayCarbs: Double { todayLogs.reduce(0) { $0 + $1.macros.carbsG } }
    var todayFat: Double { todayLogs.reduce(0) { $0 + $1.macros.fatG } }

    // MARK: - Streak

    var currentStreak: Int {
        guard let goal = goal, goal.targetCalories > 0 else { return 0 }
        let target = goal.targetCalories
        let cal = BerkeleyClock.calendar
        var date = cal.startOfDay(for: Date())
        var streak = 0
        for _ in 0..<365 {
            let dateStr = BerkeleyClock.serviceDate(date)
            let dayLogs = logsForDate(dateStr)
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
        saveLogs()
    }

    func logManualMeal(name: String, macros: Macros) {
        let meal = LoggedMeal(
            id: UUID(), date: todayDate,
            hallTitle: "Packaged Food", mealTitle: "Label Scan",
            itemNames: [name], macros: macros, loggedAt: Date()
        )
        logs.append(meal)
        saveLogs()
    }

    func deleteLog(id: UUID) {
        logs.removeAll { $0.id == id }
        saveLogs()
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

    func saveGoal(_ goal: UserGoal) {
        self.goal = goal
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: onboardingKey)
        if let data = try? JSONCoding.encoder().encode(goal) {
            UserDefaults.standard.set(data, forKey: goalKey)
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
        if let data = UserDefaults.standard.data(forKey: weightKey),
           let saved = try? JSONCoding.decoder().decode([WeightEntry].self, from: data) {
            weightEntries = saved
        }
    }

    private func saveLogs() {
        if let data = try? JSONCoding.encoder().encode(logs) {
            UserDefaults.standard.set(data, forKey: logsKey)
        }
    }

    private func saveWeights() {
        if let data = try? JSONCoding.encoder().encode(weightEntries) {
            UserDefaults.standard.set(data, forKey: weightKey)
        }
    }
}
