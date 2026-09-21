import SwiftUI

// MARK: - Recurring Foods Screen

struct RecurringFoodsScreen: View {
    var daily: DailyStore
    @State private var editingFood: RecurringFood?
    @State private var showAdd = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if daily.recurringFoods.isEmpty {
                    emptyState
                } else {
                    foodList
                }
            }
            .background(PlateStyle.cream)
            .navigationTitle("Recurring Foods")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            EditRecurringFoodSheet(food: nil) { food in
                daily.addRecurringFood(food)
            }
        }
        .sheet(item: $editingFood) { food in
            EditRecurringFoodSheet(food: food) { updated in
                daily.updateRecurringFood(updated)
            }
        }
        .tint(PlateStyle.green)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "repeat.circle")
                .font(.system(size: 52))
                .foregroundStyle(PlateStyle.green.opacity(0.7))
            VStack(spacing: 6) {
                Text("No recurring foods")
                    .font(.system(.title3, design: .serif, weight: .semibold))
                Text("Add protein shakes, bars, yogurt, or any food you eat daily. They'll be subtracted from your meal plan budget automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button { showAdd = true } label: {
                Label("Add recurring food", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(PlateStyle.green)
            Spacer()
            Spacer()
        }
    }

    private var foodList: some View {
        List {
            Section {
                ForEach(daily.recurringFoods) { food in
                    RecurringFoodRow(food: food) {
                        editingFood = food
                    }
                }
                .onDelete { offsets in
                    offsets.forEach { daily.deleteRecurringFood(id: daily.recurringFoods[$0].id) }
                }
            } header: {
                Text("Saved foods")
            } footer: {
                Text("These are deducted from your daily meal plan budget when enabled. Toggle them per-day in the Plan sheet.")
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Recurring Food Row

private struct RecurringFoodRow: View {
    let food: RecurringFood
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(food.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(food.servingDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int(food.calories)) kcal · \(Int(food.proteinG))g protein · \(Int(food.carbsG))g carbs · \(Int(food.fatG))g fat")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if food.defaultEnabled {
                        Text("Default ON")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(PlateStyle.green)
                    } else {
                        Text("Default OFF")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Edit Recurring Food Sheet

struct EditRecurringFoodSheet: View {
    /// nil → adding a new food; non-nil → editing an existing one
    let food: RecurringFood?
    let onSave: (RecurringFood) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var servingDescription: String
    @State private var caloriesText: String
    @State private var proteinText: String
    @State private var carbsText: String
    @State private var fatText: String
    @State private var typicalMeal: Meal?
    @State private var defaultEnabled: Bool

    init(food: RecurringFood?, onSave: @escaping (RecurringFood) -> Void) {
        self.food   = food
        self.onSave = onSave
        _name               = State(initialValue: food?.name ?? "")
        _servingDescription = State(initialValue: food?.servingDescription ?? "")
        _caloriesText       = State(initialValue: food.map { String(Int($0.calories)) } ?? "")
        _proteinText        = State(initialValue: food.map { String(Int($0.proteinG)) } ?? "")
        _carbsText          = State(initialValue: food.map { String(Int($0.carbsG)) }  ?? "")
        _fatText            = State(initialValue: food.map { String(Int($0.fatG)) }    ?? "")
        _typicalMeal        = State(initialValue: food?.typicalMeal)
        _defaultEnabled     = State(initialValue: food?.defaultEnabled ?? true)
    }

    private func parse(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")).map { max(0, $0) } ?? 0 }
    private var calories: Double { parse(caloriesText) }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && calories > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Food") {
                    LabeledContent("Name") {
                        TextField("Protein Shake", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Serving") {
                        TextField("1 shake (360 ml)", text: $servingDescription)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Nutrition per serving") {
                    macroRow(label: "Calories (kcal)", placeholder: "160", text: $caloriesText)
                    macroRow(label: "Protein (g)",     placeholder: "30",  text: $proteinText)
                    macroRow(label: "Carbs (g)",        placeholder: "8",   text: $carbsText)
                    macroRow(label: "Fat (g)",          placeholder: "3",   text: $fatText)
                }

                Section("Plan behavior") {
                    Toggle("Enabled by default", isOn: $defaultEnabled)
                    Picker("Typical meal", selection: $typicalMeal) {
                        Text("None").tag(Meal?.none)
                        ForEach(Meal.allCases) { meal in
                            Text(meal.title).tag(Meal?.some(meal))
                        }
                    }
                }
            }
            .navigationTitle(food == nil ? "Add Food" : "Edit Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
    }

    @ViewBuilder
    private func macroRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
        }
    }

    private func save() {
        let updated = RecurringFood(
            id:                 food?.id ?? UUID(),
            name:               name.trimmingCharacters(in: .whitespaces),
            calories:           calories,
            proteinG:           parse(proteinText),
            carbsG:             parse(carbsText),
            fatG:               parse(fatText),
            servingDescription: servingDescription.trimmingCharacters(in: .whitespaces),
            typicalMeal:        typicalMeal,
            defaultEnabled:     defaultEnabled
        )
        onSave(updated)
        dismiss()
    }
}
