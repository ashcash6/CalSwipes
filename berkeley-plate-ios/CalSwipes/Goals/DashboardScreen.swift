import SwiftUI

struct DashboardScreen: View {
    var store: AppStore
    var daily: DailyStore
    @State private var showGoalSheet = false
    @State private var showDietarySheet = false
    @State private var showRecurringFoods = false
    @State private var showHistory = false
    @State private var showLabelScan = false
    @State private var showManualEntry = false
    @State private var editingMeal: LoggedMeal?
    @State private var showMakeMeal = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CP.sp20) {
                    dateHeader
                    progressSection
                    makeMealSection
                    scanSection
                    if !daily.todayLogs.isEmpty { mealsSection }
                }
                .padding(CP.sp20)
            }
            .background(CP.bg)
            .navigationTitle("")
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
        .sheet(isPresented: $showMakeMeal) {
            MakeMealSheet(store: store, daily: daily)
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
        let base: String
        switch hour {
        case 0..<12: base = "Good morning"
        case 12..<17: base = "Good afternoon"
        default: base = "Good evening"
        }
        let first = daily.nickname.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "\(base)." : "\(base), \(first)."
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

    // MARK: - Make My Meal

    @ViewBuilder
    private var makeMealSection: some View {
        if store.menu?.isFresh() == true {
            CPPrimaryButton(title: "Make My Meal", icon: "sparkles") {
                showMakeMeal = true
            }
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

    // MARK: - Log actions

    private var scanSection: some View {
        VStack(spacing: CP.sp8) {
            logActionsCard

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

    private var logActionsCard: some View {
        VStack(spacing: 0) {
            // Nutrition label
            Button { showLabelScan = true } label: {
                HStack(spacing: CP.sp12) {
                    Image(systemName: "barcode.viewfinder")
                        .font(.subheadline)
                        .foregroundStyle(CP.textSec)
                        .frame(width: 28)
                    Text("Nutrition label")
                        .font(.subheadline)
                        .foregroundStyle(CP.text)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CP.textSec)
                }
                .padding(.horizontal, CP.sp16)
                .padding(.vertical, CP.sp14)
            }
            .buttonStyle(CPPressStyle())

            Divider().padding(.leading, CP.sp16 + 28 + CP.sp12)

            // Manual
            Button { showManualEntry = true } label: {
                HStack(spacing: CP.sp12) {
                    Image(systemName: "square.and.pencil")
                        .font(.subheadline)
                        .foregroundStyle(CP.textSec)
                        .frame(width: 28)
                    Text("Log manually")
                        .font(.subheadline)
                        .foregroundStyle(CP.text)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CP.textSec)
                }
                .padding(.horizontal, CP.sp16)
                .padding(.vertical, CP.sp14)
            }
            .buttonStyle(CPPressStyle())
        }
        .background(CP.surface, in: RoundedRectangle(cornerRadius: CP.r16))
        .shadow(color: .black.opacity(CP.shadowOpacity), radius: CP.shadowRadius, x: 0, y: CP.shadowY)
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
            // Centered ring
            Button(action: onTapRing) {
                CPProgressRing(consumed: calories, target: targetCalories)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Calorie ring — tap to view history")
            .accessibilityValue("\(Int(calories)) of \(Int(targetCalories)) calories consumed today")

            CPDivider()

            // Macro bars
            VStack(spacing: CP.sp10) {
                CPMacroBar(label: "Protein", value: protein, target: targetProtein, unit: "g", color: CP.protein)
                CPMacroBar(label: "Carbs",   value: carbs,   target: targetCarbs,   unit: "g", color: CP.carbs)
                CPMacroBar(label: "Fat",     value: fat,     target: targetFat,     unit: "g", color: CP.fat)
            }

            Button(action: onTapRing) {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").font(.caption2)
                    Text("View calorie history").font(.caption2)
                }
                .foregroundStyle(CP.textSec)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CPPressStyle())
        }
        .cpCard(CP.sp20)
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
            .buttonStyle(CPPressStyle()).frame(maxWidth: .infinity)

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
                .buttonStyle(CPPressStyle())
                .accessibilityLabel("Edit meal")

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CP.textSec).font(.title3)
                }
                .buttonStyle(CPPressStyle())
                .accessibilityLabel("Remove meal")
            }
        }
        .padding(CP.sp14)
        .background(CP.surface, in: RoundedRectangle(cornerRadius: CP.r12))
        .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 1)
    }
}

