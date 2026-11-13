import SwiftUI
import UIKit

// Shared pieces for the accessibility-first redesign: progress strip, Log sheet,
// undo snackbar, week circles, macro rows. Colors come only from CP tokens.

// MARK: - Haptics

enum Haptics {
    static func logged() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Number formatting

enum Fmt {
    static func int(_ v: Double) -> String { Int(v.rounded()).formatted() }
}

// MARK: - Progress strip (spec §4)

/// One-line summary: "1,835 kcal left  P 0/152  C 0/206  F 0/61". Tap goes to Today.
struct ProgressStrip: View {
    var daily: DailyStore
    var onTap: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: onTap) {
            Group {
                if let goal = daily.goal {
                    let left = goal.targetCalories - daily.todayCalories
                    let layout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: CP.sp4))
                        : AnyLayout(HStackLayout(spacing: CP.sp12))
                    layout {
                        Text(left >= 0 ? "\(Fmt.int(left)) kcal left" : "\(Fmt.int(-left)) kcal over")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CP.textPrimary)
                        HStack(spacing: CP.sp12) {
                            mini("P", daily.todayProtein, goal.targetProteinG, CP.macroProtein)
                            mini("C", daily.todayCarbs, goal.targetCarbsG, CP.macroCarbs)
                            mini("F", daily.todayFat, goal.targetFatG, CP.macroFat)
                        }
                    }
                } else {
                    Text("\(Fmt.int(daily.todayCalories)) kcal today · Set a goal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CP.textPrimary)
                }
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, CP.sp12)
            .background(CP.surface1, in: RoundedRectangle(cornerRadius: CP.r12))
            .overlay(RoundedRectangle(cornerRadius: CP.r12).stroke(CP.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOver)
        .accessibilityHint("Opens Today")
        .accessibilityAddTraits(.isButton)
    }

    private func mini(_ letter: String, _ cur: Double, _ target: Double, _ color: Color) -> some View {
        HStack(spacing: CP.sp4) {
            Text(letter).font(.footnote.weight(.bold)).foregroundStyle(color)
            Capsule().fill(color).frame(width: 3, height: 12).accessibilityHidden(true)
            Text("\(Fmt.int(cur))/\(Fmt.int(target))").font(.footnote).foregroundStyle(CP.textPrimary)
        }
        .fixedSize()
    }

    private var voiceOver: String {
        guard let goal = daily.goal else {
            return "\(Fmt.int(daily.todayCalories)) calories today. Set a goal."
        }
        let left = goal.targetCalories - daily.todayCalories
        let head = left >= 0 ? "\(Fmt.int(left)) calories left." : "\(Fmt.int(-left)) calories over."
        return head
            + " Protein \(Fmt.int(daily.todayProtein)) of \(Fmt.int(goal.targetProteinG)) grams."
            + " Carbs \(Fmt.int(daily.todayCarbs)) of \(Fmt.int(goal.targetCarbsG)) grams."
            + " Fat \(Fmt.int(daily.todayFat)) of \(Fmt.int(goal.targetFatG)) grams."
    }
}

// MARK: - Log sheet (spec §3)

enum LogRoute: String, Identifiable {
    case tray, label, manual, ai
    var id: String { rawValue }
}

