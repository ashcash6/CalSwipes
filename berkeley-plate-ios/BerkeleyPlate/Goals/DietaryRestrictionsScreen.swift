import SwiftUI
import os

private let dietLog = Logger(subsystem: "BerkeleyPlate", category: "DietaryRestrictions")

struct DietaryRestrictionsScreen: View {
    private let store: DailyStore
    @Environment(\.dismiss) private var dismiss

    @State private var allergens: Set<String>
    @State private var dietaryTags: Set<String>

    init(store: DailyStore) {
        self.store = store
        let goal = store.goal
        self._allergens = State(initialValue: Set(goal?.allergens ?? []))
        self._dietaryTags = State(initialValue: Set(goal?.dietaryTags ?? []))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section(title: "Allergens",
                            subtitle: "These will be flagged on menu items.",
                            items: knownAllergens,
                            selection: $allergens)

                    section(title: "Dietary preferences",
                            subtitle: "Menu items will show matching tags.",
                            items: knownDietaryTags,
                            selection: $dietaryTags)

                    CPPrimaryButton(title: "Save") { save() }
                }
                .padding(24)
            }
            .background(PlateStyle.cream)
            .navigationTitle("Dietary restrictions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(PlateStyle.green)
    }

    @ViewBuilder
    private func section(title: String, subtitle: String,
                         items: [String], selection: Binding<Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            DietaryChipGrid(items: items, selection: selection)
        }
    }

    private func save() {
        let t0 = Date()
        dietLog.info("save() tapped at \(t0.timeIntervalSinceReferenceDate, format: .fixed(precision: 3))")
        var goal = store.goal ?? UserGoal(
            goalType: .maintain, pace: .medium,
            heightIn: 68, weightLbs: 160, activityLevel: .moderate
        )
        goal.allergens = allergens.sorted()
        goal.dietaryTags = dietaryTags.sorted()
        dismiss()
        dietLog.info("save() dismiss() called at +\(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 1))ms")
        let s = store, g = goal
        Task { @MainActor in
            dietLog.info("save() Task fired at +\(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 1))ms — calling saveGoal")
            s.saveGoal(g)
            dietLog.info("save() saveGoal returned at +\(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 1))ms")
        }
    }
}

// Shared chip grid — used here and in OnboardingScreen step 4
struct DietaryChipGrid: View {
    let items: [String]
    @Binding var selection: Set<String>

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 220), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(items, id: \.self) { item in
                let selected = selection.contains(item)
                Button {
                    if selected { selection.remove(item) } else { selection.insert(item) }
                } label: {
                    Text(item)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            selected ? PlateStyle.green : Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 20)
                        )
                        .foregroundStyle(selected ? .white : .primary)
                        .animation(.easeInOut(duration: 0.12), value: selected)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
