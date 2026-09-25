import SwiftUI

struct ManualMacrosScreen: View {
    @Binding var isPresented: Bool
    private let store: DailyStore
    private let ref: ComputedRef?

    @State private var caloriesText: String
    @State private var proteinText: String
    @State private var carbsText: String
    @State private var fatText: String
    @State private var activeField: MacroField?
    @State private var clearOnNextInput = false

    enum MacroField { case calories, protein, carbs, fat }

    struct ComputedRef {
        let calories: Double; let protein: Double; let carbs: Double; let fat: Double
    }

    init(store: DailyStore, isPresented: Binding<Bool>) {
        self.store = store
        self._isPresented = isPresented
        let g = store.goal
        self.ref = g.map {
            ComputedRef(calories: $0.computedCalories, protein: $0.computedProteinG,
                        carbs: $0.computedCarbsG, fat: $0.computedFatG)
        }
        self._caloriesText = State(initialValue: g.map { "\(Int($0.targetCalories))" } ?? "2000")
        self._proteinText  = State(initialValue: g.map { "\(Int($0.targetProteinG))"  } ?? "150")
        self._carbsText    = State(initialValue: g.map { "\(Int($0.targetCarbsG))"    } ?? "225")
        self._fatText      = State(initialValue: g.map { "\(Int($0.targetFatG))"      } ?? "67")
    }

    private func parsePositive(_ text: String) -> Double? {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v > 0 else { return nil }
        return v
    }

    private var canSave: Bool {
        [caloriesText, proteinText, carbsText, fatText].allSatisfy { parsePositive($0) != nil }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Set your targets")
                            .font(.system(.title, design: .serif, weight: .semibold))
                        Text("Enter daily targets directly. These override the values calculated from your profile.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    VStack(spacing: 12) {
                        MacroDisplayRow(label: "Calories", unit: "kcal", text: caloriesText,
                                        isActive: activeField == .calories) { activate(.calories) }
                        MacroDisplayRow(label: "Protein",  unit: "g",    text: proteinText,
                                        isActive: activeField == .protein) { activate(.protein) }
                        MacroDisplayRow(label: "Carbs",    unit: "g",    text: carbsText,
                                        isActive: activeField == .carbs) { activate(.carbs) }
                        MacroDisplayRow(label: "Fat",      unit: "g",    text: fatText,
                                        isActive: activeField == .fat) { activate(.fat) }
                    }

                    if let r = ref {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Calculated from your profile")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            HStack(spacing: 0) {
                                CalcCell(label: "Calories", value: Int(r.calories), unit: "kcal")
                                CalcCell(label: "Protein",  value: Int(r.protein),  unit: "g")
                                CalcCell(label: "Carbs",    value: Int(r.carbs),    unit: "g")
                                CalcCell(label: "Fat",      value: Int(r.fat),      unit: "g")
                            }
                            Button {
                                caloriesText = "\(Int(r.calories))"
                                proteinText  = "\(Int(r.protein))"
                                carbsText    = "\(Int(r.carbs))"
                                fatText      = "\(Int(r.fat))"
                                activeField  = nil
                            } label: {
                                Label("Use calculated values", systemImage: "arrow.counterclockwise")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(PlateStyle.green)
                        }
                        .padding(16)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 16))
                    }

                    Button(action: saveTapped) {
                        Text("Save targets")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(canSave ? PlateStyle.green : Color.secondary.opacity(0.25))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)

                    Text("These targets are only used within CalSwipes.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(24)
            }
            .background(PlateStyle.cream)
            .safeAreaInset(edge: .bottom) {
                if activeField != nil { Color.clear.frame(height: 320) }
            }

            if activeField != nil {
                MacroNumpad(canSave: canSave, onKey: handleKey,
                            onDone: { withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) { activeField = nil } },
                            onSave: saveAndStay)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: activeField)
        .background(PlateStyle.cream)
        .navigationTitle("Manual targets")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func activate(_ field: MacroField) {
        // Switching to a new field clears on next keystroke; re-tapping same field does not
        clearOnNextInput = (activeField != field)
        activeField = field
    }

    private func handleKey(_ key: String) {
        guard let field = activeField else { return }

        var t: String
        switch field {
        case .calories: t = caloriesText
        case .protein:  t = proteinText
        case .carbs:    t = carbsText
        case .fat:      t = fatText
        }

        if clearOnNextInput {
            clearOnNextInput = false
            switch key {
            case "⌫": t = ""
            case ".":  t = "0."
            default:   t = key
            }
        } else {
            switch key {
            case "⌫": if !t.isEmpty { t.removeLast() }
            case ".":  if !t.contains(".") { t = t.isEmpty ? "0." : t + "." }
            default:   if t.count < 6 { t += key }
            }
        }

        switch field {
        case .calories: caloriesText = t
        case .protein:  proteinText = t
        case .carbs:    carbsText = t
        case .fat:      fatText = t
        }
    }

    // Numpad Save: just closes the numpad — values stay in @State, nothing navigates
    private func saveAndStay() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) { activeField = nil }
    }

    // Content "Save targets" button: commit to store and go back to the survey
    private func saveTapped() {
        guard let kcal = parsePositive(caloriesText),
              let prot = parsePositive(proteinText),
              let carb = parsePositive(carbsText),
              let fat  = parsePositive(fatText) else { return }

        var updated = store.goal ?? UserGoal(
            goalType: .maintain, pace: .medium,
            heightIn: 68, weightLbs: 160, activityLevel: .moderate
        )
        updated.manualCalories = kcal
        updated.manualProteinG = prot
        updated.manualCarbsG   = carb
        updated.manualFatG     = fat
        store.saveGoal(updated)
        isPresented = false
    }
}

// MARK: - Tappable display row (no system keyboard)

private struct MacroDisplayRow: View {
    let label: String
    let unit: String
    let text: String
    let isActive: Bool
    let onTap: () -> Void

    private var isValid: Bool {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v > 0 else { return false }
        return true
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Text(label)
                    .font(.headline).foregroundStyle(.primary)
                    .frame(minWidth: 72, alignment: .leading)
                Spacer()
                Text(text.isEmpty ? "—" : text)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(isValid ? PlateStyle.green : Color.red.opacity(0.8))
                    .frame(width: 90, alignment: .trailing)
                    .monospacedDigit()
                Text(unit)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(PlateStyle.green.opacity(isActive ? 1.0 : 0.0), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Custom number pad with Save at the bottom

private struct MacroNumpad: View {
    let canSave: Bool
    let onKey: (String) -> Void
    let onDone: () -> Void
    let onSave: () -> Void

    private let rows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        [".",  "0", "⌫"],
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Dismiss handle
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PlateStyle.green)
                    .padding(.trailing, 16)
                    .padding(.vertical, 8)
            }
            .background(Color(uiColor: .systemGroupedBackground))

            Divider()

            VStack(spacing: 6) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { key in
                            Button { onKey(key) } label: {
                                Group {
                                    if key == "⌫" {
                                        Image(systemName: "delete.left")
                                            .font(.system(size: 20))
                                    } else {
                                        Text(key)
                                            .font(.system(size: 24, weight: .light, design: .rounded))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .foregroundStyle(.primary)
                                .background(
                                    key == "⌫"
                                        ? Color(uiColor: .systemGray4)
                                        : Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Save row — directly below the last number row
                Button(action: onSave) {
                    Text("Save")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(.white)
                        .background(
                            canSave ? PlateStyle.green : Color.secondary.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 20)
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }
}

// MARK: - Calculated reference cell

private struct CalcCell: View {
    let label: String; let value: Int; let unit: String
    var body: some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(PlateStyle.green)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
