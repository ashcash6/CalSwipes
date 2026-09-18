import SwiftUI

struct OnboardingScreen: View {
    @ObservedObject var store: DailyStore
    var editMode: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var showManualEntry = false
    @State private var step: Int
    @State private var goalType: GoalType
    @State private var pace: Pace
    @State private var heightIn: Double
    @State private var weightLbs: Double
    @State private var activityLevel: ActivityLevel

    init(store: DailyStore, editMode: Bool = false) {
        self._store = ObservedObject(wrappedValue: store)
        self.editMode = editMode
        let goal = store.goal
        self._step = State(initialValue: 0)
        self._goalType = State(initialValue: goal?.goalType ?? .maintain)
        self._pace = State(initialValue: goal?.pace ?? .medium)
        self._heightIn = State(initialValue: goal?.heightIn ?? 68)
        self._weightLbs = State(initialValue: goal?.weightLbs ?? 160)
        self._activityLevel = State(initialValue: goal?.activityLevel ?? .moderate)
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
        default:
            OnboardingStepView(title: "Activity level",
                               subtitle: "How active are you on a typical week?",
                               nextLabel: "Set my goals") {
                ForEach(ActivityLevel.allCases) { level in
                    SelectionRow(title: level.title, subtitle: level.subtitle,
                                 selected: activityLevel == level) { activityLevel = level }
                }
            } next: {
                store.saveGoal(UserGoal(goalType: goalType, pace: pace,
                                       heightIn: heightIn, weightLbs: weightLbs,
                                       activityLevel: activityLevel))
                if editMode { dismiss() }
            }
        }
    }

    private var stepDots: some View {
        let count = skipsPace ? 3 : 4
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