// MARK: - Make My Meal Sheet

private struct MakeMealSheet: View {
    var store: AppStore
    var daily: DailyStore

    @State private var selectedHall: Hall
    @State private var selectedMeal: Meal
    @State private var localAvailableMeals: [Meal]
    @State private var localMenu: MenuEnvelope?
    @State private var combos: [MealCombo] = []
    @State private var budget = PlanBudget(caloriesKcal: 600, proteinG: 40, carbsG: 70, fatG: 20)
    @State private var isLoading = false
    @State private var selectedTab = 0
    @State private var swappingCtx: SwapContext? = nil
    @Environment(\.dismiss) private var dismiss

    private struct SwapContext: Identifiable {
        // Append comboIndex so re-tapping the same item on a different tab opens a fresh sheet
        var id: String { component.itemId + "\(comboIndex)" }
        let component: MealComponent
        let comboIndex: Int
    }

    private var availableMealOptions: [Meal] {
        guard !localAvailableMeals.isEmpty else { return Meal.allCases }
        return Meal.allCases.filter { localAvailableMeals.contains($0) }
    }
    private var isFixedPortions: Bool { !selectedHall.isDiningHall }

    private let labels = ["Best Match", "High Protein", "High Carb"]
    private var explanations: [String] {
        isFixedPortions ? [
            "Best overall match to your remaining calorie and macro targets.",
            "Highest-protein dish available at this venue.",
            "Highest-carb dish — good for energy before or after activity.",
        ] : [
            "Best overall match to your remaining calorie and macro targets.",
            "Maximum protein — pushes servings to hit your protein target first, calories second.",
            "Higher carbs for sustained energy — great before or after active periods.",
        ]
    }

