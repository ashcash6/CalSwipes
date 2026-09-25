import SwiftUI

struct CalorieHistoryScreen: View {
    var daily: DailyStore
    @Environment(\.dismiss) private var dismiss

    // 12 pages: index 0 = 11 months ago, index 11 = current month
    @State private var pageIndex = 11
    @State private var selectedDate: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Swipeable month calendar
                TabView(selection: $pageIndex) {
                    ForEach(0..<12, id: \.self) { idx in
                        MonthCalendarPage(
                            monthOffset: idx - 11,
                            daily: daily,
                            selectedDate: $selectedDate
                        )
                        .tag(idx)
                        .padding(.horizontal, 20)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 370)

                Divider()

                // Day detail panel — always visible, defaults to today
                ScrollView {
                    DayDetailPanel(
                        date: selectedDate ?? daily.todayDate,
                        daily: daily
                    )
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground))
            }
            .background(PlateStyle.cream)
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { selectedDate = daily.todayDate }
    }
}

// MARK: - Month Calendar Page

private struct MonthCalendarPage: View {
    let monthOffset: Int
    var daily: DailyStore
    @Binding var selectedDate: String?

    private var cal: Calendar { BerkeleyClock.calendar }

    private var monthDate: Date {
        cal.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
    }

    private var monthTitle: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        fmt.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return fmt.string(from: monthDate)
    }

    private var cells: [DayInfo] {
        let comps = cal.dateComponents([.year, .month], from: monthDate)
        guard let firstDay = cal.date(from: comps),
              let dayRange = cal.range(of: .day, in: .month, for: firstDay) else { return [] }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "America/Los_Angeles")

        let firstWeekday = cal.component(.weekday, from: firstDay)
        var result: [DayInfo] = []

        for i in 0..<(firstWeekday - 1) {
            result.append(DayInfo(id: "lead-\(i)", dateString: nil, dayNumber: nil))
        }
        for dayNum in dayRange {
            if let date = cal.date(byAdding: .day, value: dayNum - 1, to: firstDay) {
                let str = fmt.string(from: date)
                result.append(DayInfo(id: str, dateString: str, dayNumber: dayNum))
            }
        }
        // Pad to 42 cells (6 full rows) so all months have the same height
        while result.count < 42 {
            result.append(DayInfo(id: "trail-\(result.count)", dateString: nil, dayNumber: nil))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(monthTitle)
                    .font(.title3.weight(.semibold))
                Spacer()
                // Swipe hint on current month
                if monthOffset == 0 {
                    Text("Swipe for past months")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
                // Weekday headers
                ForEach(0..<7, id: \.self) { i in
                    Text(["S","M","T","W","T","F","S"][i])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                // Day cells
                ForEach(cells) { info in
                    DayCellView(info: info, daily: daily, selectedDate: $selectedDate)
                }
            }
        }
    }
}

// MARK: - Day Info model

private struct DayInfo: Identifiable {
    let id: String
    let dateString: String?
    let dayNumber: Int?
}

// MARK: - Day Cell

private struct DayCellView: View {
    let info: DayInfo
    var daily: DailyStore
    @Binding var selectedDate: String?

    private var calories: Double {
        guard let d = info.dateString else { return 0 }
        return daily.caloriesForDate(d)
    }
    private var target: Double { daily.goal?.targetCalories ?? 0 }
    private var fraction: Double {
        guard target > 0, calories > 0 else { return 0 }
        return min(1.0, calories / target)
    }
    private var hasData: Bool { calories > 0 }
    private var isToday: Bool { info.dateString == daily.todayDate }
    private var isSelected: Bool {
        guard let d = info.dateString else { return false }
        return selectedDate == d
    }
    private var isFuture: Bool {
        guard let d = info.dateString else { return false }
        return d > daily.todayDate
    }

