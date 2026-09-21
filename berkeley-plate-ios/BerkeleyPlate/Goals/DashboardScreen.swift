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
                VStack(alignment: .leading, spacing: CP.sp20) {
                    dateHeader
                    progressSection
                    if !daily.todayLogs.isEmpty { mealsSection }
                    scanSection
                }
                .padding(CP.sp20)
            }
            .background(CP.bg)
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: store.menuLoadTrigger) {
            guard store.mealValidated else { return }
            await store.loadMenu()
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

    // MARK: - Date header

    private var dateHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(daily.todayDate.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(CP.textSec)
                Text(greetingText)
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .foregroundStyle(CP.text)
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

    // MARK: - Progress

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

    // MARK: - Today's meals

    private var mealsSection: some View {
        VStack(alignment: .leading, spacing: CP.sp12) {
            CPSectionLabel(text: "Logged today")
            VStack(spacing: CP.sp8) {
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

    // MARK: - Scan actions

    private var scanSection: some View {
        VStack(spacing: CP.sp8) {
            CPSectionLabel(text: "Log a meal")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, CP.sp4)

            CPPrimaryButton(
                title: "Scan your meal",
                icon: "camera.fill",
                isDisabled: !(store.menu?.isFresh() ?? false)
            ) {
                guard let menu = store.menu, menu.isFresh() else { return }
                scanRequest = ScanRequest(menu: menu, expected: [])
            }

            HStack(spacing: CP.sp8) {
                CPSecondaryButton(title: "Nutrition label", icon: "barcode.viewfinder") {
                    showLabelScan = true
                }
                CPSecondaryButton(title: "Log manually", icon: "square.and.pencil") {
                    showManualEntry = true
                }
            }

            if store.isLoading {
                Text("Loading your menu…")
                    .font(.caption).foregroundStyle(CP.textSec)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if store.menu == nil {
                Text("Finding your nearest dining hall…")
                    .font(.caption).foregroundStyle(CP.textSec)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if !(store.menu?.isFresh() ?? false) {
                Text("Menu expired — open the Menu tab and pull to refresh.")
                    .font(.caption).foregroundStyle(CP.textSec)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
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
        .padding(.horizontal, CP.sp12).padding(.vertical, CP.sp8)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: CP.r12))
        .accessibilityLabel("\(streak)-day streak")
    }
}

// MARK: - Goal progress card

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

    var body: some View {
        VStack(spacing: CP.sp20) {
            // Ring + macro trio
            HStack(spacing: CP.sp20) {
                Button(action: onTapRing) {
                    CPProgressRing(consumed: calories, target: targetCalories, size: 130, strokeWidth: 11)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Calorie ring — tap to view history")
                .accessibilityValue("\(Int(calories)) of \(Int(targetCalories)) calories consumed today")

                VStack(alignment: .leading, spacing: CP.sp12) {
                    MacroStatColumn(value: protein, target: targetProtein, label: "Protein", unit: "g", color: CP.protein)
                    MacroStatColumn(value: carbs, target: targetCarbs, label: "Carbs", unit: "g", color: CP.carbs)
                    MacroStatColumn(value: fat, target: targetFat, label: "Fat", unit: "g", color: CP.fat)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            CPDivider()

            // Macro bars
            VStack(spacing: CP.sp10) {
                CPMacroBar(label: "Protein", value: protein, target: targetProtein, unit: "g", color: CP.protein)
                CPMacroBar(label: "Carbs",   value: carbs,   target: targetCarbs,   unit: "g", color: CP.carbs)
                CPMacroBar(label: "Fat",     value: fat,     target: targetFat,     unit: "g", color: CP.fat)
            }

            Button {
                onTapRing()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").font(.caption2)
                    Text("View calorie history")
                        .font(.caption2)
                }
                .foregroundStyle(CP.textSec)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .cpCard(CP.sp20)
    }
}

private struct MacroStatColumn: View {
    let value: Double
    let target: Double
    let label: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text("\(Int(value))")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(color)
                Text("/ \(Int(target))\(unit)")
                    .font(.caption2)
                    .foregroundStyle(CP.textSec)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(CP.textSec)
        }
    }
}

// MARK: - Simple calorie card (no goal)

private struct SimpleCalorieCard: View {
    let calories: Double
    let onSetGoal: () -> Void
    let onTapHistory: () -> Void

    var body: some View {
        VStack(spacing: CP.sp16) {
            Button(action: onTapHistory) {
                VStack(spacing: 4) {
                    Text(calories.formatted(.number.precision(.fractionLength(0))))
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(CP.navy)
                    Text("kcal today").font(.subheadline).foregroundStyle(CP.textSec)
                    HStack(spacing: 4) {
                        Image(systemName: "calendar").font(.caption2)
                        Text("Tap to view history").font(.caption2)
                    }
                    .foregroundStyle(CP.textSec.opacity(0.6)).padding(.top, 2)
                }
            }
            .buttonStyle(.plain).frame(maxWidth: .infinity)

            CPPrimaryButton(title: "Set a calorie goal", action: onSetGoal)
        }
        .cpCard(CP.sp20)
    }
}

// MARK: - Logged meal row

private struct LoggedMealRow: View {
    let meal: LoggedMeal
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: CP.sp12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(meal.hallTitle) · \(meal.mealTitle)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CP.text)
                Text(meal.itemNames.prefix(3).joined(separator: ", "))
                    .font(.caption).foregroundStyle(CP.textSec).lineLimit(1)
                Text(meal.macros.caloriesKcal.formatted(.number.precision(.fractionLength(0))) + " kcal")
                    .font(.caption.weight(.semibold)).foregroundStyle(CP.navy)
            }
            Spacer()
            HStack(spacing: CP.sp12) {
                Button(action: onEdit) {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(CP.textSec).font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit meal")

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CP.textSec).font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove meal")
            }
        }
        .padding(CP.sp14)
        .background(CP.surface, in: RoundedRectangle(cornerRadius: CP.r12))
        .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 1)
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

