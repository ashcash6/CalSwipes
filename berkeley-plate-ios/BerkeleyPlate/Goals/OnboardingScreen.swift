import SwiftUI

struct OnboardingScreen: View {
    var store: DailyStore
    var editMode: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var showManualEntry = false
    @State private var step: Int
    @State private var goalType: GoalType
    @State private var pace: Pace
    @State private var heightIn: Double
    @State private var weightLbs: Double
    @State private var activityLevel: ActivityLevel
    @State private var allergens: Set<String>
    @State private var dietaryTags: Set<String>

    // Recurring foods step (step 5, initial setup only)
    @State private var recurringPresets: [RecurringFood] = OnboardingScreen.defaultPresets
    @State private var enabledPresetIds: Set<UUID> = []
    @State private var editingPreset: RecurringFood?

    static let defaultPresets: [RecurringFood] = [
        RecurringFood(id: UUID(), name: "Protein Shake", calories: 160, proteinG: 30,
                      carbsG: 8, fatG: 3, servingDescription: "1 shake",
                      typicalMeal: .breakfast, defaultEnabled: true),
        RecurringFood(id: UUID(), name: "Protein Bar", calories: 200, proteinG: 20,
                      carbsG: 22, fatG: 7, servingDescription: "1 bar",
                      typicalMeal: nil, defaultEnabled: true),
        RecurringFood(id: UUID(), name: "Greek Yogurt", calories: 130, proteinG: 17,
                      carbsG: 9, fatG: 4, servingDescription: "1 cup (227g)",
                      typicalMeal: .breakfast, defaultEnabled: true),
    ]

    init(store: DailyStore, editMode: Bool = false) {
        self.store = store
        self.editMode = editMode
        let goal = store.goal
        self._step = State(initialValue: 0)
        self._goalType = State(initialValue: goal?.goalType ?? .maintain)
        self._pace = State(initialValue: goal?.pace ?? .medium)
        self._heightIn = State(initialValue: goal?.heightIn ?? 68)
        self._weightLbs = State(initialValue: goal?.weightLbs ?? 160)
        self._activityLevel = State(initialValue: goal?.activityLevel ?? .moderate)
        self._allergens = State(initialValue: Set(goal?.allergens ?? []))
        self._dietaryTags = State(initialValue: Set(goal?.dietaryTags ?? []))
    }

