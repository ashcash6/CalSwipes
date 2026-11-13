import SwiftUI
import os

private let menuLog = Logger(subsystem: "CalSwipes", category: "MenuScreen")

enum PlateStyle {
    static let green = CP.navy
    static let cream = CP.bg
    static let gold  = Color(red: 0.88, green: 0.66, blue: 0.25)
}

private enum MacroFilter: String, CaseIterable {
    case all = "All"
    case protein = "Protein"
    case carbs = "Carbs"
    case greens = "Greens"
}

struct MenuScreen: View {
    var store: AppStore
    var daily: DailyStore
    let simulator: Bool
    var onShowToday: () -> Void = {}
    @State private var aboutPresented = false
    @State private var lastLogged: (id: UUID, name: String)? = nil
    @State private var snackbarTask: Task<Void, Never>? = nil
    @State private var search = ""
    @State private var showMakeMeal = false
    @State private var macroFilter: MacroFilter = .all
    @AppStorage("menuByStation") private var byStation = true
    @State private var expandedStations: Set<String> = []

    private func dietaryFiltered(_ items: [MenuItem]) -> [MenuItem] {
        guard let goal = daily.goal,
              !goal.allergens.isEmpty || !goal.dietaryTags.isEmpty else { return items }
        let blockedAllergens = Set(goal.allergens)
        let tags = Set(goal.dietaryTags)
        return items.filter { item in
            let allergens = Set(item.allergens)
            let itemTags = Set(item.dietaryTags)

            // Hard block: item contains a selected allergen
            if !blockedAllergens.isEmpty, !blockedAllergens.isDisjoint(with: allergens) { return false }

            // Vegetarian: Berkeley tracks Fish, Shellfish, and Pork as the key non-vegetarian allergens
            if tags.contains("Vegetarian") {
                if !allergens.isDisjoint(with: ["Fish", "Shellfish", "Pork"]) { return false }
            }

            // Vegan: all animal-derived allergens Berkeley tracks; also exclude items Berkeley
            // explicitly labels Vegetarian-Only (dairy/eggs present but tagged, so confirmed non-vegan)
            if tags.contains("Vegan") {
                if !allergens.isDisjoint(with: ["Milk", "Egg", "Fish", "Shellfish", "Pork"]) { return false }
                if itemTags.contains("Vegetarian Option") && !itemTags.contains("Vegan Option") { return false }
            }

            // Halal: Pork and Alcohol are the explicit violations Berkeley's allergen data covers
            if tags.contains("Halal") {
                if allergens.contains("Pork") || allergens.contains("Alcohol") { return false }
            }

            // Kosher: Pork and Shellfish are the primary Berkeley-tracked violations
            if tags.contains("Kosher") {
                if allergens.contains("Pork") || allergens.contains("Shellfish") { return false }
            }

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
                LazyVStack(alignment: .leading, spacing: CP.sp12) {
                    ProgressStrip(daily: daily, onTap: onShowToday)
                    contextRow
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
            .scrollDismissesKeyboard(.immediately)
            .simultaneousGesture(TapGesture().onEnded {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            })
            .background(CP.bg)
            .navigationTitle(prettyDate(store.serviceDate))
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
                macroFilter = .all
                await store.loadMenu()
            }
            .sheet(isPresented: $aboutPresented) { AboutView() }
            .sheet(isPresented: $showMakeMeal) {
                MakeMealSheet(store: store, daily: daily)
            }
            .overlay(alignment: .bottom) {
                if let logged = lastLogged {
                    UndoSnackbar(text: "Added \(logged.name)") {
                        daily.deleteLog(id: logged.id)
                        lastLogged = nil
                    }
                    .padding(.bottom, CP.sp32)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: lastLogged?.id)
        }
    }

    private func logItem(_ item: MenuItem) {
        guard let macros = item.macros else { return }
        daily.logDiningItem(name: item.name, macros: macros,
                            hallTitle: store.selectedHall.title, mealTitle: store.selectedMeal.title)
        Haptics.logged()
        if let newest = daily.todayLogs.max(by: { $0.loggedAt < $1.loggedAt }) {
            lastLogged = (newest.id, item.name)
            UIAccessibility.post(notification: .announcement, argument: "Added \(item.name)")
        }
        snackbarTask?.cancel()
        snackbarTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { lastLogged = nil }
        }
    }

