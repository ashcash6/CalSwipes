import SwiftUI
import os

private let menuLog = Logger(subsystem: "CalSwipes", category: "MenuScreen")

enum PlateStyle {
    static let green = CP.navy
    static let cream = CP.bg
    static let gold  = Color(red: 0.88, green: 0.66, blue: 0.25)
}

struct MenuScreen: View {
    var store: AppStore
    var daily: DailyStore
    let simulator: Bool
    @State private var aboutPresented = false
    @State private var search = ""
    @State private var mealSuggestionRequest: MealSuggestionRequest?

    private func dietaryFiltered(_ items: [MenuItem]) -> [MenuItem] {
        guard let goal = daily.goal,
              !goal.allergens.isEmpty || !goal.dietaryTags.isEmpty else { return items }
        let blocked = Set(goal.allergens)
        let required = Set(goal.dietaryTags.map { dietaryTagToBackend[$0] ?? $0 })
        return items.filter { item in
            if !blocked.isEmpty, !blocked.isDisjoint(with: Set(item.allergens)) { return false }
            if !required.isEmpty, !required.isSubset(of: Set(item.dietaryTags)) { return false }
            return true
        }
    }

    // Tier 1 = protein-first, Tier 2 = carb-first, Tier 3 = condiments/desserts/drinks
    private func menuSortTier(_ item: MenuItem) -> Int {
        let cats = item.categories.map { $0.lowercased() }.joined(separator: " ")
        if cats.contains("dessert") || cats.contains("pastry") || cats.contains("bakery")
            || cats.contains("sweet") || cats.contains("cake") || cats.contains("cookie")
            || cats.contains("sauce") || cats.contains("dressing") || cats.contains("condiment")
            || cats.contains("beverage") || cats.contains("drink") || cats.contains("juice") {
            return 3
        }
        let protein = item.macros?.proteinG ?? 0
        let carbs   = item.macros?.carbsG   ?? 0
        return protein >= carbs ? 1 : 2
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        CPSectionLabel(text: "Today at Berkeley")
                        Text("Make it your plate.")
                            .font(.system(.largeTitle, design: .serif, weight: .semibold))
                            .foregroundStyle(CP.text)
                        Text(store.serviceDate + " · Berkeley time")
                            .font(.subheadline)
                            .foregroundStyle(CP.textSec)
                    }
                    selections
                    if simulator {
                        Label("Simulator preview · camera support is unverified", systemImage: "desktopcomputer")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.isLoading && store.menu == nil {
                        // First load — nothing to show yet
                        ProgressView("Getting your menu…").frame(maxWidth: .infinity).padding(40)
                    } else if let menu = store.menu {
                        // Subsequent loads: keep old content visible and show a subtle refresh indicator
                        if store.isLoading {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.75)
                                Text("Refreshing…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            if menu.isFresh(at: context.date) {
                                menuContents(menu)
                            } else {
                                ContentUnavailableView("Downloaded menu expired", systemImage: "clock.badge.exclamationmark",
                                    description: Text("Pull to refresh before using this menu."))
                            }
                        }
                    } else if let error = store.menuError {
                        ContentUnavailableView {
                            Label("Menu unavailable", systemImage: "wifi.exclamationmark")
                        } description: { Text(error) } actions: {
                            Button("Try again") { Task { await store.loadMenu() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(CP.sp20)
            }
            .background(CP.bg)
            .navigationTitle("CalPlate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { aboutPresented = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("About")
                }
            }
            .searchable(text: $search, prompt: "Find a menu item")
            .refreshable { await store.loadMenu() }
            .task(id: store.menuLoadTrigger) {
                menuLog.info("task(id: menuLoadTrigger) fired — key=\(self.store.key.cacheName) mealValidated=\(self.store.mealValidated) version=\(self.store.loadVersion)")
                guard store.mealValidated else { return }
                search = ""
                await store.loadMenu()
            }
            .sheet(isPresented: $aboutPresented) { AboutView() }
            .sheet(item: $mealSuggestionRequest) { req in
                MealSuggestionSheet(combos: req.combos, hallTitle: req.hallTitle, mealTitle: req.mealTitle)
            }
        }
    }

