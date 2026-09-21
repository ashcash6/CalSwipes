import SwiftUI
import os

private let menuLog = Logger(subsystem: "BerkeleyPlate", category: "MenuScreen")

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
    @State private var scanRequest: ScanRequest?

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
            .fullScreenCover(item: $scanRequest) { request in
                ScanScreen(request: request, onLog: { result in
                    daily.logMeal(result: result, menu: request.menu)
                })
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
                guard menu.isFresh(), menu.date == BerkeleyClock.serviceDate() else { return }
                scanRequest = ScanRequest(menu: menu, expected: [])
            } label: {
                Label("Photograph meal", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            Text("Take a photo — your iPhone identifies foods automatically. Values are per published serving.")
                .font(.caption).foregroundStyle(.secondary)
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
