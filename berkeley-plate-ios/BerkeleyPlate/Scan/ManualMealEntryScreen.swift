import SwiftUI

struct ManualMealEntryScreen: View {
    private let store: DailyStore
    @Environment(\.dismiss) private var dismiss

    @State private var mealName: String = ""
    @State private var caloriesText: String = ""
    @State private var proteinText: String = ""
    @State private var carbsText: String = ""
    @State private var fatText: String = ""
    @State private var activeField: MacroField?
    @State private var clearOnNextInput = false
    @State private var logged = false

    private enum MacroField { case calories, protein, carbs, fat }

    init(store: DailyStore) { self.store = store }

    private func parsePositive(_ text: String) -> Double? {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v > 0 else { return nil }
        return v
    }

    private var canLog: Bool {
        parsePositive(caloriesText) != nil
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Log a meal")
                                .font(.system(.title, design: .serif, weight: .semibold))
                            Text("Enter calories to log your meal. Name, protein, carbs, and fat are optional.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)

                        // Meal name
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Meal name (optional)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            TextField("e.g. David Bar, Greek Yogurt…", text: $mealName)
                                .textFieldStyle(.roundedBorder)
                                .font(.body)
                                .submitLabel(.done)
                                .onSubmit {
                                    UIApplication.shared.sendAction(
                                        #selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil
                                    )
                                }
                        }

                        // Macro entry rows
                        VStack(spacing: 12) {
                            EntryRow(label: "Calories", unit: "kcal", text: caloriesText,
                                     isActive: activeField == .calories) { activate(.calories) }
                            EntryRow(label: "Protein",  unit: "g",    text: proteinText,
                                     isActive: activeField == .protein) { activate(.protein) }
                            EntryRow(label: "Carbs",    unit: "g",    text: carbsText,
                                     isActive: activeField == .carbs) { activate(.carbs) }
                            EntryRow(label: "Fat",      unit: "g",    text: fatText,
                                     isActive: activeField == .fat) { activate(.fat) }
                        }

                        if !logged {
                            Button(action: logTapped) {
                                Text("Log meal")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .background(canLog ? PlateStyle.green : Color.secondary.opacity(0.25))
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 18))
                            }
                            .buttonStyle(.plain)
                            .disabled(!canLog)
                        } else {
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(PlateStyle.green)
                                Text("Meal logged!").font(.headline).foregroundStyle(PlateStyle.green)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(PlateStyle.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                        }
                    }
                    .padding(24)
                }
                .background(PlateStyle.cream)
                .safeAreaInset(edge: .bottom) {
                    if activeField != nil { Color.clear.frame(height: 320) }
                }

                if activeField != nil {
                    EntryNumpad(canLog: canLog,
                                onKey: handleKey,
                                onDone: { withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) { activeField = nil } },
                                onLog: logTapped)
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.spring(response: 0.2, dampingFraction: 0.85), value: activeField)
            .background(PlateStyle.cream)
            .navigationTitle("Log meal manually")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(PlateStyle.green)
    }

    private func activate(_ field: MacroField) {
        // Dismiss system keyboard (from name field) if open
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
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

    private func logTapped() {
        guard let kcal = parsePositive(caloriesText) else { return }
        let prot = parsePositive(proteinText) ?? 0
        let carb = parsePositive(carbsText) ?? 0
        let fat  = parsePositive(fatText) ?? 0
        let name = mealName.trimmingCharacters(in: .whitespaces)
        let macros = Macros(caloriesKcal: kcal, proteinG: prot, carbsG: carb, fatG: fat)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        store.logManualMeal(name: name.isEmpty ? "Manual entry" : name, macros: macros)
        withAnimation { logged = true }
        activeField = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { dismiss() }
    }
}

// MARK: - Display row

private struct EntryRow: View {
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
                Text(label).font(.headline).foregroundStyle(.primary)
                    .frame(minWidth: 72, alignment: .leading)
                Spacer()
                Text(text.isEmpty ? "—" : text)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(text.isEmpty ? Color.secondary : (isValid ? PlateStyle.green : Color.red.opacity(0.8)))
                    .frame(width: 90, alignment: .trailing)
                    .monospacedDigit()
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
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

// MARK: - Custom numpad

private struct EntryNumpad: View {
    let canLog: Bool
    let onKey: (String) -> Void
    let onDone: () -> Void
    let onLog: () -> Void

    private let rows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        [".",  "0", "⌫"],
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PlateStyle.green)
                    .padding(.trailing, 16).padding(.vertical, 8)
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
                                        Image(systemName: "delete.left").font(.system(size: 20))
                                    } else {
                                        Text(key).font(.system(size: 24, weight: .light, design: .rounded))
                                    }
                                }
                                .frame(maxWidth: .infinity).frame(height: 52).foregroundStyle(.primary)
                                .background(key == "⌫" ? Color(uiColor: .systemGray4)
                                                       : Color(uiColor: .secondarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button(action: onLog) {
                    Text("Log meal")
                        .font(.headline)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(.white)
                        .background(canLog ? PlateStyle.green : Color.secondary.opacity(0.25),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).disabled(!canLog)
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 20)
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }
}