    private var selections: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Dining hall", systemImage: "building.2").font(.subheadline.weight(.medium))
                Spacer()
                Picker("Dining hall", selection: Binding(
                    get: { store.selectedHall },
                    set: { hall in Task { await store.selectHall(hall) } }
                )) {
                    ForEach(Hall.allCases) { hall in Text(hall.title).tag(hall) }
                }
                .pickerStyle(.menu)
            }
            Divider()
            HStack {
                Label("Meal", systemImage: "sun.max").font(.subheadline.weight(.medium))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Picker("Meal", selection: Binding(
                        get: { store.selectedMeal },
                        set: { meal in Task { await store.selectMeal(meal) } }
                    )) {
                        let options: [Meal] = store.availableMeals.isEmpty
                            ? Meal.allCases
                            : Meal.allCases.filter { store.availableMeals.contains($0) }
                        ForEach(options) { meal in Text(meal.title).tag(meal) }
                    }
                    .pickerStyle(.menu)
                    if store.mealValidated {
                        Text(store.selectedMeal.typicalHours)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .cpCard(CP.sp16, radius: CP.r12)
    }

    @ViewBuilder
    private func menuContents(_ menu: MenuEnvelope) -> some View {
        // Compute filtering + sort ONCE per render. Previously filteredItems and
        // dietaryHiddenCount were separate computed properties each calling dietaryFiltered,
        // and filteredItems was referenced 4–5 times per render (re-running each time).
        let t0 = Date()
        let allItems = menu.items
        let dietaryItems = dietaryFiltered(allItems)
        let hiddenCount = allItems.count - dietaryItems.count
        // Pre-compute tier per item so the sort comparator doesn't recompute it O(n log n) times
        let tiered = (search.isEmpty ? dietaryItems : dietaryItems.filter { $0.name.localizedCaseInsensitiveContains(search) })
            .map { ($0, menuSortTier($0)) }
        let items = tiered.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            switch a.1 {
            case 1:  return (a.0.macros?.proteinG ?? 0) > (b.0.macros?.proteinG ?? 0)
            case 2:  return (a.0.macros?.carbsG   ?? 0) > (b.0.macros?.carbsG   ?? 0)
            default: return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
            }
        }.map(\.0)
        let _ = menuLog.debug("menuContents: \(allItems.count) total → \(dietaryItems.count) dietary → \(items.count) final in \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 2))ms (hidden=\(hiddenCount))")

        if store.isOffline {
            Label("Offline · using your downloaded menu", systemImage: "wifi.slash")
                .font(.subheadline).foregroundStyle(CP.navy)
        }
        if !store.cacheSaved {
            Text("Menu loaded, but could not be saved for offline use.").font(.caption).foregroundStyle(.orange)
        }
        Text("Updated \(menu.fetchedAt.formatted(date: .omitted, time: .shortened)) · values per published serving")
            .font(.caption).foregroundStyle(.secondary)
        if menu.status == "not_published" {
            ContentUnavailableView("No published menu", systemImage: "calendar.badge.exclamationmark",
                description: Text("Berkeley has not listed this meal period for \(store.selectedHall.title). Try another meal."))
        } else {
            Button {
                let liveMenu = store.menu ?? menu
                let budget = mealBudget()
                let combos = LocalRecommender.recommend(
                    from: liveMenu.items,
                    meal: store.selectedMeal,
                    goal: daily.goal,
                    budget: budget,
                    excluding: [],
                    fixedPortions: !store.selectedHall.isDiningHall
                )
                mealSuggestionRequest = MealSuggestionRequest(
                    combos: combos,
                    hallTitle: store.selectedHall.title,
                    mealTitle: store.selectedMeal.title
                )
            } label: {
                Label("Suggest a meal", systemImage: "sparkles")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            if hiddenCount > 0 {
                Label(
                    "\(hiddenCount) item\(hiddenCount == 1 ? "" : "s") hidden for your dietary restrictions",
                    systemImage: "line.3.horizontal.decrease.circle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(CP.navy)
            }
            Text("\(items.count) menu items").font(.headline)
            if items.isEmpty && !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if items.isEmpty {
                ContentUnavailableView("No matching items", systemImage: "fork.knife.circle",
                    description: Text("All items are hidden by your dietary restrictions."))
            }
            if !items.isEmpty {
                ForEach(items) { item in
                    MenuItemCard(item: item)
                }
            }
            Text("A listed serving is a reference amount, not a measurement of your plate. Nutrition values are estimates.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
    }

    /// Single-meal macro budget: the lesser of (a) what remains today and (b) one-third of
    /// the daily goal. This prevents the recommender from trying to fill the entire day's
    /// remaining deficit in a single plate (which produces ~1500 kcal suggestions).
    private func mealBudget() -> PlanBudget {
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
}

struct MenuItemCard: View {
    let item: MenuItem

    var body: some View {
        VStack(alignment: .leading, spacing: CP.sp12) {
            // Food name — dominant
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CP.text)
                    .multilineTextAlignment(.leading)
                let cats = item.categories.filter { !$0.isEmpty }.joined(separator: " · ")
                if !cats.isEmpty {
                    Text(cats)
                        .font(.caption2)
                        .foregroundStyle(CP.textSec)
                }
            }

            if let macros = item.macros {
                HStack(alignment: .center) {
                    Text("\(Int(macros.caloriesKcal)) kcal")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(CP.navy)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    MacroChip(value: macros.proteinG, label: "P", color: CP.protein)
                    MacroChip(value: macros.carbsG,   label: "C", color: CP.carbs)
                    MacroChip(value: macros.fatG,     label: "F", color: CP.fat)
                }
                Text("Per \(item.serving.label)")
                    .font(.caption2)
                    .foregroundStyle(CP.textSec)
            } else {
                Text("Nutrition not available")
                    .font(.caption)
                    .foregroundStyle(CP.textSec)
            }
        }
        .padding(CP.sp16)
        .background(CP.surface, in: RoundedRectangle(cornerRadius: CP.r12))
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 1)
        .accessibilityLabel(item.name)
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var value = ""
        if let macros = item.macros {
            value += "\(macros.caloriesKcal.formatted()) calories, \(macros.proteinG.formatted()) grams protein. "
        } else { value += "Nutrition unavailable. " }
        return value + "Per serving: " + item.serving.label
    }
}

private struct MacroChip: View {
    let value: Double
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(label) \(Int(value))g")
                .font(.caption2.weight(.medium))
                .foregroundStyle(CP.textSec)
        }
    }
}