    private func prettyDate(_ ymd: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = BerkeleyClock.calendar.timeZone
        guard let d = f.date(from: ymd) else { return ymd }
        let out = DateFormatter(); out.dateFormat = "EEE, MMM d"; out.timeZone = BerkeleyClock.calendar.timeZone
        return out.string(from: d)
    }

    /// One compact line: Crossroads ▾ · Dinner ▾ · 5–9 PM (spec §5.1)
    private var contextRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: CP.sp8) { hallPicker; Text("·").foregroundStyle(CP.textSecondary); mealPicker; hoursText }
            VStack(alignment: .leading, spacing: CP.sp4) { hallPicker; mealPicker; hoursText }
        }
        .font(.subheadline)
    }

    private var hallPicker: some View {
        Menu {
            Picker("Dining hall", selection: Binding(
                get: { store.selectedHall },
                set: { hall in Task { await store.selectHall(hall) } }
            )) {
                ForEach(Hall.allCases.filter { $0 != .theDen && $0 != .cubMarket && $0 != .bearMarket }) { hall in
                    Text(hall.title).tag(hall)
                }
            }
        } label: {
            pickerLabel(store.selectedHall.title)
        }
        .accessibilityLabel("Dining hall, \(store.selectedHall.title)")
    }

    private var mealPicker: some View {
        Menu {
            Picker("Meal", selection: Binding(
                get: { store.selectedMeal },
                set: { meal in Task { await store.selectMeal(meal) } }
            )) {
                let options: [Meal] = store.availableMeals.isEmpty
                    ? Meal.allCases
                    : Meal.allCases.filter { store.availableMeals.contains($0) }
                ForEach(options) { meal in Text(meal.title).tag(meal) }
            }
        } label: {
            pickerLabel(store.selectedMeal.title)
        }
        .accessibilityLabel("Meal, \(store.selectedMeal.title)")
    }

    @ViewBuilder private var hoursText: some View {
        if store.mealValidated {
            Text(store.selectedMeal.typicalHours).foregroundStyle(CP.textSecondary)
        }
    }

    private func pickerLabel(_ title: String) -> some View {
        HStack(spacing: CP.sp4) {
            Text(title).font(.headline).foregroundStyle(CP.textPrimary)
            Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(CP.accent)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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
                    ForEach(Hall.allCases.filter { $0 != .theDen && $0 != .cubMarket && $0 != .bearMarket }) { hall in
                        Text(hall.title).tag(hall)
                    }
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
        let searched = search.isEmpty ? dietaryItems : dietaryItems.filter { $0.name.localizedCaseInsensitiveContains(search) }
        let macroFiltered: [MenuItem] = {
            switch macroFilter {
            case .all:     return searched
            case .protein: return searched.filter { menuSortTier($0) == 1 }
            case .carbs:   return searched.filter { menuSortTier($0) == 2 }
            case .greens:  return searched.filter { LocalRecommender.classifyRoles($0).contains(.produce) }
            }
        }()
        let tiered = macroFiltered.map { ($0, menuSortTier($0)) }
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
        Text("Updated \(menu.fetchedAt.formatted(date: .omitted, time: .shortened)) · per published serving")
            .font(.footnote).foregroundStyle(CP.textSecondary)
        if menu.status == "not_published" {
            ContentUnavailableView("No published menu", systemImage: "calendar.badge.exclamationmark",
                description: Text("Berkeley has not listed this meal period for \(store.selectedHall.title). Try another meal."))
        } else {
            CPPrimaryButton(title: "Make My Meal", icon: "sparkles") {
                showMakeMeal = true
            }
            if hiddenCount > 0 {
                Label(
                    "\(hiddenCount) item\(hiddenCount == 1 ? "" : "s") hidden for your dietary restrictions",
                    systemImage: "line.3.horizontal.decrease.circle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(CP.navy)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CP.sp8) {
                    ForEach(MacroFilter.allCases, id: \.self) { f in
                        let on = macroFilter == f
                        Button { macroFilter = f } label: {
                            HStack(spacing: CP.sp4) {
                                if on { Image(systemName: "checkmark").font(.footnote.weight(.bold)) }
                                Text(f.rawValue).font(.subheadline.weight(.medium))
                            }
                            .foregroundStyle(on ? CP.onAccent : CP.textPrimary)
                            .padding(.horizontal, CP.sp16)
                            .frame(minHeight: 44)
                            .background(on ? CP.accent : CP.surface2, in: Capsule())
                            .overlay(Capsule().stroke(on ? Color.clear : CP.outline, lineWidth: 1))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }

            Picker("View", selection: $byStation) {
                Text("Top by station").tag(true)
                Text("All items").tag(false)
            }
            .pickerStyle(.segmented)

            Text("\(items.count) items").font(.headline).foregroundStyle(CP.textPrimary)
            if items.isEmpty && !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if items.isEmpty {
                ContentUnavailableView("No matching items", systemImage: "fork.knife.circle",
                    description: Text("All items are hidden by your dietary restrictions."))
            }
            if !items.isEmpty && byStation {
                ForEach(Station.group(items)) { station in
                    let expanded = expandedStations.contains(station.id)
                    VStack(alignment: .leading, spacing: CP.sp8) {
                        HStack {
                            Text(station.name).font(.title3.weight(.semibold)).foregroundStyle(CP.navy)
                            Spacer()
                            if station.items.count > station.top.count {
                                Button(expanded ? "Show less" : "See all \(station.items.count)") {
                                    withAnimation {
                                        if expanded { expandedStations.remove(station.id) }
                                        else { expandedStations.insert(station.id) }
                                    }
                                }
                                .font(.subheadline)
                            }
                        }
                        ForEach(expanded ? station.items : station.top) { item in
                            MenuItemCard(item: item, hall: store.selectedHall) { logItem(item) }
                        }
                    }
                    .padding(.top, CP.sp8)
                }
            }
            if !items.isEmpty && !byStation {
                ForEach(items) { item in
                    MenuItemCard(item: item, hall: store.selectedHall) { logItem(item) }
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
    let hall: Hall
    var onLog: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: CP.sp12) {
            VStack(alignment: .leading, spacing: CP.sp4) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(CP.textPrimary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.leading)
                if !item.dietaryTags.isEmpty {
                    tagRow
                }
                if let macros = item.macros {
                    macroLine(macros)
                    Text(servingText)
                        .font(.footnote)
                        .foregroundStyle(CP.textSecondary)
                    if let original = rescaledFromOz {
                        Label("Berkeley listed \(original) oz per serving, which isn't realistic. Adjusted to 4 oz.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(CP.textPrimary)
                    } else if possibleDataError(macros: macros, hall: hall) {
                        Label("Values may be scaled up. Berkeley sometimes publishes incorrect serving sizes.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(CP.textPrimary)
                    }
                } else {
                    Text("Nutrition not available")
                        .font(.footnote)
                        .foregroundStyle(CP.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.name)
            .accessibilityValue(accessibilitySummary)
            Spacer(minLength: 0)
            if let onLog, let macros = item.macros {
                Button(action: onLog) {
                    Image(systemName: "plus")
                        .font(.body.weight(.bold))
                        .foregroundStyle(CP.onAccent)
                        .frame(width: 30, height: 30)
                        .background(CP.accent, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(item.name), \(Fmt.int(macros.caloriesKcal)) calories")
            }
        }
        .padding(.vertical, CP.sp12)
        .padding(.horizontal, CP.sp16)
        .background(CP.surface1, in: RoundedRectangle(cornerRadius: CP.r16))
    }

    private var tagRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: CP.sp4) { tags }
            VStack(alignment: .leading, spacing: CP.sp4) { tags }
        }
    }

    @ViewBuilder private var tags: some View {
        ForEach(item.dietaryTags, id: \.self) { tag in
            Text(tag)
                .font(.caption)
                .foregroundStyle(CP.textPrimary)
                .padding(.horizontal, CP.sp8)
                .padding(.vertical, 2)
                .background(CP.surface2, in: Capsule())
        }
    }

    private func macroLine(_ m: Macros) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: CP.sp4))
            : AnyLayout(HStackLayout(spacing: CP.sp8))
        return layout {
            Text("\(Fmt.int(m.caloriesKcal)) kcal")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CP.textPrimary)
            HStack(spacing: CP.sp8) {
                macro("P", m.proteinG, CP.macroProtein)
                Text("·").foregroundStyle(CP.textSecondary)
                macro("C", m.carbsG, CP.macroCarbs)
                Text("·").foregroundStyle(CP.textSecondary)
                macro("F", m.fatG, CP.macroFat)
            }
            .font(.subheadline)
        }
        .monospacedDigit()
    }

    private func macro(_ letter: String, _ grams: Double, _ color: Color) -> some View {
        (Text(letter).foregroundColor(color).bold() + Text(" \(Fmt.int(grams))g").foregroundColor(CP.textPrimary))
    }

    private var servingText: String { item.serving.label }

    /// Set by the server when it shrank an unrealistic published serving (warning "serving_rescaled_from_<N>oz").
    private var rescaledFromOz: String? {
        guard let w = item.warnings.first(where: { $0.hasPrefix("serving_rescaled_from_") }) else { return nil }
        return w.replacingOccurrences(of: "serving_rescaled_from_", with: "").replacingOccurrences(of: "oz", with: "")
    }

    private func possibleDataError(macros: Macros, hall: Hall) -> Bool {
        guard hall.isDiningHall else { return false }
        return macros.caloriesKcal > 1000
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


// MARK: - Stations

/// A Berkeley Dining station (the XML "category", e.g. Lemongrass, Kosher Station, Center Plate).
struct Station: Identifiable {
    let id: String
    let name: String
    let items: [MenuItem]
    /// The 2 dishes to show by default: real dishes (not toppings or sauces), highest protein first.
    let top: [MenuItem]

    /// Build-your-own bars and extras: shown last, still with their top picks.
    private static let lastKeywords = ["salad bar", "cold food", "bagel", "bread", "spread", "yogurt", "cereal",
                                       "fruit", "soft serve", "condiment", "dessert", "pastr", "deli"]

    static func normalize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if s.caseInsensitiveCompare("Centerplate") == .orderedSame { s = "Center Plate" }
        return s.isEmpty ? "Other" : s
    }

    private static func isDish(_ item: MenuItem) -> Bool {
        guard let m = item.macros else { return false }
        let n = item.name.lowercased()
        let extra = ["sauce", "dressing", "salsa", "chutney", "gravy", "syrup", "topping", "garnish", "seasoning",
                     "vinaigrette", "aioli", "ketchup", "mustard", "mayo", "relish", "croutons"]
        return m.caloriesKcal >= 60 && !extra.contains(where: n.contains)
    }

    static func group(_ items: [MenuItem]) -> [Station] {
        var buckets: [String: [MenuItem]] = [:]
        var order: [String] = []
        for item in items {
            let name = normalize(item.categories.first ?? "")
            if buckets[name] == nil { order.append(name) }
            buckets[name, default: []].append(item)
        }
        let stations = order.map { name -> Station in
            let all = buckets[name]!.sorted { ($0.macros?.proteinG ?? 0) > ($1.macros?.proteinG ?? 0) }
            let dishes = all.filter(isDish)
            return Station(id: name, name: name, items: all, top: Array((dishes.isEmpty ? all : dishes).prefix(2)))
        }
        func isLast(_ s: Station) -> Bool { lastKeywords.contains { s.name.lowercased().contains($0) } }
        // Center Plate first, then other main stations (Berkeley's order), then bars/extras.
        let main = stations.filter { !isLast($0) }
        let center = main.filter { $0.name == "Center Plate" }
        return center + main.filter { $0.name != "Center Plate" } + stations.filter(isLast)
    }
}
