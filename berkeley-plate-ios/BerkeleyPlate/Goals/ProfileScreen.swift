import SwiftUI

struct ProfileScreen: View {
    var daily: DailyStore
    var store: AppStore
    @State private var showGoalSheet = false
    @State private var showDietarySheet = false
    @State private var showRecurringFoods = false
    @State private var showWeight = false
    @State private var showAbout = false
    @State private var showAppearancePicker = false
    @AppStorage("appearancePref") private var appearancePref = "system"

    private var appearanceLabel: String {
        switch appearancePref {
        case "light": return "Light"
        case "dark":  return "Dark"
        default:      return "System"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CP.sp16) {
                    goalCard
                    actionsSection
                    appSection
                }
                .padding(CP.sp20)
            }
            .background(CP.bg)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
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
        .sheet(isPresented: $showWeight) {
            WeightScreen(daily: daily)
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
    }

    // MARK: - Goal card

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: CP.sp16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    CPSectionLabel(text: "Daily targets")
                    if let goal = daily.goal {
                        Text("\(Int(goal.targetCalories)) kcal")
                            .font(.system(.title, design: .rounded, weight: .bold))
                    } else {
                        Text("No goal set")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Edit") { showGoalSheet = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CP.navy)
                    .padding(.horizontal, CP.sp12)
                    .padding(.vertical, CP.sp8)
                    .background(CP.navy.opacity(0.08), in: RoundedRectangle(cornerRadius: CP.r8))
                    .buttonStyle(CPPressStyle())
            }

            if let goal = daily.goal {
                Divider()

                HStack(spacing: 0) {
                    CPMacroStat(value: goal.targetProteinG, unit: "g", label: "Protein", color: CP.protein)
                    Divider().frame(width: 0.5, height: 36)
                    CPMacroStat(value: goal.targetCarbsG, unit: "g", label: "Carbs", color: CP.carbs)
                    Divider().frame(width: 0.5, height: 36)
                    CPMacroStat(value: goal.targetFatG, unit: "g", label: "Fat", color: CP.fat)
                }

                if daily.currentStreak > 0 {
                    Divider()
                    HStack(spacing: CP.sp8) {
                        Text("🔥")
                        Text("\(daily.currentStreak)-day logging streak")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                    }
                }
            } else {
                CPPrimaryButton(title: "Set up your goal", icon: "target") {
                    showGoalSheet = true
                }
            }
        }
        .cpCard()
    }

    // MARK: - Action rows

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: CP.sp8) {
            CPSectionLabel(text: "Preferences")

            VStack(spacing: 0) {
                ProfileRow(icon: "fork.knife.circle.fill", label: "Dietary restrictions") {
                    showDietarySheet = true
                }
                Divider().padding(.leading, 52)
                ProfileRow(icon: "repeat.circle.fill", label: "Recurring foods") {
                    showRecurringFoods = true
                }
                Divider().padding(.leading, 52)
                ProfileRow(icon: "scalemass.fill", label: "Weight tracking",
                           badge: !daily.weightEntries.contains { $0.date == BerkeleyClock.serviceDate() }) {
                    showWeight = true
                }
            }
            .background(CP.surface, in: RoundedRectangle(cornerRadius: CP.r16))
            .shadow(color: .black.opacity(CP.shadowOpacity), radius: CP.shadowRadius, x: 0, y: CP.shadowY)
        }
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: CP.sp8) {
            CPSectionLabel(text: "App")

            VStack(spacing: 0) {
                ProfileRow(icon: "circle.lefthalf.filled", label: "Appearance", value: appearanceLabel) {
                    showAppearancePicker = true
                }
                Divider().padding(.leading, 52)
                ProfileRow(icon: "info.circle.fill", label: "About CalPlate") {
                    showAbout = true
                }
            }
            .background(CP.surface, in: RoundedRectangle(cornerRadius: CP.r16))
            .shadow(color: .black.opacity(CP.shadowOpacity), radius: CP.shadowRadius, x: 0, y: CP.shadowY)
        }
        .confirmationDialog("Appearance", isPresented: $showAppearancePicker) {
            Button("System") { appearancePref = "system" }
            Button("Light")  { appearancePref = "light" }
            Button("Dark")   { appearancePref = "dark" }
            Button("Cancel", role: .cancel) { }
        }
    }
}

// MARK: - Profile row

private struct ProfileRow: View {
    let icon: String
    let label: String
    var value: String? = nil
    var badge: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: CP.sp12) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.body)
                        .foregroundStyle(CP.navy)
                        .frame(width: 28)
                    if badge {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -3)
                    }
                }
                Text(label)
                    .font(.body)
                Spacer()
                if let value {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, CP.sp16)
            .padding(.vertical, CP.sp14)
            .contentShape(Rectangle())
        }
        .buttonStyle(CPPressStyle())
    }
}
