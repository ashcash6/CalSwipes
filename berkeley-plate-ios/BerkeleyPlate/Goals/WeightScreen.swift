import Charts
import SwiftUI

struct WeightScreen: View {
    @ObservedObject var daily: DailyStore
    @State private var inputText = ""
    @State private var showDeleteAlert = false
    @State private var deletionTarget: WeightEntry?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    logCard
                    if !daily.recentWeightEntries.isEmpty {
                        chartCard
                        summaryCard
                    } else {
                        ContentUnavailableView(
                            "No entries yet",
                            systemImage: "scalemass",
                            description: Text("Log your weight above to start tracking your progress.")
                        )
                    }
                }
                .padding(20)
            }
            .background(PlateStyle.cream)
            .navigationTitle("Weight")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("Delete entry?", isPresented: $showDeleteAlert, presenting: deletionTarget) { entry in
            Button("Delete", role: .destructive) { daily.deleteWeightEntry(id: entry.id) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("\(entry.weightLbs.formatted(.number.precision(.fractionLength(1)))) lbs on \(entry.displayDate.formatted(date: .abbreviated, time: .omitted))")
        }
    }

    // MARK: - Log card

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Log today's weight")
                .font(.headline)
            HStack(spacing: 12) {
                TextField("e.g. 165.5", text: $inputText)
                    .keyboardType(.decimalPad)
                    .focused($fieldFocused)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                Text("lbs")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save") { commitWeight() }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsedInput == nil)
            }
            if let today = daily.recentWeightEntries.last(where: { $0.date == daily.todayDate }) {
                Label("Today: \(today.weightLbs.formatted(.number.precision(.fractionLength(1)))) lbs",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(PlateStyle.green)
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var parsedInput: Double? {
        guard let v = Double(inputText.replacingOccurrences(of: ",", with: ".")),
              v > 50, v < 1000 else { return nil }
        return v
    }

    private func commitWeight() {
        guard let value = parsedInput else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        daily.logWeight(value)
        inputText = ""
        fieldFocused = false
    }

    // MARK: - Chart card

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Last 30 days")
                .font(.headline)
            Chart(daily.recentWeightEntries) { entry in
                LineMark(
                    x: .value("Date", entry.displayDate, unit: .day),
                    y: .value("Weight", entry.weightLbs)
                )
                .foregroundStyle(PlateStyle.green)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Date", entry.displayDate, unit: .day),
                    y: .value("Weight", entry.weightLbs)
                )
                .foregroundStyle(PlateStyle.green)
                .symbolSize(44)
            }
            .chartYScale(domain: chartYDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: chartStride)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))") } }
                }
            }
            .frame(height: 220)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var chartYDomain: ClosedRange<Double> {
        let weights = daily.recentWeightEntries.map(\.weightLbs)
        guard let minW = weights.min(), let maxW = weights.max() else { return 100...200 }
        let spread = Swift.max(10.0, (maxW - minW))
        let padding = spread * 0.25
        return (minW - padding)...(maxW + padding)
    }

    private var chartStride: Int {
        let count = daily.recentWeightEntries.count
        if count <= 7 { return 1 }
        if count <= 14 { return 3 }
        return 7
    }

    // MARK: - Summary card

    @ViewBuilder
    private var summaryCard: some View {
        let entries = daily.recentWeightEntries
        if entries.count >= 2, let first = entries.first, let last = entries.last {
            let delta = last.weightLbs - first.weightLbs
            VStack(alignment: .leading, spacing: 10) {
                Text("30-day summary")
                    .font(.headline)
                HStack(spacing: 20) {
                    StatBox(label: "Current",
                            value: "\(last.weightLbs.formatted(.number.precision(.fractionLength(1)))) lbs")
                    StatBox(label: "30-day change",
                            value: deltaText(delta),
                            color: deltaColor(delta))
                    StatBox(label: "Entries",
                            value: "\(entries.count)")
                }
            }
            .padding(18)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func deltaText(_ delta: Double) -> String {
        let sign = delta >= 0 ? "+" : ""
        return "\(sign)\(delta.formatted(.number.precision(.fractionLength(1)))) lbs"
    }

    private func deltaColor(_ delta: Double) -> Color {
        delta < 0 ? PlateStyle.green : (delta > 0 ? .orange : .secondary)
    }
}

private struct StatBox: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