    init(store: AppStore, daily: DailyStore) {
        self.store = store
        self.daily = daily
        let h = store.selectedHall
        let m = store.selectedMeal
        self._selectedHall = State(initialValue: h)
        self._selectedMeal = State(initialValue: m)
        self._localAvailableMeals = State(initialValue: store.availableMeals)
        // Seed localMenu from store if it already has the right menu loaded (common case).
        let seed = store.menu.flatMap { ($0.hall == h && $0.meal == m && $0.isFresh()) ? $0 : nil }
        self._localMenu = State(initialValue: seed)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CP.sp16) {
                    hallMealPicker

                    if isLoading {
                        HStack {
                            Spacer()
                            VStack(spacing: CP.sp12) {
                                ProgressView()
                                Text("Finding meals…").font(.subheadline).foregroundStyle(CP.textSec)
                            }
                            .padding(.top, 40)
                            Spacer()
                        }
                    } else if combos.isEmpty {
                        emptyState
                    } else {
                        budgetHeader
                        if combos.count > 1 {
                            Picker("Meal option", selection: $selectedTab) {
                                ForEach(0..<min(combos.count, labels.count), id: \.self) { i in
                                    Text(labels[i]).tag(i)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        if selectedTab < combos.count {
                            comboDetail(
                                combos[selectedTab],
                                comboIndex: selectedTab,
                                explanation: selectedTab < explanations.count ? explanations[selectedTab] : ""
                            )
                        }
                    }
                }
                .padding(CP.sp20)
            }
            .background(CP.bg)
            .navigationTitle("Make My Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.medium)
                }
            }
            .onAppear {
                if localMenu != nil {
                    refresh()
                } else {
                    isLoading = true
                    Task {
                        localMenu = await store.fetchMenu(hall: selectedHall, meal: selectedMeal)
                        refresh()
                        isLoading = false
                    }
                }
            }
            .sheet(item: $swappingCtx) { ctx in
                if let menu = localMenu, ctx.comboIndex < combos.count {
                    SwapPickerSheet(
                        swapping: ctx.component,
                        combo: combos[ctx.comboIndex],
                        allItems: menu.items,
                        budget: budget,
                        profileIndex: ctx.comboIndex,
                        goal: daily.goal,
                        fixedPortions: isFixedPortions
                    ) { opt in
                        performSwap(opt, swapping: ctx.component, comboIndex: ctx.comboIndex)
                    }
                }
            }
        }
    }

    private func performSwap(_ opt: LocalRecommender.SwapOption,
                              swapping old: MealComponent, comboIndex: Int) {
        guard comboIndex < combos.count,
              let idx = combos[comboIndex].components.firstIndex(where: { $0.itemId == old.itemId })
        else { return }
        combos[comboIndex].components[idx] = MealComponent(
            itemId: opt.item.id, itemName: opt.item.name, role: old.role,
            macros: opt.scaledMacros, categories: opt.item.categories,
            dietaryTags: opt.item.dietaryTags, itemScore: 0, servingCount: opt.serving,
            baseServing: ComponentServing(quantity: opt.item.serving.quantity,
                                          unit: opt.item.serving.unit)
        )
    }

    // MARK: - Hall / Meal pickers

    private var hallMealPicker: some View {
        VStack(alignment: .leading, spacing: CP.sp12) {
            HStack {
                Label("Dining hall", systemImage: "building.2")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Picker("Dining hall", selection: $selectedHall) {
                    ForEach(Hall.allCases) { hall in Text(hall.title).tag(hall) }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedHall) { _, hall in changeHall(hall) }
            }
            Divider()
            HStack {
                Label("Meal period", systemImage: "sun.max")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Picker("Meal period", selection: $selectedMeal) {
                    ForEach(availableMealOptions) { meal in Text(meal.title).tag(meal) }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedMeal) { _, meal in changeMeal(meal) }
            }
        }
        .cpCard(CP.sp16, radius: CP.r12)
    }

    // MARK: - Content

    private var emptyState: some View {
        VStack(spacing: CP.sp16) {
            Image(systemName: "fork.knife.circle")
                .font(.system(size: 44))
                .foregroundStyle(CP.navy.opacity(0.4))
            Text("No suggestions available")
                .font(.subheadline.weight(.medium))
            Text("The menu may not have enough nutrition data. Try a different meal period or dining hall.")
                .font(.caption)
                .foregroundStyle(CP.textSec)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
        .padding(.horizontal, CP.sp32)
        .frame(maxWidth: .infinity)
    }

    private var budgetHeader: some View {
        VStack(alignment: .leading, spacing: CP.sp8) {
            CPSectionLabel(text: "Your remaining target today")
            HStack(spacing: CP.sp8) {
                macroTag(Int(budget.caloriesKcal), "kcal", CP.navy)
                macroTag(Int(budget.proteinG),     "P",    CP.protein)
                macroTag(Int(budget.carbsG),       "C",    CP.carbs)
                macroTag(Int(budget.fatG),         "F",    CP.fat)
                Spacer()
            }
        }
    }

    private func macroTag(_ value: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(value)").font(.caption.weight(.bold)).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(CP.textSec)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
    }

    private func comboDetail(_ combo: MealCombo, comboIndex: Int, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: CP.sp12) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(combo.components.enumerated()), id: \.element.id) { idx, comp in
                    foodItemRow(comp, comboIndex: comboIndex)
                    if idx < combo.components.count - 1 {
                        Divider().padding(.leading, CP.sp16)
                    }
                }
            }
            .background(CP.surface, in: RoundedRectangle(cornerRadius: CP.r16))
            .shadow(color: .black.opacity(CP.shadowOpacity), radius: CP.shadowRadius, x: 0, y: CP.shadowY)

            macroComparisonCard(combo: combo)

            HStack(spacing: CP.sp10) {
                Image(systemName: "info.circle").font(.subheadline).foregroundStyle(CP.navy)
                Text(explanation).font(.subheadline).foregroundStyle(CP.textSec)
            }
            .padding(CP.sp14)
            .background(CP.navy.opacity(0.06), in: RoundedRectangle(cornerRadius: CP.r12))

            CPPrimaryButton(title: "Log this meal", icon: "checkmark.circle.fill") {
                daily.logCombo(combo, hallTitle: selectedHall.title, mealTitle: selectedMeal.title)
                dismiss()
            }

            Text("Portion sizes are estimates.")
                .font(.caption)
                .foregroundStyle(CP.textSec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private func foodItemRow(_ comp: MealComponent, comboIndex: Int) -> some View {
        HStack(spacing: CP.sp12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(comp.itemName).font(.subheadline).lineLimit(2)
                if let m = comp.macros {
                    Text("\(Int(m.caloriesKcal)) kcal  ·  \(Int(m.proteinG))g P  ·  \(Int(m.carbsG))g C  ·  \(Int(m.fatG))g F")
                        .font(.caption2).foregroundStyle(CP.textSec)
                }
            }
            Spacer(minLength: 0)
            if comp.servingCount != 1.0 && !isFixedPortions {
                Text(servingLabel(comp.servingCount))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CP.navy)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(CP.navy.opacity(0.08), in: Capsule())
            }
            Button {
                swappingCtx = SwapContext(component: comp, comboIndex: comboIndex)
            } label: {
                Image(systemName: "arrow.2.squarepath")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CP.navy.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .background(CP.navy.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(CP.sp16)
    }

    private func servingLabel(_ count: Double) -> String {
        let fractions: [(Double, String)] = [
            (0.5, "½"), (0.75, "¾"), (1.25, "1¼"), (1.5, "1½"),
            (1.75, "1¾"), (2.0, "×2"), (2.5, "×2.5"), (3.0, "×3")
        ]
        if let m = fractions.first(where: { abs($0.0 - count) < 0.01 }) { return m.1 }
        if count.truncatingRemainder(dividingBy: 1) == 0 { return "×\(Int(count))" }
        return String(format: "×%.2g", count)
    }

    private func macroComparisonCard(combo: MealCombo) -> some View {
        let total = combo.totalMacros
        return VStack(alignment: .leading, spacing: CP.sp10) {
            CPSectionLabel(text: "This meal")
            MacroDiagramBar(macros: total)
            VStack(spacing: 6) {
                compRow("Calories", actual: total.caloriesKcal, target: budget.caloriesKcal, unit: "kcal")
                compRow("Protein",  actual: total.proteinG,     target: budget.proteinG,     unit: "g")
                compRow("Carbs",    actual: total.carbsG,       target: budget.carbsG,       unit: "g")
                compRow("Fat",      actual: total.fatG,         target: budget.fatG,         unit: "g")
            }
        }
        .cpCard(CP.sp16)
    }

    private func compRow(_ label: String, actual: Double, target: Double, unit: String) -> some View {
        let pct = target > 0 ? actual / target : 1.0
        let color: Color = pct > 1.15 ? .red : pct < 0.70 ? .orange : CP.navy
        return HStack {
            Text(label).font(.caption).foregroundStyle(CP.textSec).frame(width: 56, alignment: .leading)
            Text("\(Int(actual))\(unit)").font(.caption.weight(.semibold)).foregroundStyle(color)
            Text("/ \(Int(target))\(unit)").font(.caption).foregroundStyle(CP.textSec)
            Spacer()
            Text("\(Int(pct * 100))%").font(.caption2.weight(.medium)).foregroundStyle(color)
        }
    }

    // MARK: - Data loading

    private func computeBudget() -> PlanBudget {
        let goalCal  = daily.goal?.targetCalories ?? 2100
        let goalPro  = daily.goal?.targetProteinG ?? 130
        let goalCarb = daily.goal?.targetCarbsG   ?? 250
        let goalFat  = daily.goal?.targetFatG      ?? 65
        let remaining = max(0, goalCal - daily.todayCalories)
        let mealCal   = max(100, min(remaining, goalCal / 3))
        let fraction  = goalCal > 0 ? mealCal / goalCal : 1.0 / 3.0
        return PlanBudget(
            caloriesKcal: mealCal,
            proteinG:     max(10, goalPro  * fraction),
            carbsG:       max(20, goalCarb * fraction),
            fatG:         max(5,  goalFat  * fraction)
        )
    }

    private func refresh() {
        guard let menu = localMenu, menu.isFresh(),
              menu.hall == selectedHall, menu.meal == selectedMeal else {
            combos = []
            return
        }
        let b = computeBudget()
        budget = b
        combos = LocalRecommender.recommend(
            from: menu.items, meal: selectedMeal,
            goal: daily.goal, budget: b, excluding: [],
            fixedPortions: isFixedPortions
        )
        selectedTab = 0
    }

    private func changeHall(_ hall: Hall) {
        isLoading = true
        combos = []
        Task {
            // Fetch available meals for new hall into local state; doesn't touch store state.
            if let meals = await store.cachedOrFetchMeals(for: hall, date: store.serviceDate) {
                let ordered = Meal.allCases.filter { meals.contains($0) }
                localAvailableMeals = ordered
                if !ordered.isEmpty && !ordered.contains(selectedMeal) {
                    selectedMeal = BerkeleyClock.closestMeal(to: selectedMeal, among: ordered)
                }
            }
            // fetchMenu is isolated: no shared state mutations, no generation-check race.
            localMenu = await store.fetchMenu(hall: hall, meal: selectedMeal)
            refresh()
            isLoading = false
        }
    }

    private func changeMeal(_ meal: Meal) {
        isLoading = true
        combos = []
        Task {
            localMenu = await store.fetchMenu(hall: selectedHall, meal: meal)
            refresh()
            isLoading = false
        }
    }
}

// MARK: - Swap Picker Sheet

private struct SwapPickerSheet: View {
    let swapping: MealComponent
    let combo: MealCombo
    let allItems: [MenuItem]
    let budget: PlanBudget
    let profileIndex: Int
    let goal: UserGoal?
    let fixedPortions: Bool
    let onSelect: (LocalRecommender.SwapOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options: [LocalRecommender.SwapOption] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: CP.sp16) {
                        ProgressView()
                        Text("Finding alternatives…")
                            .font(.subheadline).foregroundStyle(CP.textSec)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CP.bg)
                } else if options.isEmpty {
                    VStack(spacing: CP.sp16) {
                        Image(systemName: "fork.knife.circle")
                            .font(.system(size: 44)).foregroundStyle(CP.navy.opacity(0.4))
                        Text("No alternatives found")
                            .font(.subheadline.weight(.medium))
                        Text("No other \(swapping.role.displayName.lowercased()) items are available in this menu.")
                            .font(.caption).foregroundStyle(CP.textSec)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, CP.sp32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CP.bg)
                } else {
                    List {
                        Section {
                            ForEach(options) { opt in
                                Button {
                                    onSelect(opt)
                                    dismiss()
                                } label: {
                                    swapRow(opt)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("Replace \(swapping.itemName)")
                        }
                    }
                }
            }
            .navigationTitle("Swap \(swapping.role.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            options = LocalRecommender.swapsForComponent(
                swapping, in: combo, from: allItems,
                budget: budget, profileIndex: profileIndex, goal: goal,
                fixedPortions: fixedPortions
            )
            isLoading = false
        }
    }

    private func swapRow(_ opt: LocalRecommender.SwapOption) -> some View {
        HStack(spacing: CP.sp12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(opt.item.name)
                    .font(.subheadline).foregroundStyle(.primary)
                Text("\(Int(opt.scaledMacros.caloriesKcal)) kcal · \(Int(opt.scaledMacros.proteinG))g P · \(Int(opt.scaledMacros.carbsG))g C · \(Int(opt.scaledMacros.fatG))g F")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                deltaChip(opt.deltaMacros.caloriesKcal, "cal")
                deltaChip(opt.deltaMacros.proteinG, "P")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func deltaChip(_ value: Double, _ unit: String) -> some View {
        let rounded = Int(value.rounded())
        if abs(rounded) >= 5 {
            let isUp = rounded > 0
            Text((isUp ? "+" : "") + "\(rounded)\(unit)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isUp ? Color.orange : CP.navy)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background((isUp ? Color.orange : CP.navy).opacity(0.10), in: Capsule())
        }
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