    var body: some View {
        if let dateStr = info.dateString, let dayNum = info.dayNumber {
            Button {
                guard !isFuture else { return }
                selectedDate = dateStr
            } label: {
                ZStack {
                    // Fill circle for days with data
                    if hasData {
                        Circle().fill(fillColor)
                    }
                    // Selection ring
                    if isSelected {
                        Circle().strokeBorder(PlateStyle.green, lineWidth: 2.5)
                    } else if isToday && !hasData {
                        Circle().strokeBorder(PlateStyle.green.opacity(0.55), lineWidth: 1.5)
                    }
                    Text("\(dayNum)")
                        .font(.system(size: 13, weight: hasData ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(textColor)
                }
                .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .opacity(isFuture ? 0.25 : 1.0)
        } else {
            Color.clear.frame(width: 38, height: 38)
        }
    }

    private var fillColor: Color {
        guard target > 0 else { return PlateStyle.green.opacity(0.45) }
        if fraction >= 1.0 { return PlateStyle.green }
        if fraction >= 0.75 { return PlateStyle.green.opacity(0.70) }
        if fraction >= 0.5  { return PlateStyle.green.opacity(0.45) }
        return PlateStyle.green.opacity(0.20)
    }

    private var textColor: Color {
        if isFuture { return .secondary }
        if fraction >= 0.75 { return .white }
        if isToday { return PlateStyle.green }
        return .primary
    }
}

// MARK: - Day Detail Panel

private struct DayDetailPanel: View {
    let date: String
    var daily: DailyStore

    private var displayDate: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "America/Los_Angeles")
        guard let d = fmt.date(from: date) else { return date }
        return d.formatted(date: .long, time: .omitted)
    }

    var body: some View {
        let calories = daily.caloriesForDate(date)
        let protein  = daily.proteinForDate(date)
        let carbs    = daily.carbsForDate(date)
        let fat      = daily.fatForDate(date)

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(displayDate)
                    .font(.headline)
                if date == daily.todayDate {
                    Text("Today")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(PlateStyle.green, in: Capsule())
                }
            }

            if calories == 0 {
                Text("No meals logged")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                // Macro summary row
                HStack(spacing: 0) {
                    MacroStat(label: "Calories", value: Int(calories), unit: "kcal", color: PlateStyle.green)
                    MacroStat(label: "Protein",  value: Int(protein),  unit: "g",    color: PlateStyle.green)
                    MacroStat(label: "Carbs",    value: Int(carbs),    unit: "g",    color: PlateStyle.gold)
                    MacroStat(label: "Fat",      value: Int(fat),      unit: "g",    color: .orange)
                }

                if let goal = daily.goal {
                    VStack(spacing: 10) {
                        HistoryMacroBar("Calories", calories, goal.targetCalories, "kcal")
                        HistoryMacroBar("Protein",  protein,  goal.targetProteinG,  "g")
                        HistoryMacroBar("Carbs",    carbs,    goal.targetCarbsG,    "g")
                        HistoryMacroBar("Fat",      fat,      goal.targetFatG,      "g")
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Macro Stat

private struct MacroStat: View {
    let label: String
    let value: Int
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(color)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - History Macro Bar

private struct HistoryMacroBar: View {
    let label: String
    let value: Double
    let target: Double
    let unit: String

    init(_ label: String, _ value: Double, _ target: Double, _ unit: String) {
        self.label = label; self.value = value; self.target = target; self.unit = unit
    }

    private var ratio: Double { guard target > 0 else { return 0 }; return value / target }
    private var fraction: Double { min(1.0, ratio) }
    private var barColor: Color {
        if label == "Calories" {
            if ratio > 1.05 { return .orange }
            if ratio >= 0.9  { return PlateStyle.green }
            return .yellow
        }
        return ratio >= 0.9 ? PlateStyle.green : .yellow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value)) / \(Int(target)) \(unit)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(barColor.opacity(0.12)).frame(height: 6)
                    Capsule().fill(barColor)
                        .frame(width: geo.size.width * fraction, height: 6)
                }
            }
            .frame(height: 6)
        }
    }
}