struct LogSheet: View {
    var assistantAvailable: Bool
    var onPick: (LogRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: CP.sp16) {
            Text("Log a meal")
                .font(.title2.weight(.semibold))
                .foregroundStyle(CP.textPrimary)
                .accessibilityAddTraits(.isHeader)

            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: CP.sp8))
                : AnyLayout(HStackLayout(spacing: CP.sp8))
            layout {
                if assistantAvailable {
                    tile("Scan tray", "camera.viewfinder", .tray)
                }
                tile("Scan label", "barcode.viewfinder", .label)
                tile("Type it", "square.and.pencil", .manual)
            }

            if assistantAvailable {
                Button { pick(.ai) } label: {
                    HStack(spacing: CP.sp12) {
                        Image(systemName: "sparkles").font(.body.weight(.semibold))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ask the AI").font(.headline)
                            Text("Menu questions, meal ideas, tray scans").font(.footnote)
                                .foregroundStyle(CP.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(CP.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(CP.textPrimary)
                    .padding(CP.sp16)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(CP.surface2, in: RoundedRectangle(cornerRadius: CP.r16))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
        .padding(CP.sp20)
        .background(CP.bg)
    }

    private func tile(_ title: String, _ icon: String, _ route: LogRoute) -> some View {
        Button { pick(route) } label: {
            VStack(spacing: CP.sp8) {
                Image(systemName: icon).font(.title2).foregroundStyle(CP.accent)
                    .accessibilityHidden(true)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(CP.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(CP.surface2, in: RoundedRectangle(cornerRadius: CP.r16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func pick(_ route: LogRoute) {
        onPick(route)
        dismiss()
    }
}

/// Raised center "+" button drawn over the tab bar. The real tab underneath carries the
/// "Log" label and the VoiceOver element, so this one is hidden from accessibility.
struct RaisedLogButton: View {
    var action: () -> Void
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 56

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.bold))
                .foregroundStyle(CP.onAccent)
                .frame(width: size, height: size)
                .background(CP.accent, in: Circle())
                .overlay(Circle().stroke(CP.bg, lineWidth: 4))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}

struct LogHintBubble: View {
    var onDismiss: () -> Void
    var body: some View {
        Button(action: onDismiss) {
            Text("Tap + to log a meal.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(CP.onAccent)
                .padding(.horizontal, CP.sp16)
                .padding(.vertical, CP.sp12)
                .background(CP.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tip: tap Log to log a meal. Dismiss.")
    }
}

// MARK: - Undo snackbar (spec §5.1)

struct UndoSnackbar: View {
    let text: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: CP.sp12) {
            Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
            Text(text).font(.subheadline.weight(.medium)).lineLimit(2)
            Spacer(minLength: CP.sp8)
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.bold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .foregroundStyle(CP.onAccent)
        .padding(.horizontal, CP.sp16)
        .background(CP.accent, in: RoundedRectangle(cornerRadius: CP.r12))
        .padding(.horizontal, CP.sp16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Macro row (Today card)

struct MacroRow: View {
    let name: String
    let current: Double
    let target: Double
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: CP.sp4) {
            HStack {
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                Spacer()
                Text("\(Fmt.int(current)) / \(Fmt.int(target)) g")
                    .font(.subheadline).foregroundStyle(CP.textPrimary).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(CP.track)
                    Capsule().fill(color)
                        .frame(width: geo.size.width * min(1, target > 0 ? current / target : 0))
                }
            }
            .frame(height: 6)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: current)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(Fmt.int(current)) of \(Fmt.int(target)) grams")
    }
}

// MARK: - Week circles (inside the Today card)

struct WeekCircles: View {
    var daily: DailyStore
    @ScaledMetric(relativeTo: .body) private var circle: CGFloat = 32

    private struct Day: Identifiable {
        let id: Int, letter: String, name: String, isToday: Bool, isFuture: Bool, kcal: Double
    }

    private var days: [Day] {
        let cal = BerkeleyClock.calendar
        let now = Date()
        let today = BerkeleyClock.serviceDate()
        let weekday = cal.component(.weekday, from: now)
        let back = weekday == 1 ? 6 : weekday - 2
        guard let monday = cal.date(byAdding: .day, value: -back, to: now) else { return [] }
        let letters = ["M", "T", "W", "T", "F", "S", "S"]
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i, to: monday) ?? monday
            let ds = BerkeleyClock.serviceDate(d)
            let future = ds > today
            return Day(id: i, letter: letters[i], name: names[i], isToday: ds == today,
                       isFuture: future, kcal: future ? 0 : daily.caloriesForDate(ds))
        }
    }

    var body: some View {
        let week = days
        VStack(alignment: .leading, spacing: CP.sp8) {
            Text("This week: \(Fmt.int(week.reduce(0) { $0 + $1.kcal })) kcal")
                .font(.footnote).foregroundStyle(CP.textSecondary).monospacedDigit()
            HStack(spacing: 0) {
                ForEach(week) { d in
                    VStack(spacing: CP.sp4) {
                        ZStack {
                            if d.kcal > 0 {
                                Circle().fill(CP.accent)
                            } else {
                                Circle().stroke(CP.outline, lineWidth: 1.5)
                            }
                            if d.isToday {
                                Circle().stroke(CP.textPrimary, lineWidth: 2).padding(-4)
                            }
                        }
                        .frame(width: circle, height: circle)
                        Text(d.letter)
                            .font(d.isToday ? .footnote.weight(.bold) : .footnote)
                            .foregroundStyle(d.isToday ? CP.textPrimary : CP.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(d.isFuture ? "\(d.name), upcoming"
                        : "\(d.name)\(d.isToday ? ", today" : ""), \(Fmt.int(d.kcal)) calories logged")
                }
            }
        }
    }
}

// MARK: - "New" capsule (replaces color-only red dots)

struct NewCapsule: View {
    var body: some View {
        Text("1")
            .font(.caption.weight(.bold))
            .foregroundStyle(CP.onAccent)
            .padding(.horizontal, CP.sp8)
            .padding(.vertical, 2)
            .background(CP.accent, in: Capsule())
    }
}

// MARK: - Today hero card (spec §5.2)

struct TodayHeroCard: View {
    var daily: DailyStore
    var goal: UserGoal
    var onHistory: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var ring: CGFloat = 112
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var eaten: Double { daily.todayCalories }
    private var target: Double { goal.targetCalories }
    private var left: Double { target - eaten }

    var body: some View {
        VStack(alignment: .leading, spacing: CP.sp16) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: CP.sp16))
                : AnyLayout(HStackLayout(spacing: CP.sp20))
            layout {
                VStack(alignment: .leading, spacing: CP.sp4) {
                    Text(Fmt.int(abs(left)))
                        .font(.system(.largeTitle, design: .serif).weight(.semibold))
                        .foregroundStyle(CP.textPrimary)
                        .monospacedDigit()
                    Text(left >= 0 ? "kcal left" : "kcal over your goal")
                        .font(.subheadline)
                        .foregroundStyle(CP.textSecondary)
                    Text("\(Fmt.int(eaten)) of \(Fmt.int(target)) eaten")
                        .font(.footnote)
                        .foregroundStyle(CP.textSecondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                Button(action: onHistory) {
                    ZStack {
                        Circle().stroke(CP.track, lineWidth: 10)
                        Circle()
                            .trim(from: 0, to: min(1, target > 0 ? eaten / target : 0))
                            .stroke(CP.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: eaten)
                    }
                    .frame(width: ring, height: ring)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Calories, \(Fmt.int(eaten)) of \(Fmt.int(target)) eaten, "
                    + (left >= 0 ? "\(Fmt.int(left)) left" : "\(Fmt.int(-left)) over"))
                .accessibilityHint("Opens calorie history")
            }
            .accessibilityElement(children: .contain)

            VStack(spacing: CP.sp12) {
                MacroRow(name: "Protein", current: daily.todayProtein, target: goal.targetProteinG, color: CP.macroProtein)
                MacroRow(name: "Carbs", current: daily.todayCarbs, target: goal.targetCarbsG, color: CP.macroCarbs)
                MacroRow(name: "Fat", current: daily.todayFat, target: goal.targetFatG, color: CP.macroFat)
            }

            Button("View calorie history", action: onHistory)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CP.accent)
                .frame(minHeight: 44)

            Divider().overlay(CP.separator)
            WeekCircles(daily: daily)
        }
        .padding(CP.sp16)
        .background(CP.surface1, in: RoundedRectangle(cornerRadius: CP.r16))
    }
}


// MARK: - Tap outside a text field closes the keyboard (app-wide)

/// Adds one window-level tap recognizer that ends editing when you tap anything that isn't a
/// text field. It doesn't cancel touches, so buttons, rows and lists keep working normally.
enum TapOutsideToDismissKeyboard {
    private final class Delegate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var v: UIView? = touch.view
            while let view = v {
                if view is UITextField || view is UITextView { return false }
                v = view.superview
            }
            return true
        }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
    private static let delegate = Delegate()
    private static var installed = false

    static func install() {
        guard !installed,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)
        else { return }
        let tap = UITapGestureRecognizer(target: window, action: #selector(UIView.endEditing(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = delegate
        window.addGestureRecognizer(tap)
        installed = true
    }
}
