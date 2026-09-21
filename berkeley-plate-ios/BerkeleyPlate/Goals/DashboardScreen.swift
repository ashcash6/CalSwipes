import SwiftUI

struct DashboardScreen: View {
    var store: AppStore
    var daily: DailyStore
    @State private var scanRequest: ScanRequest?
    @State private var showGoalSheet = false
    @State private var showDietarySheet = false
    @State private var showRecurringFoods = false
    @State private var showHistory = false
    @State private var showLabelScan = false
    @State private var showManualEntry = false
    @State private var editingMeal: LoggedMeal?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    dateHeader
                    progressSection
                    weeklySummarySection
                    scanCard
                    if !daily.todayLogs.isEmpty { mealsSection }
                }
                .padding(20)
            }
            .background(PlateStyle.cream)
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showDietarySheet = true
                    } label: {
                        let hasRestrictions = !(daily.goal?.allergens.isEmpty ?? true)
                            || !(daily.goal?.dietaryTags.isEmpty ?? true)
                        Image(systemName: hasRestrictions ? "fork.knife.circle.fill" : "fork.knife.circle")
                    }
                    .accessibilityLabel("Dietary restrictions")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        Button {
                            showRecurringFoods = true
                        } label: {
                            Image(systemName: "repeat.circle")
                        }
                        .accessibilityLabel("Recurring foods")
                        Button("Edit") { showGoalSheet = true }
                            .fontWeight(.medium)
                    }
                }
            }
        }
        .sheet(isPresented: $showGoalSheet) {
            OnboardingScreen(store: daily, editMode: true)
        }
        .sheet(isPresented: $showDietarySheet) {
            DietaryRestrictionsScreen(store: daily)
        }
        .sheet(isPresented: $showRecurringFoods) {
            RecurringFoodsScreen(daily: daily)
        }
        .sheet(isPresented: $showHistory) {
            CalorieHistoryScreen(daily: daily)
        }
        .fullScreenCover(item: $scanRequest) { request in
            ScanScreen(request: request, onLog: { result in
                daily.logMeal(result: result, menu: request.menu)
            })
        }
        .fullScreenCover(isPresented: $showLabelScan) {
            NutritionLabelScanScreen { name, macros in
                daily.logManualMeal(name: name, macros: macros)
            }
        }
        .sheet(isPresented: $showManualEntry) {
            ManualMealEntryScreen(store: daily)
        }
        .sheet(item: $editingMeal) { meal in
            EditMealSheet(meal: meal) { name, macros in
                daily.updateLog(id: meal.id, name: name, macros: macros)
            }
        }
    }

    // MARK: - Date header with streak

    private var dateHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(daily.todayDate)
                    .font(.caption.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(PlateStyle.green)
                    .textCase(.uppercase)
                Text(greetingText)
                    .font(.system(.title2, design: .serif, weight: .semibold))
            }
            Spacer()
            if daily.currentStreak > 0 {
                StreakBadge(streak: daily.currentStreak)
            }
        }
    }

    private var greetingText: String {
        let hour = BerkeleyClock.calendar.component(.hour, from: Date())
        switch hour {
        case 0..<12: return "Good morning."
        case 12..<17: return "Good afternoon."
        default: return "Good evening."
        }
    }

    // MARK: - Progress section

    @ViewBuilder
    private var progressSection: some View {
        if let goal = daily.goal {
            GoalProgressCard(
                calories: daily.todayCalories,
                targetCalories: goal.targetCalories,
                protein: daily.todayProtein,
                targetProtein: goal.targetProteinG,
                carbs: daily.todayCarbs,
                targetCarbs: goal.targetCarbsG,
                fat: daily.todayFat,
                targetFat: goal.targetFatG,
                onTapRing: { showHistory = true }
            )
        } else {
            SimpleCalorieCard(calories: daily.todayCalories, onSetGoal: { showGoalSheet = true },
                              onTapHistory: { showHistory = true })
        }
    }

    // MARK: - Weekly summary

    @ViewBuilder
    private var weeklySummarySection: some View {
        if let goal = daily.goal, daily.weeklyDaysLogged > 0 {
            WeeklySummaryCard(
                daysLogged: daily.weeklyDaysLogged,
                weeklyCalories: daily.weeklyCalories,
                weeklyProtein: daily.weeklyProtein,
                weeklyCarbs: daily.weeklyCarbs,
                weeklyFat: daily.weeklyFat,
                targetCalories: goal.targetCalories,
                targetProtein: goal.targetProteinG,
                targetCarbs: goal.targetCarbsG,
                targetFat: goal.targetFatG
            )
        }
    }

    // MARK: - Scan CTA

    private var scanCard: some View {
        VStack(spacing: 10) {
            Button {
                guard let menu = store.menu, menu.isFresh() else { return }
                scanRequest = ScanRequest(menu: menu, expected: [])
            } label: {
                Label("Scan your meal", systemImage: "camera.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!(store.menu?.isFresh() ?? false))

            Button {
                showLabelScan = true
            } label: {
                Label("Scan nutrition label", systemImage: "barcode.viewfinder")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)

            Button {
                showManualEntry = true
            } label: {
                Label("Log meal manually", systemImage: "square.and.pencil")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)

            if store.isLoading {
                Text("Loading menu…").font(.caption).foregroundStyle(.secondary)
            } else if store.menu == nil {
                Text("Select a dining hall in the Menu tab first.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !(store.menu?.isFresh() ?? false) {
                Text("Menu expired · pull to refresh in the Menu tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Today's meals

    private var mealsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today's meals").font(.headline)
            ForEach(daily.todayLogs) { meal in
                LoggedMealRow(
                    meal: meal,
                    onEdit: { editingMeal = meal },
                    onDelete: { withAnimation { daily.deleteLog(id: meal.id) } }
                )
            }
        }
    }
}

// MARK: - Streak badge

private struct StreakBadge: View {
    let streak: Int
    var body: some View {
        HStack(spacing: 4) {
            Text("🔥")
            Text("\(streak)")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("\(streak)-day streak")
    }
}

// MARK: - Weekly summary card

private struct WeeklySummaryCard: View {
    let daysLogged: Int
    let weeklyCalories: Double
    let weeklyProtein: Double
    let weeklyCarbs: Double
    let weeklyFat: Double
    let targetCalories: Double
    let targetProtein: Double
    let targetCarbs: Double
    let targetFat: Double

    // User's formula: total ÷ daily_target = day-equivalents consumed
    // Compare to days actually logged to get ratio
    private var weeklyTarget: Double { targetCalories * Double(daysLogged) }
    private var ratio: Double {
        guard weeklyTarget > 0 else { return 0 }
        return weeklyCalories / weeklyTarget
    }
    private var weeklyCalBarColor: Color {
        if ratio > 1.05 { return .orange }
        if ratio >= 0.9  { return PlateStyle.green }
        return .yellow
    }

    private var message: (String, Color) {
        switch ratio {
        case ..<0.85: return ("Under target this week — try to make it up.", .secondary)
        case ..<0.95: return ("Slightly under target this week.", PlateStyle.green)
        case ...1.05: return ("On track this week. 🎯", PlateStyle.green)
        case ...1.15: return ("Slightly over target this week.", .orange)
        default:      return ("Over target this week.", .orange)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("This week")
                    .font(.headline)
                Spacer()
                Text("\(daysLogged) of 7 days tracked")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Calories").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(weeklyCalories)) / \(Int(weeklyTarget)) kcal")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(weeklyCalBarColor.opacity(0.12))
                            .frame(height: 8)
                        Capsule().fill(weeklyCalBarColor)
                            .frame(width: geo.size.width * min(1, ratio), height: 8)
                            .animation(.spring(response: 0.5), value: ratio)
                    }
                }
                .frame(height: 8)
            }

            Text(message.0)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(message.1)

            Divider()

            HStack(spacing: 0) {
                WeeklyMacroCell(label: "Protein",
                                value: weeklyProtein,
                                target: targetProtein * Double(daysLogged),
                                unit: "g")
                WeeklyMacroCell(label: "Carbs",
                                value: weeklyCarbs,
                                target: targetCarbs * Double(daysLogged),
                                unit: "g")
                WeeklyMacroCell(label: "Fat",
                                value: weeklyFat,
                                target: targetFat * Double(daysLogged),
                                unit: "g")
            }
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct WeeklyMacroCell: View {
    let label: String
    let value: Double
    let target: Double
    let unit: String

    private var cellColor: Color {
        guard target > 0 else { return .yellow }
        return (value / target) >= 0.9 ? PlateStyle.green : .yellow
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text("\(Int(value))")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(cellColor)
            Text("/ \(Int(target)) \(unit)").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Goal Progress Card

private struct GoalProgressCard: View {
    let calories: Double
    let targetCalories: Double
    let protein: Double
    let targetProtein: Double
    let carbs: Double
    let targetCarbs: Double
    let fat: Double
    let targetFat: Double
    let onTapRing: () -> Void

    private var calorieRatio: Double { targetCalories > 0 ? calories / targetCalories : 0 }
    private var messageColor: Color {
        if calorieRatio > 1.05 { return .orange }
        if calorieRatio >= 0.9  { return PlateStyle.green }
        return .yellow
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Button(action: onTapRing) {
                    ProgressRing(consumed: calories, target: targetCalories)
                        .frame(width: 200, height: 200)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Calorie ring. Tap to view history.")
                .accessibilityValue("\(Int(calories)) of \(Int(targetCalories)) calories consumed today")

                Text("\(Int(calories)) of \(Int(targetCalories)) kcal")
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(progressMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(messageColor)

                HStack(spacing: 4) {
                    Image(systemName: "calendar").font(.caption2)
                    Text("Tap ring to view history").font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                MacroBar(label: "Protein", value: protein, target: targetProtein, unit: "g")
                MacroBar(label: "Carbs",   value: carbs,   target: targetCarbs,   unit: "g")
                MacroBar(label: "Fat",     value: fat,     target: targetFat,     unit: "g")
            }
        }
        .padding(24)
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
    }

    private var progressMessage: String {
        guard targetCalories > 0 else { return "Ready to start!" }
        let pct = calories / targetCalories
        switch pct {
        case 0: return "Ready to start!"
        case ..<0.4: return "Getting started."
        case ..<0.7: return "Good progress!"
        case ..<0.95: return "Almost there!"
        case ..<1.05: return "Goal reached!"
        default: return "Over budget today."
        }
    }
}

// MARK: - Simple Calorie Card (no goal set)

private struct SimpleCalorieCard: View {
    let calories: Double
    let onSetGoal: () -> Void
    let onTapHistory: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Button(action: onTapHistory) {
                VStack(spacing: 4) {
                    Text(calories.formatted(.number.precision(.fractionLength(0))))
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(PlateStyle.green)
                    Text("kcal today").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "calendar").font(.caption2)
                        Text("Tap to view history").font(.caption2)
                    }
                    .foregroundStyle(.tertiary).padding(.top, 2)
                }
            }
            .buttonStyle(.plain).frame(maxWidth: .infinity)

            Button("Set a calorie goal", action: onSetGoal).buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
    }
}

// MARK: - Progress Ring

private struct ProgressRing: View {
    let consumed: Double
    let target: Double

    private var fraction: Double {
        guard target > 0 else { return 0 }
        return consumed / target
    }
    private var isOver: Bool { fraction > 1.05 }
    private var ringColor: Color {
        if fraction > 1.05 { return .orange }
        if fraction >= 0.9  { return PlateStyle.green }
        return .yellow
    }
    private var displayFraction: Double { min(1.0, fraction) }

    var body: some View {
        ZStack {
            Circle().stroke(ringColor.opacity(0.12), lineWidth: 18)
            if isOver { Circle().stroke(Color.orange.opacity(0.30), lineWidth: 18) }
            Circle()
                .trim(from: 0, to: displayFraction)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.5, dampingFraction: 0.75), value: displayFraction)
            VStack(spacing: 3) {
                if isOver {
                    Text("+\(Int(consumed - target))")
                        .font(.system(.title2, design: .rounded, weight: .bold)).foregroundStyle(.orange)
                    Text("over").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                } else {
                    Text(Int(max(0, target - consumed)).formatted())
                        .font(.system(.title2, design: .rounded, weight: .bold)).foregroundStyle(ringColor)
                    Text("left").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Macro Bar

private struct MacroBar: View {
    let label: String
    let value: Double
    let target: Double
    let unit: String

    private var ratio: Double { guard target > 0 else { return 0 }; return value / target }
    private var fraction: Double { min(1.0, ratio) }
    private var barColor: Color { ratio >= 0.9 ? PlateStyle.green : .yellow }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value)) / \(Int(target)) \(unit)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(barColor.opacity(0.12)).frame(height: 7)
                    Capsule().fill(barColor)
                        .frame(width: geo.size.width * fraction, height: 7)
                        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: fraction)
                }
            }
            .frame(height: 7)
        }
    }
}

