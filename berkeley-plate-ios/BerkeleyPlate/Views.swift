import SwiftUI

enum PlateStyle {
    static let green = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.55, green: 0.83, blue: 0.67, alpha: 1)
            : UIColor(red: 0.12, green: 0.31, blue: 0.25, alpha: 1)
    })
    static let cream = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGroupedBackground
            : UIColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1)
    })
    static let gold = Color(red: 0.88, green: 0.66, blue: 0.25)
}

struct MenuScreen: View {
    @ObservedObject var store: AppStore
    let simulator: Bool
    @State private var aboutPresented = false
    @State private var search = ""
    @State private var scanRequest: ScanRequest?

    private var filteredItems: [MenuItem] {
        let items = store.menu?.items ?? []
        return items.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TODAY AT BERKELEY").font(.caption.weight(.bold)).tracking(2).foregroundStyle(PlateStyle.green)
                        Text("Make it your plate.").font(.system(.largeTitle, design: .serif, weight: .semibold))
                        Text(store.serviceDate + " · Berkeley time").font(.subheadline).foregroundStyle(.secondary)
                    }
                    selections
                    if simulator {
                        Label("Simulator preview · camera support is unverified", systemImage: "desktopcomputer")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.isLoading {
                        ProgressView("Getting your menu…").frame(maxWidth: .infinity).padding(40)
                    } else if let error = store.menuError {
                        ContentUnavailableView {
                            Label("Menu unavailable", systemImage: "wifi.exclamationmark")
                        } description: { Text(error) } actions: {
                            Button("Try again") { Task { await store.loadMenu() } }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if let menu = store.menu {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            if menu.isFresh(at: context.date) {
                                menuContents(menu)
                            } else {
                                ContentUnavailableView("Downloaded menu expired", systemImage: "clock.badge.exclamationmark",
                                    description: Text("Pull to refresh before using this menu."))
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(PlateStyle.cream)
            .navigationTitle("Berkeley Plate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { aboutPresented = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("About")
                }
            }
            .searchable(text: $search, prompt: "Find a menu item")
            .refreshable { await store.loadMenu() }
            .task(id: store.key) {
                search = ""
                await store.loadMenu()
            }
            .safeAreaInset(edge: .bottom) {
                if !store.selectedItemIds.isEmpty {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(store.selectedItemIds.count) expected items").font(.headline)
                            Text("Selections help narrow your next scan.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Clear") { store.selectedItemIds = [] }
                    }
                    .padding().background(.regularMaterial)
                }
            }
            .sheet(isPresented: $aboutPresented) { AboutView() }
            .fullScreenCover(item: $scanRequest) { request in ScanScreen(request: request) }
        }
    }

    private var selections: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Dining hall", systemImage: "building.2").font(.subheadline.weight(.medium))
                Spacer()
                Picker("Dining hall", selection: $store.selectedHall) {
                    ForEach(Hall.allCases) { hall in Text(hall.title).tag(hall) }
                }
                .pickerStyle(.menu)
            }
            Divider()
            HStack {
                Label("Meal", systemImage: "sun.max").font(.subheadline.weight(.medium))
                Spacer()
                Text(store.selectedMeal.title)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding().background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func menuContents(_ menu: MenuEnvelope) -> some View {
        if store.isOffline {
            Label("Offline · using your downloaded menu", systemImage: "wifi.slash")
                .font(.subheadline).foregroundStyle(PlateStyle.green)
        }
        if !store.cacheSaved {
            Text("Menu loaded, but could not be saved for offline use.").font(.caption).foregroundStyle(.orange)
        }
        Text("Updated \(menu.fetchedAt.formatted(date: .omitted, time: .shortened)) · values per published serving")
            .font(.caption).foregroundStyle(.secondary)
        if menu.status == "not_published" {
            ContentUnavailableView("No published menu", systemImage: "calendar.badge.exclamationmark",
                description: Text("Berkeley has not listed this meal period for \(store.selectedHall.title). Try another meal. This does not confirm that the hall is closed."))
        } else {
            Button {
                guard menu.isFresh(), menu.date == BerkeleyClock.serviceDate() else { return }
                scanRequest = ScanRequest(menu: menu, expected: store.selectedItemIds)
            } label: {
                Label("Photograph meal", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            Text("Photograph your meal and tap to outline the plate and foods on this iPhone. Portion estimates are not available yet.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(menu.items.count) menu items").font(.headline)
                Spacer()
                Text("Tap to preselect").font(.caption).foregroundStyle(.secondary)
            }
            if filteredItems.isEmpty {
                ContentUnavailableView.search(text: search)
            }
            ForEach(filteredItems) { item in
                MenuItemCard(item: item, selected: store.selectedItemIds.contains(item.id)) {
                    store.toggle(item.id)
                }
            }
            Text("A listed serving is a reference amount, not a measurement of your plate. Photo-based estimation is not included in this build.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
    }
}

struct MenuItemCard: View {
    let item: MenuItem
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Text(item.categories.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3).foregroundStyle(PlateStyle.green)
                }
                if let macros = item.macros {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { macroLabels(macros) }
                        VStack(alignment: .leading, spacing: 8) { macroLabels(macros) }
                    }
                } else {
                    Text("Nutrition not available").font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Serving: \(item.serving.label)").font(.caption).foregroundStyle(.secondary)
                if item.serving.weightG == nil {
                    Text("Serving weight not published").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .background(selected ? PlateStyle.green.opacity(0.07) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? PlateStyle.green : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.name)
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint("Double tap to change expected items")
    }

    private var accessibilitySummary: String {
        var value = selected ? "Selected. " : "Not selected. "
        if let macros = item.macros {
            value += "\(macros.caloriesKcal.formatted()) calories, \(macros.proteinG.formatted()) grams protein, \(macros.carbsG.formatted()) grams carbohydrates, \(macros.fatG.formatted()) grams fat. "
        } else { value += "Nutrition unavailable. " }
        return value + "Per serving: " + item.serving.label
    }

    @ViewBuilder
    private func macroLabels(_ macros: Macros) -> some View {
        Text("\(macros.caloriesKcal.formatted(.number.precision(.fractionLength(0)))) kcal")
            .font(.subheadline.weight(.semibold)).foregroundStyle(PlateStyle.green)
        Text("P \(macros.proteinG.formatted(.number.precision(.fractionLength(0...1)))) g")
            .font(.caption).foregroundStyle(.secondary)
        Text("C \(macros.carbsG.formatted(.number.precision(.fractionLength(0...1)))) g")
            .font(.caption).foregroundStyle(.secondary)
        Text("F \(macros.fatG.formatted(.number.precision(.fractionLength(0...1)))) g")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Your data") {
                    Text("Downloaded public menus are cached on this device. Captured photos stay in memory on this iPhone and are discarded when you close the camera flow. Photos are not uploaded or saved to Photos.")
                    Text("Item preselections stay in memory and are cleared when you switch menus.")
                }
                Section("About this build") {
                    Text("Menus and photo capture")
                    Text("Nutrition figures are Berkeley's published per-serving reference values. Automated food analysis, portion estimation, meal logging and HealthKit are planned for later phases.")
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
