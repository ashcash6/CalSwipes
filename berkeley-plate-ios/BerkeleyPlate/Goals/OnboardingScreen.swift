import SwiftUI

struct OnboardingScreen: View {
    var store: DailyStore
    var editMode: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var showManualEntry = false
    @State private var step: Int
    @State private var goalType: GoalType
    @State private var weeklyRateLbs: Double
    @State private var targetWeightText: String
    @State private var heightIn: Double
    @State private var weightLbs: Double
    @State private var activityLevel: ActivityLevel
    @State private var allergens: Set<String>
    @State private var dietaryTags: Set<String>

    init(store: DailyStore, editMode: Bool = false) {
        self.store = store
        self.editMode = editMode
        let goal = store.goal
        self._step = State(initialValue: 0)
        self._goalType = State(initialValue: goal?.goalType ?? .maintain)
        self._weeklyRateLbs = State(initialValue: goal?.weeklyRateLbs ?? 1.0)
        self._targetWeightText = State(initialValue: goal?.targetWeightLbs.map { "\(Int($0))" } ?? "")
        self._heightIn = State(initialValue: goal?.heightIn ?? 68)
        self._weightLbs = State(initialValue: goal?.weightLbs ?? 160)
        self._activityLevel = State(initialValue: goal?.activityLevel ?? .moderate)
        self._allergens = State(initialValue: Set(goal?.allergens ?? []))
        self._dietaryTags = State(initialValue: Set(goal?.dietaryTags ?? []))
    }