// MARK: - Meal Suggestion Sheet

struct MealSuggestionRequest: Identifiable {
    let id = UUID()
    let combos: [MealCombo]
    let hallTitle: String
    let mealTitle: String
}

struct MealSuggestionSheet: View {
    let combos: [MealCombo]
    let hallTitle: String
    let mealTitle: String
    @Environment(\.dismiss) private var dismiss

    private func topItems(for role: FoodRole) -> [MealComponent] {
        var seenIds = Set<String>()
        return combos
            .flatMap { $0.components }
            .filter { $0.role == role && seenIds.insert($0.itemId).inserted }
            .sorted { $0.itemScore > $1.itemScore }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CP.sp16) {
                    if combos.isEmpty {
                        VStack(spacing: CP.sp16) {
                            Image(systemName: "fork.knife.circle")
                                .font(.system(size: 44))
                                .foregroundStyle(CP.navy.opacity(0.4))
                            Text("No suggestions available")
                                .font(.subheadline.weight(.medium))
                            Text("The menu for this meal may not have enough nutrition data to generate suggestions.")
                                .font(.caption)
                                .foregroundStyle(CP.textSec)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 60)
                        .padding(.horizontal, CP.sp32)
                    } else {
                        VStack(alignment: .leading, spacing: CP.sp4) {
                            CPSectionLabel(text: "Based on your remaining budget today")
                            Text("Pick one from each section to build a balanced plate.")
                                .font(.subheadline)
                                .foregroundStyle(CP.textSec)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let topCombo = combos.first {
                            macroDiagramCard(macros: topCombo.totalMacros)
                        }

                        let proteinItems = topItems(for: .protein)
                        let carbItems    = topItems(for: .carb)
                        let produceItems = topItems(for: .produce)

                        if !proteinItems.isEmpty {
                            roleSection(role: .protein, title: "Protein Sources", items: proteinItems)
                        }
                        if !carbItems.isEmpty {
                            roleSection(role: .carb, title: "Carb Sources", items: carbItems)
                        }
                        if !produceItems.isEmpty {
                            roleSection(role: .produce, title: "Produce", items: produceItems)
                        }

                        Text("These are suggestions based on your calorie goal. Use Scan in the Today tab to log what you actually eat.")
                            .font(.caption)
                            .foregroundStyle(CP.textSec)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, CP.sp8)
                    }
                }
                .padding(CP.sp20)
            }
            .background(CP.bg)
            .navigationTitle("\(mealTitle) at \(hallTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.medium)
                }
            }
        }
    }

    private func macroDiagramCard(macros: PlanMacros) -> some View {
        VStack(alignment: .leading, spacing: CP.sp10) {
            CPSectionLabel(text: "Top suggestion")
            MacroDiagramBar(macros: macros)
            HStack(spacing: CP.sp16) {
                suggestionLegendChip("Protein", color: CP.protein, value: macros.proteinG)
                suggestionLegendChip("Carbs",   color: CP.carbs,   value: macros.carbsG)
                suggestionLegendChip("Fat",     color: CP.fat,     value: macros.fatG)
                Spacer()
                Text("\(Int(macros.caloriesKcal)) kcal")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(CP.navy)
            }
        }
        .cpCard(CP.sp16)
    }

    private func suggestionLegendChip(_ label: String, color: Color, value: Double) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(Int(value))g \(label)")
                .font(.caption2).foregroundStyle(CP.textSec)
        }
    }

    private func roleSection(role: FoodRole, title: String, items: [MealComponent]) -> some View {
        let ordinals = ["1st", "2nd", "3rd"]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: CP.sp8) {
                Image(systemName: role.systemImage)
                    .font(.caption)
                    .foregroundStyle(CP.roleColor(role))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CP.textSec)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            .padding(.horizontal, CP.sp16)
            .padding(.top, CP.sp14)
            .padding(.bottom, CP.sp10)

            Divider().padding(.horizontal, CP.sp16)

            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                HStack(spacing: CP.sp10) {
                    Text(i < ordinals.count ? ordinals[i] : "#\(i + 1)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(CP.navy)
                        .frame(width: 26, alignment: .center)
                        .padding(.vertical, 4)
                        .background(CP.navy.opacity(0.08), in: Capsule())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.itemName)
                            .font(.subheadline)
                            .lineLimit(2)
                        if let macros = item.macros {
                            Text("\(Int(macros.caloriesKcal)) kcal · \(Int(macros.proteinG))g pro · \(Int(macros.carbsG))g carbs")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, CP.sp16)
                .padding(.vertical, CP.sp10)
                if i < items.count - 1 {
                    Divider().padding(.leading, CP.sp16 + 26 + CP.sp10)
                }
            }
        }
        .background(CP.surface, in: RoundedRectangle(cornerRadius: CP.r16))
        .shadow(color: .black.opacity(CP.shadowOpacity), radius: CP.shadowRadius, x: 0, y: CP.shadowY)
    }
}