    private var skipsPace: Bool { goalType == .maintain }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                PlateStyle.cream.ignoresSafeArea()
                VStack(spacing: 0) {
                    stepDots
                    stepContent
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                .animation(.easeInOut(duration: 0.25), value: step)
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showManualEntry) {
                ManualMacrosScreen(store: store, isPresented: $showManualEntry)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == 0 {
                        Button(editMode ? "Cancel" : "Skip") {
                            if editMode { dismiss() } else { store.skipOnboarding() }
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        Button(action: goBack) {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Input manually") { showManualEntry = true }
                        .font(.subheadline)
                }
            }
        }
        .tint(PlateStyle.green)
        .sheet(item: $editingPreset) { preset in
            EditRecurringFoodSheet(food: preset) { updated in
                if let idx = recurringPresets.firstIndex(where: { $0.id == preset.id }) {
                    recurringPresets[idx] = updated
                }
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:
            OnboardingStepView(title: "What's your goal?",
                               subtitle: "We'll use this to set your daily calorie target.") {
                ForEach(GoalType.allCases) { type in
                    SelectionRow(title: type.title, systemImage: type.systemImage,
                                 selected: goalType == type) { goalType = type }
                }
            } next: { goForward() }
        case 1:
            OnboardingStepView(
                title: "How quickly?",
                subtitle: goalType == .lose ? "How fast do you want to lose?" : "How fast do you want to gain?"
            ) {
                ForEach(Pace.allCases) { p in
                    SelectionRow(title: p.title, subtitle: p.subtitle,
                                 selected: pace == p) { pace = p }
                }
            } next: { goForward() }
        case 2:
            OnboardingStepView(title: "Your measurements",
                               subtitle: "Used to estimate your daily calorie needs.") {
                HeightSlider(heightIn: $heightIn)
                WeightSlider(weightLbs: $weightLbs)
            } next: { goForward() }
        case 3:
            OnboardingStepView(title: "Activity level",
                               subtitle: "How active are you on a typical week?") {
                ForEach(ActivityLevel.allCases) { level in
                    SelectionRow(title: level.title, subtitle: level.subtitle,
                                 selected: activityLevel == level) { activityLevel = level }
                }
            } next: { goForward() }
        case 4:
            OnboardingStepView(title: "Dietary preferences",
                               subtitle: "We'll highlight allergens and tags on menu items.",
                               nextLabel: editMode ? "Save" : "Continue") {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Allergens")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        DietaryChipGrid(items: knownAllergens, selection: $allergens)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Dietary preferences")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        DietaryChipGrid(items: knownDietaryTags, selection: $dietaryTags)
                    }
                }
            } next: {
                if editMode {
                    store.saveGoal(UserGoal(goalType: goalType, pace: pace,
                                           heightIn: heightIn, weightLbs: weightLbs,
                                           activityLevel: activityLevel,
                                           allergens: allergens.sorted(),
                                           dietaryTags: dietaryTags.sorted()))
                    dismiss()
                } else {
                    goForward()
                }
            }
        default:
            // Step 5 — recurring foods (initial setup only)
            OnboardingStepView(title: "Protein snacks",
                               subtitle: "Foods you eat every day. Their calories are automatically deducted from your meal plan budget.",
                               nextLabel: "Finish setup") {
                VStack(spacing: 10) {
                    ForEach(recurringPresets) { preset in
                        let isEnabled = enabledPresetIds.contains(preset.id)
                        Button {
                            if isEnabled { enabledPresetIds.remove(preset.id) }
                            else         { enabledPresetIds.insert(preset.id) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isEnabled ? PlateStyle.green : .secondary)
                                    .frame(width: 32, alignment: .center)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("\(Int(preset.calories)) kcal · \(Int(preset.proteinG))g protein · \(preset.servingDescription)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { editingPreset = preset } label: {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(16)
                            .background(
                                isEnabled
                                    ? PlateStyle.green.opacity(0.08)
                                    : Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 16)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(isEnabled ? PlateStyle.green : .clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Text("You can always add or edit these in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            } next: {
                store.saveGoal(UserGoal(goalType: goalType, pace: pace,
                                       heightIn: heightIn, weightLbs: weightLbs,
                                       activityLevel: activityLevel,
                                       allergens: allergens.sorted(),
                                       dietaryTags: dietaryTags.sorted()))
                let existingNames = Set(store.recurringFoods.map(\.name))
                for preset in recurringPresets where enabledPresetIds.contains(preset.id) {
                    if !existingNames.contains(preset.name) {
                        store.addRecurringFood(preset)
                    }
                }
                // hasCompletedOnboarding = true → parent view dismisses automatically
            }
        }
    }

    private var stepDots: some View {
        let baseCount = skipsPace ? 4 : 5
        let count = editMode ? baseCount : baseCount + 1
        let current: Int = {
            if skipsPace { return step == 0 ? 0 : step - 1 }
            return step
        }()
        return HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i <= current ? PlateStyle.green : Color.secondary.opacity(0.2))
                    .frame(height: 4)
                    .animation(.easeInOut, value: current)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func goForward() {
        withAnimation(.easeInOut(duration: 0.25)) {
            if step == 0 && skipsPace { step = 2 } else { step += 1 }
        }
    }

    private func goBack() {
        withAnimation(.easeInOut(duration: 0.25)) {
            if step == 2 && skipsPace { step = 0 } else { step -= 1 }
        }
    }
}

// MARK: - Step Container

private struct OnboardingStepView<Content: View>: View {
    let title: String
    let subtitle: String
    var nextLabel: String = "Continue"
    @ViewBuilder let content: Content
    let next: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(.title, design: .serif, weight: .semibold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                content
                Spacer(minLength: 8)
                Button(action: next) {
                    Text(nextLabel)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(PlateStyle.green)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)
            }
            .padding(24)
        }
    }
}

// MARK: - Selection Row

private struct SelectionRow: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(selected ? PlateStyle.green : .secondary)
                        .frame(width: 32, alignment: .center)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? PlateStyle.green : .secondary)
            }
            .padding(16)
            .background(
                selected ? PlateStyle.green.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? PlateStyle.green : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Height Slider (imperial) with text entry

private struct HeightSlider: View {
    @Binding var heightIn: Double
    @State private var inputText = ""
    @FocusState private var focused: Bool

    private var feetInchesDisplay: String {
        let feet = Int(heightIn) / 12
        let inches = Int(heightIn) % 12
        return "\(feet)' \(inches)\""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Height").font(.headline)
                Spacer()
                Text(feetInchesDisplay)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(PlateStyle.green)
            }
            Slider(value: $heightIn, in: 58...82, step: 1)
                .tint(PlateStyle.green)
                .onChange(of: heightIn) { _, v in
                    if !focused { inputText = "\(Int(v))" }
                }
            HStack(spacing: 6) {
                Text("or type:")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("\(Int(heightIn))", text: $inputText)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .onChange(of: inputText) { _, val in
                        if let v = Double(val), (58...82).contains(v) { heightIn = v }
                    }
                Text("inches total")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .onAppear { inputText = "\(Int(heightIn))" }
    }
}

// MARK: - Weight Slider (imperial) with text entry

private struct WeightSlider: View {
    @Binding var weightLbs: Double
    @State private var inputText = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Weight").font(.headline)
                Spacer()
                Text("\(Int(weightLbs)) lbs")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(PlateStyle.green)
            }
            Slider(value: $weightLbs, in: 90...400, step: 1)
                .tint(PlateStyle.green)
                .onChange(of: weightLbs) { _, v in
                    if !focused { inputText = "\(Int(v))" }
                }
            HStack(spacing: 6) {
                Text("or type:")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("\(Int(weightLbs))", text: $inputText)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 65)
                    .onChange(of: inputText) { _, val in
                        if let v = Double(val), (90...400).contains(v) { weightLbs = v }
                    }
                Text("lbs")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .onAppear { inputText = "\(Int(weightLbs))" }
    }
}