// MARK: - Logged Meal Row

private struct LoggedMealRow: View {
    let meal: LoggedMeal
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(meal.hallTitle) · \(meal.mealTitle)")
                    .font(.subheadline.weight(.medium))
                Text(meal.itemNames.prefix(3).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(meal.macros.caloriesKcal.formatted(.number.precision(.fractionLength(0))) + " kcal")
                    .font(.caption.weight(.semibold)).foregroundStyle(PlateStyle.green)
            }
            Spacer()
            HStack(spacing: 10) {
                Button(action: onEdit) {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.secondary).font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit meal")

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary).font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove meal")
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Edit Meal Sheet

private struct EditMealSheet: View {
    let meal: LoggedMeal
    let onSave: (String, Macros) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var caloriesText: String
    @State private var proteinText: String
    @State private var carbsText: String
    @State private var fatText: String

    init(meal: LoggedMeal, onSave: @escaping (String, Macros) -> Void) {
        self.meal = meal
        self.onSave = onSave
        _name = State(initialValue: meal.itemNames.first ?? "")
        let m = meal.macros
        _caloriesText = State(initialValue: m.caloriesKcal > 0 ? String(Int(m.caloriesKcal)) : "")
        _proteinText  = State(initialValue: m.proteinG > 0    ? String(Int(m.proteinG))    : "")
        _carbsText    = State(initialValue: m.carbsG > 0      ? String(Int(m.carbsG))      : "")
        _fatText      = State(initialValue: m.fatG > 0        ? String(Int(m.fatG))        : "")
    }

    private func parseRequired(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? $0 : nil }
    }
    private func parseOptional(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".")).map { max(0, $0) } ?? 0
    }
    private var canSave: Bool { parseRequired(caloriesText) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("Optional", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                } header: { Text("Meal") }

                Section {
                    LabeledContent("Calories (kcal)") {
                        TextField("Required", text: $caloriesText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Protein (g)") {
                        TextField("Optional", text: $proteinText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Carbs (g)") {
                        TextField("Optional", text: $carbsText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Fat (g)") {
                        TextField("Optional", text: $fatText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Nutrition")
                } footer: {
                    Text("Calories are required. All other fields are optional.")
                }
            }
            .navigationTitle("Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let kcal = parseRequired(caloriesText) else { return }
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        let finalName = trimmed.isEmpty ? (meal.itemNames.first ?? "Manual entry") : trimmed
                        onSave(finalName, Macros(
                            caloriesKcal: kcal,
                            proteinG: parseOptional(proteinText),
                            carbsG: parseOptional(carbsText),
                            fatG: parseOptional(fatText)
                        ))
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