    // Steps 1 and 2 (target weight + weekly rate) are skipped when maintaining.
    private var skipGoalSteps: Bool { goalType == .maintain }

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
            // Target weight — skipped when goalType == .maintain
            OnboardingStepView(
                title: "What's your target weight?",
                subtitle: "Optional — used to estimate when you'll reach your goal."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        TextField("e.g. 155", text: $targetWeightText)
                            .keyboardType(.decimalPad)
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .padding(14)
                            .background(
                                Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .frame(maxWidth: 130)
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Spacer()
                                    Button("Done") {
                                        UIApplication.shared.sendAction(
                                            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                    }
                                }
                            }
                        Text("lbs")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("Skip this step if you don't have a specific weight in mind.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } next: { goForward() }

        case 2:
            // Weekly rate — skipped when goalType == .maintain
            let rateOptions: [(Double, String, String)] = goalType == .lose ? [
                (0.5, "Gradual",    "0.5 lb/week · ~250 kcal/day"),
                (1.0, "Steady",     "1 lb/week · ~500 kcal/day"),
                (1.5, "Moderate",   "1.5 lb/week · ~750 kcal/day"),
                (2.0, "Aggressive", "2 lb/week · ~1000 kcal/day"),
            ] : [
                (0.5, "Gradual",    "0.5 lb/week · ~250 kcal/day"),
                (1.0, "Steady",     "1 lb/week · ~500 kcal/day"),
                (1.5, "Moderate",   "1.5 lb/week · ~750 kcal/day"),
            ]
            OnboardingStepView(
                title: "How fast?",
                subtitle: goalType == .lose
                    ? "How quickly do you want to lose weight?"
                    : "How quickly do you want to gain weight?"
            ) {
                ForEach(rateOptions, id: \.0) { rate, title, subtitle in
                    SelectionRow(title: title, subtitle: subtitle,
                                 selected: weeklyRateLbs == rate) { weeklyRateLbs = rate }
                }
                Text("Want full control? Tap \"Input manually\" at the top to set your exact calorie target.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } next: { goForward() }

        case 3:
            OnboardingStepView(title: "Your measurements",
                               subtitle: "Used to estimate your daily calorie needs.") {
                HeightSlider(heightIn: $heightIn)
                WeightSlider(weightLbs: $weightLbs)
            } next: { goForward() }

        case 4:
            OnboardingStepView(title: "Activity level",
                               subtitle: "How active are you on a typical week?") {
                ForEach(ActivityLevel.allCases) { level in
                    SelectionRow(title: level.title, subtitle: level.subtitle,
                                 selected: activityLevel == level) { activityLevel = level }
                }
            } next: { goForward() }

        default:
            OnboardingStepView(title: "Dietary preferences",
                               subtitle: "We'll highlight allergens and tags on menu items.",
                               nextLabel: editMode ? "Save" : "Finish setup") {
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
                let targetWeight = Double(targetWeightText.trimmingCharacters(in: .whitespaces))
                store.saveGoal(UserGoal(
                    goalType: goalType, pace: .medium,
                    heightIn: heightIn, weightLbs: weightLbs,
                    activityLevel: activityLevel,
                    weeklyRateLbs: weeklyRateLbs,
                    targetWeightLbs: targetWeight,
                    allergens: allergens.sorted(),
                    dietaryTags: dietaryTags.sorted()
                ))
                if editMode { dismiss() }
                // else: saveGoal sets hasCompletedOnboarding = true → parent dismisses automatically
            }
        }
    }

    private var stepDots: some View {
        let totalDots = skipGoalSteps ? 4 : 6
        let dotIndex: Int = {
            if skipGoalSteps { return step == 0 ? 0 : max(0, step - 2) }
            return step
        }()
        return HStack(spacing: 6) {
            ForEach(0..<totalDots, id: \.self) { i in
                Capsule()
                    .fill(i <= dotIndex ? PlateStyle.green : Color.secondary.opacity(0.2))
                    .frame(height: 4)
                    .animation(.easeInOut, value: dotIndex)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func goForward() {
        withAnimation(.easeInOut(duration: 0.25)) {
            if step == 0 && skipGoalSteps { step = 3 } else { step += 1 }
        }
    }

    private func goBack() {
        withAnimation(.easeInOut(duration: 0.25)) {
            if step == 3 && skipGoalSteps { step = 0 } else { step -= 1 }
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
                .buttonStyle(CPPressStyle())
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
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
        .buttonStyle(CPPressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Height Slider (imperial) with text entry

private struct HeightSlider: View {
    @Binding var heightIn: Double
    @State private var draft: Double
    @State private var inputText: String
    @FocusState private var focused: Bool

    init(heightIn: Binding<Double>) {
        self._heightIn = heightIn
        self._draft = State(initialValue: heightIn.wrappedValue)
        self._inputText = State(initialValue: "\(Int(heightIn.wrappedValue))")
    }

    private var feetInchesDisplay: String {
        let feet = Int(draft) / 12
        let inches = Int(draft) % 12
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
            Slider(value: $draft, in: 58...82, step: 1, onEditingChanged: { editing in
                if !editing { heightIn = draft }
            })
            .tint(PlateStyle.green)
            .onChange(of: draft) { _, v in
                if !focused { inputText = "\(Int(v))" }
            }
            HStack(spacing: 6) {
                Text("or type:")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("\(Int(draft))", text: $inputText)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .onChange(of: inputText) { _, val in
                        if let v = Double(val), (58...82).contains(v) {
                            draft = v
                            heightIn = v
                        }
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { focused = false }
                        }
                    }
                Text("inches total")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Weight Slider (imperial) with text entry

private struct WeightSlider: View {
    @Binding var weightLbs: Double
    @State private var draft: Double
    @State private var inputText: String
    @FocusState private var focused: Bool

    init(weightLbs: Binding<Double>) {
        self._weightLbs = weightLbs
        self._draft = State(initialValue: weightLbs.wrappedValue)
        self._inputText = State(initialValue: "\(Int(weightLbs.wrappedValue))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Weight").font(.headline)
                Spacer()
                Text("\(Int(draft)) lbs")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(PlateStyle.green)
            }
            Slider(value: $draft, in: 90...400, step: 1, onEditingChanged: { editing in
                if !editing { weightLbs = draft }
            })
            .tint(PlateStyle.green)
            .onChange(of: draft) { _, v in
                if !focused { inputText = "\(Int(v))" }
            }
            HStack(spacing: 6) {
                Text("or type:")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("\(Int(draft))", text: $inputText)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 65)
                    .onChange(of: inputText) { _, val in
                        if let v = Double(val), (90...400).contains(v) {
                            draft = v
                            weightLbs = v
                        }
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { focused = false }
                        }
                    }
                Text("lbs")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