// MARK: - Macro Diagram Bar

struct MacroDiagramBar: View {
    let macros: PlanMacros

    var body: some View {
        let totalCal = max(1.0, macros.caloriesKcal)
        let pFrac = CGFloat(macros.proteinG * 4 / totalCal)
        let cFrac = CGFloat(macros.carbsG * 4 / totalCal)
        let fFrac = CGFloat(macros.fatG * 9 / totalCal)

        GeometryReader { geo in
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 3).fill(CP.protein)
                    .frame(width: geo.size.width * pFrac)
                RoundedRectangle(cornerRadius: 3).fill(CP.carbs)
                    .frame(width: geo.size.width * cFrac)
                RoundedRectangle(cornerRadius: 3).fill(CP.fat)
                    .frame(width: geo.size.width * fFrac)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Your data") {
                    Text("Downloaded public menus are cached on this device. Captured photos stay in memory on this iPhone and are discarded when you close the camera flow. Photos are not uploaded or saved to Photos.")
                }
                Section("About this build") {
                    Text("Menus, photo capture, and nutrition tracking.")
                    Text("Nutrition figures are Berkeley's published per-serving reference values. Food recognition uses Apple's on-device Vision framework.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("An independent app. Not affiliated with UC Berkeley. Nutrition values are estimates, not medical advice.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
