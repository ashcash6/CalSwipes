import SwiftUI

struct ProfileScreen: View {
    var daily: DailyStore
    var store: AppStore
    @State private var showGoalSheet = false
    @State private var showDietarySheet = false
    @State private var showRecurringFoods = false
    @State private var showWeight = false
    @State private var showAbout = false

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
                            .foregroundStyle(CP.text)
                    } else {
                        Text("No goal set")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(CP.textSec)
                    }
                }
                Spacer()
                Button {
                    showGoalSheet = true
                } label: {
                    Text("Edit")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(CP.navy)
                        .padding(.horizontal, CP.sp12)
                        .padding(.vertical, CP.sp8)
                        .background(CP.navy.opacity(0.08), in: RoundedRectangle(cornerRadius: CP.r8))
                }
                .buttonStyle(.plain)
            }

            if let goal = daily.goal {
                CPDivider()

                HStack(spacing: 0) {
                    CPMacroStat(value: goal.targetProteinG, unit: "g", label: "Protein", color: CP.protein)
                    CPDivider().frame(width: 0.5, height: 36)
                    CPMacroStat(value: goal.targetCarbsG, unit: "g", label: "Carbs", color: CP.carbs)
                    CPDivider().frame(width: 0.5, height: 36)
                    CPMacroStat(value: goal.targetFatG, unit: "g", label: "Fat", color: CP.fat)
                }

                if daily.currentStreak > 0 {
                    CPDivider()
                    HStack(spacing: CP.sp8) {
                        Text("🔥")
                        Text("\(daily.currentStreak)-day logging streak")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(CP.text)
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
        VStack(spacing: 0) {
            CPSectionLabel(text: "Preferences")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, CP.sp8)

            VStack(spacing: 0) {
                ProfileRow(icon: "fork.knife.circle.fill", label: "Dietary restrictions") {
                    showDietarySheet = true
                }
                CPDivider().padding(.leading, 48)
                ProfileRow(icon: "repeat.circle.fill", label: "Recurring foods") {
                    showRecurringFoods = true
                }
                CPDivider().padding(.leading, 48)
                ProfileRow(icon: "scalemass.fill", label: "Weight tracking") {
                    showWeight = true
                }
            }
            .cpCard(0)
        }
    }

    private var appSection: some View {
        VStack(spacing: 0) {
            CPSectionLabel(text: "App")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, CP.sp8)

            VStack(spacing: 0) {
                ProfileRow(icon: "info.circle.fill", label: "About CalPlate") {
                    showAbout = true
                }
            }
            .cpCard(0)
        }
    }
}

// MARK: - Profile row

private struct ProfileRow: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: CP.sp12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(CP.navy)
                    .frame(width: 28)
                Text(label)
                    .font(.body)
                    .foregroundStyle(CP.text)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CP.textSec)
            }
            .padding(.horizontal, CP.sp16)
            .padding(.vertical, CP.sp14)
        }
        .buttonStyle(.plain)
    }
}
