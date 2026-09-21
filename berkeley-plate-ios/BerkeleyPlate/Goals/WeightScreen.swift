import Charts
import SwiftUI

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
            ScrollView {
                VStack(alignment: .leading, spacing: CP.sp16) {
                    heroHeader
                    if todayEntry == nil { reminderBanner }
                    WeightInputCard(todayEntry: todayEntry, onSave: { daily.logWeight($0) })
                    if !daily.recentWeightEntries.isEmpty {
                        trendCard
                        statsRow
                        historyCard
                    }
                }
                .padding(CP.sp20)
            }
            .background(CP.bg)
            .navigationTitle("Weight")
            .navigationBarTitleDisplayMode(.inline)
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
                CPSectionLabel(text: "Current weight")
                if let last = daily.recentWeightEntries.last {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(last.weightLbs.formatted(.number.precision(.fractionLength(1))))
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .foregroundStyle(CP.navy)
                        Text("lbs")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(CP.textSec)
                            .padding(.bottom, 4)
                    }
                } else {
                    Text("No entries yet")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(CP.textSec)
                }
            }
            Spacer()
        }
        .padding(.top, CP.sp8)
    }

    // MARK: - Reminder

    private var reminderBanner: some View {
        HStack(spacing: CP.sp14) {
            Image(systemName: "bell.badge.fill")
                .font(.title3)
                .foregroundStyle(CP.carbs)
            VStack(alignment: .leading, spacing: 3) {
                Text("Log today's weight")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CP.text)
                Text("Consistent tracking leads to better results.")
                    .font(.caption)
                    .foregroundStyle(CP.textSec)
            }
            Spacer()
        }
        .padding(CP.sp16)
        .background(CP.carbs.opacity(0.08), in: RoundedRectangle(cornerRadius: CP.r16))
        .overlay(RoundedRectangle(cornerRadius: CP.r16).strokeBorder(CP.carbs.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Trend chart

    private var lineColor: Color {
        guard daily.recentWeightEntries.count >= 2,
              let first = daily.recentWeightEntries.first,
              let last  = daily.recentWeightEntries.last else { return CP.navy }
        let delta = last.weightLbs - first.weightLbs
        guard let goal = daily.goal else { return CP.navy }
        switch goal.goalType {
        case .lose:     return delta <= 0 ? CP.navy : CP.protein
        case .gain:     return delta >= 0 ? CP.navy : CP.protein
        case .maintain: return CP.navy
        }
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: CP.sp14) {
            CPSectionLabel(text: "30-day trend")

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
                    AxisGridLine().foregroundStyle(CP.border)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(CP.border)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v))").foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
            .frame(height: 190)
        }
        .cpCard(CP.sp20)
    }

    private var chartYDomain: ClosedRange<Double> {
        let weights = daily.recentWeightEntries.map(\.weightLbs)
        guard let minW = weights.min(), let maxW = weights.max() else { return 100...200 }
        let spread = Swift.max(10.0, maxW - minW)
        return (minW - spread * 0.28)...(maxW + spread * 0.28)
    }

    private var chartStride: Int {
        let count = daily.recentWeightEntries.count
        if count <= 7  { return 1 }
        if count <= 14 { return 3 }
        return 7
    }

    // MARK: - Stats row

    private func deltaColor(_ delta: Double) -> Color {
        guard let goal = daily.goal else { return delta < 0 ? CP.navy : CP.carbs }
        switch goal.goalType {
        case .lose:     return delta <= 0 ? CP.navy : CP.protein
        case .gain:     return delta >= 0 ? CP.navy : CP.protein
        case .maintain: return CP.navy
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
                    color: CP.navy
                )
                Divider().frame(height: 38)
                WStatCell(
                    label: "30-day Δ",
                    value: (delta >= 0 ? "+" : "") + delta.formatted(.number.precision(.fractionLength(1))),
                    unit: "lbs",
                    color: deltaColor(delta)
                )
                Divider().frame(height: 38)
                WStatCell(label: "Entries", value: "\(entries.count)", unit: nil, color: CP.text)
            }
            .padding(.vertical, CP.sp8)
            .background(CP.surface)
            .clipShape(RoundedRectangle(cornerRadius: CP.r16))
            .shadow(color: .black.opacity(CP.shadowOpacity), radius: CP.shadowRadius, x: 0, y: CP.shadowY)
        }
    }

    // MARK: - History list

    private var historyCard: some View {
        let entries = daily.recentWeightEntries.sorted { $0.date > $1.date }.prefix(25)
        return VStack(alignment: .leading, spacing: 0) {
            CPSectionLabel(text: "History")
                .padding(.horizontal, CP.sp20)
                .padding(.top, CP.sp16)
                .padding(.bottom, CP.sp12)

            ForEach(Array(entries)) { entry in
                VStack(spacing: 0) {
                    Divider().padding(.leading, CP.sp20)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.weightLbs.formatted(.number.precision(.fractionLength(1))) + " lbs")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(CP.text)
                            Text(entry.displayDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(CP.textSec)
                        }
                        Spacer()
                        if entry.date == daily.todayDate {
                            Text("Today")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(CP.navy)
                                .padding(.horizontal, CP.sp10).padding(.vertical, CP.sp4)
                                .background(CP.navy.opacity(0.08), in: Capsule())
                        }
                        Button {
                            editingEntry = entry
                        } label: {
                            Image(systemName: "pencil.circle.fill")
                                .font(.title3)
                                .foregroundStyle(CP.textSec)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, CP.sp8)
                        Button {
                            deletionTarget = entry
                            showDeleteAlert = true
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(CP.textSec)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, CP.sp4)
                    }
                    .padding(.horizontal, CP.sp20)
                    .padding(.vertical, CP.sp14)
                }
            }
            Spacer(minLength: CP.sp8)
        }
        .background(CP.surface)
        .clipShape(RoundedRectangle(cornerRadius: CP.r16))
        .shadow(color: .black.opacity(CP.shadowOpacity), radius: CP.shadowRadius, x: 0, y: CP.shadowY)
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
        VStack(alignment: .leading, spacing: CP.sp12) {
            CPSectionLabel(text: "Log today")

            HStack(spacing: CP.sp10) {
                TextField("165.5", text: $inputText)
                    .keyboardType(.decimalPad)
                    .focused($fieldFocused)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(CP.text)
                    .tint(CP.navy)
                    .padding(.horizontal, CP.sp14)
                    .padding(.vertical, CP.sp12)
                    .background(CP.surface2, in: RoundedRectangle(cornerRadius: CP.r12))
                    .frame(maxWidth: 150)

                Text("lbs")
                    .font(.subheadline)
                    .foregroundStyle(CP.textSec)

                Spacer()

                if fieldFocused {
                    Button("Cancel") {
                        inputText = ""
                        fieldFocused = false
                    }
                    .font(.subheadline)
                    .foregroundStyle(CP.textSec)
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
                .padding(.horizontal, CP.sp16)
                .padding(.vertical, CP.sp12)
                .background(
                    parsedInput != nil ? CP.navy : CP.surface2,
                    in: RoundedRectangle(cornerRadius: CP.r12)
                )
                .foregroundStyle(parsedInput != nil ? Color.white : CP.textSec)
                .disabled(parsedInput == nil)
                .animation(.easeInOut(duration: 0.15), value: parsedInput != nil)
            }
            .animation(.easeInOut(duration: 0.15), value: fieldFocused)

            if let today = todayEntry {
                HStack(spacing: CP.sp8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(CP.navy)
                    Text("Logged today: \(today.weightLbs.formatted(.number.precision(.fractionLength(1)))) lbs")
                        .foregroundStyle(CP.textSec)
                }
                .font(.caption)
            }
        }
        .cpCard(CP.sp20)
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
                        .foregroundStyle(color.opacity(0.7))
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(CP.textSec)
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
