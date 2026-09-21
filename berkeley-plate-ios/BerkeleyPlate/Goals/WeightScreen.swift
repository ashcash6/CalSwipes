import Charts
import SwiftUI

// MARK: - Design tokens (dark, vibrant)

private enum W {
    static let bg      = Color.black
    static let card    = Color(white: 0.09)
    static let surface = Color(white: 0.14)
    static let accent  = Color(red: 0.12, green: 0.92, blue: 0.60)   // bright mint
    static let warn    = Color(red: 1.0,  green: 0.38, blue: 0.18)   // vivid orange
    static let red     = Color(red: 1.0,  green: 0.27, blue: 0.27)   // bad-trend red
}

// MARK: - WeightScreen

struct WeightScreen: View {
    var daily: DailyStore
    @State private var showDeleteAlert = false
    @State private var deletionTarget: WeightEntry?
    @State private var editingEntry: WeightEntry?

    private var todayEntry: WeightEntry? {
        daily.recentWeightEntries.last(where: { $0.date == daily.todayDate })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                W.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        heroHeader
                        if todayEntry == nil { reminderBanner }
                        WeightInputCard(todayEntry: todayEntry, onSave: { daily.logWeight($0) })
                        if !daily.recentWeightEntries.isEmpty {
                            trendCard
                            statsRow
                            historyCard
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(W.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .alert("Delete entry?", isPresented: $showDeleteAlert, presenting: deletionTarget) { entry in
            Button("Delete", role: .destructive) { daily.deleteWeightEntry(id: entry.id) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(
                "\(entry.weightLbs.formatted(.number.precision(.fractionLength(1)))) lbs" +
                " on \(entry.displayDate.formatted(date: .abbreviated, time: .omitted))"
            )
        }
        .sheet(item: $editingEntry) { entry in
            WeightEditSheet(entry: entry) { newWeight in
                daily.updateWeightEntry(id: entry.id, weightLbs: newWeight)
            }
        }
    }

    // MARK: - Hero

    private var heroHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CURRENT WEIGHT")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(1.4)

                if let last = daily.recentWeightEntries.last {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(last.weightLbs.formatted(.number.precision(.fractionLength(1))))
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .foregroundStyle(W.accent)
                        Text("lbs")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.bottom, 4)
                    }
                } else {
                    Text("—")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.2))
                }
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Reminder

    private var reminderBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "bell.badge.fill")
                .font(.title3)
                .foregroundStyle(W.warn)
            VStack(alignment: .leading, spacing: 3) {
                Text("Log today's weight")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Consistent tracking leads to better results.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(16)
        .background(W.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(W.warn.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Trend chart

    /// Green if the weight trend matches the goal direction, red otherwise.
    private var lineColor: Color {
        guard daily.recentWeightEntries.count >= 2,
              let first = daily.recentWeightEntries.first,
              let last = daily.recentWeightEntries.last else { return W.accent }
        let delta = last.weightLbs - first.weightLbs
        guard let goal = daily.goal else { return W.accent }
        switch goal.goalType {
        case .lose:     return delta <= 0 ? W.accent : W.red
        case .gain:     return delta >= 0 ? W.accent : W.red
        case .maintain: return W.accent
        }
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("30-DAY TREND")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1.4)

            Chart(daily.recentWeightEntries) { entry in
                LineMark(
                    x: .value("Date", entry.displayDate, unit: .day),
                    y: .value("Weight", entry.weightLbs)
                )
                .foregroundStyle(lineColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Date", entry.displayDate, unit: .day),
                    y: .value("Weight", entry.weightLbs)
                )
                .foregroundStyle(lineColor)
                .symbolSize(22)
            }
            .chartYScale(domain: chartYDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: chartStride)) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .foregroundStyle(Color.white.opacity(0.38))
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v))")
                                .foregroundStyle(Color.white.opacity(0.38))
                        }
                    }
                }
            }
            .frame(height: 190)
        }
        .padding(20)
        .background(W.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var chartYDomain: ClosedRange<Double> {
        let weights = daily.recentWeightEntries.map(\.weightLbs)
        guard let minW = weights.min(), let maxW = weights.max() else { return 100...200 }
        let spread = Swift.max(10.0, maxW - minW)
        return (minW - spread * 0.28)...(maxW + spread * 0.28)
    }

    private var chartStride: Int {
        let count = daily.recentWeightEntries.count
        if count <= 7 { return 1 }
        if count <= 14 { return 3 }
        return 7
    }

    // MARK: - Stats row

    private func deltaColor(_ delta: Double) -> Color {
        guard let goal = daily.goal else { return delta < 0 ? W.accent : W.warn }
        switch goal.goalType {
        case .lose:     return delta <= 0 ? W.accent : W.red
        case .gain:     return delta >= 0 ? W.accent : W.red
        case .maintain: return W.accent
        }
    }

    @ViewBuilder
    private var statsRow: some View {
        let entries = daily.recentWeightEntries
        if entries.count >= 2, let first = entries.first, let last = entries.last {
            let delta = last.weightLbs - first.weightLbs
            HStack(spacing: 0) {
                WStatCell(
                    label: "Current",
                    value: last.weightLbs.formatted(.number.precision(.fractionLength(1))),
                    unit: "lbs",
                    color: W.accent
                )
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 38)
                WStatCell(
                    label: "30-day Δ",
                    value: (delta >= 0 ? "+" : "") + delta.formatted(.number.precision(.fractionLength(1))),
                    unit: "lbs",
                    color: deltaColor(delta)
                )
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 38)
                WStatCell(label: "Entries", value: "\(entries.count)", unit: nil, color: .white)
            }
            .padding(.vertical, 18)
            .background(W.card, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    // MARK: - History list

    private var historyCard: some View {
        let entries = daily.recentWeightEntries.sorted { $0.date > $1.date }.prefix(25)
        return VStack(alignment: .leading, spacing: 0) {
            Text("HISTORY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1.4)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ForEach(Array(entries)) { entry in
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 0.5)
                        .padding(.leading, 20)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.weightLbs.formatted(.number.precision(.fractionLength(1))) + " lbs")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(entry.displayDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Spacer()
                        if entry.date == daily.todayDate {
                            Text("Today")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(W.accent)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(W.accent.opacity(0.15), in: Capsule())
                        }
                        Button {
                            editingEntry = entry
                        } label: {
                            Image(systemName: "pencil.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.white.opacity(0.2))
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 8)
                        Button {
                            deletionTarget = entry
                            showDeleteAlert = true
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.white.opacity(0.2))
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 4)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
            Spacer(minLength: 8)
        }
        .background(W.card, in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Input card (own @State so typing doesn't re-render the chart)

private struct WeightInputCard: View {
    let todayEntry: WeightEntry?
    let onSave: (Double) -> Void
    @State private var inputText = ""
    @FocusState private var fieldFocused: Bool

    private var parsedInput: Double? {
        guard let v = Double(inputText.replacingOccurrences(of: ",", with: ".")),
              v > 50, v < 1000 else { return nil }
        return v
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LOG TODAY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1.4)

            HStack(spacing: 10) {
                TextField("165.5", text: $inputText)
                    .keyboardType(.decimalPad)
                    .focused($fieldFocused)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .tint(W.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(W.surface, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: 150)

                Text("lbs")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))

                Spacer()

                if fieldFocused {
                    Button("Cancel") {
                        inputText = ""
                        fieldFocused = false
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }

                Button("Save") {
                    guard let value = parsedInput else { return }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onSave(value)
                    inputText = ""
                    fieldFocused = false
                }
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(
                    parsedInput != nil ? W.accent : W.surface,
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .foregroundStyle(parsedInput != nil ? Color.black : Color.white.opacity(0.2))
                .disabled(parsedInput == nil)
                .animation(.easeInOut(duration: 0.15), value: parsedInput != nil)
            }
            .animation(.easeInOut(duration: 0.15), value: fieldFocused)

            if let today = todayEntry {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(W.accent)
                    Text("Logged today: \(today.weightLbs.formatted(.number.precision(.fractionLength(1)))) lbs")
                        .foregroundStyle(.white.opacity(0.55))
                }
                .font(.caption)
            }
        }
        .padding(20)
        .background(W.card, in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Stat cell

private struct WStatCell: View {
    let label: String
    let value: String
    let unit: String?
    let color: Color

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(color)
                if let unit {
                    Text(unit)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(color.opacity(0.55))
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.38))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Weight Edit Sheet

private struct WeightEditSheet: View {
    let entry: WeightEntry
    let onSave: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var inputText: String

    init(entry: WeightEntry, onSave: @escaping (Double) -> Void) {
        self.entry  = entry
        self.onSave = onSave
        _inputText  = State(initialValue: entry.weightLbs.formatted(.number.precision(.fractionLength(1))))
    }

    private var parsedInput: Double? {
        guard let v = Double(inputText.replacingOccurrences(of: ",", with: ".")),
              v > 50, v < 1000 else { return nil }
        return v
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(entry.displayDate.formatted(date: .long, time: .omitted)) {
                    LabeledContent("Weight (lbs)") {
                        TextField("165.5", text: $inputText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let v = parsedInput else { return }
                        onSave(v)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(parsedInput == nil)
                }
            }
        }
    }
}
