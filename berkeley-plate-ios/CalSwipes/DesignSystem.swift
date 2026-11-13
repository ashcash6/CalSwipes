import SwiftUI

// MARK: - Hex color convenience (light-mode fixed colors)

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

private extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255
        let g = CGFloat((int >> 8)  & 0xFF) / 255
        let b = CGFloat( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - CalSwipes Design Tokens (accessibility-first palette)
//
// Every color is (light, dark) and resolves at render time. With Increase Contrast on,
// textSecondary uses textPrimary and outline uses textSecondary (spec §6).
// Contrast ratios are enforced by Tests/ContrastTests.swift.

/// Raw palette. Views use the `CP` names below, never these directly.
enum Palette {
    struct Pair { let light: String; let dark: String }
    static let bg            = Pair(light: "F4F5F7", dark: "0E1013")
    static let surface1      = Pair(light: "FFFFFF", dark: "1A1D22")
    static let surface2      = Pair(light: "EEF0F3", dark: "252931")
    static let textPrimary   = Pair(light: "15171A", dark: "ECEDEF")
    static let textSecondary = Pair(light: "545B66", dark: "A3A9B3")
    static let accent        = Pair(light: "2B66A6", dark: "7BA6D3")
    static let onAccent      = Pair(light: "FFFFFF", dark: "0E1013")
    static let macroProtein  = Pair(light: "0067A3", dark: "56B4E9")
    static let macroCarbs    = Pair(light: "A35F00", dark: "E69F00")
    static let macroFat      = Pair(light: "A8457F", dark: "CC79A7")
    static let track         = Pair(light: "D9DCE1", dark: "3A404B")
    static let outline       = Pair(light: "7E8591", dark: "6A717D")
    static let separator     = Pair(light: "E3E5E9", dark: "2C3038")
    static let destructive   = Pair(light: "A34A00", dark: "F2A65A")

    static func uiColor(_ pair: Pair, highContrast: Pair? = nil) -> UIColor {
        UIColor { traits in
            let p = (traits.accessibilityContrast == .high ? highContrast : nil) ?? pair
            return UIColor(hex: traits.userInterfaceStyle == .dark ? p.dark : p.light)
        }
    }
}

enum CP {

    // MARK: Colors (spec §2.1)

    static let bg            = Color(uiColor: Palette.uiColor(Palette.bg))
    static let surface1      = Color(uiColor: Palette.uiColor(Palette.surface1))
    static let surface2      = Color(uiColor: Palette.uiColor(Palette.surface2))
    static let textPrimary   = Color(uiColor: Palette.uiColor(Palette.textPrimary))
    static let textSecondary = Color(uiColor: Palette.uiColor(Palette.textSecondary, highContrast: Palette.textPrimary))
    static let accent        = Color(uiColor: Palette.uiColor(Palette.accent))
    static let onAccent      = Color(uiColor: Palette.uiColor(Palette.onAccent))
    static let macroProtein  = Color(uiColor: Palette.uiColor(Palette.macroProtein))
    static let macroCarbs    = Color(uiColor: Palette.uiColor(Palette.macroCarbs))
    static let macroFat      = Color(uiColor: Palette.uiColor(Palette.macroFat))
    static let track         = Color(uiColor: Palette.uiColor(Palette.track))
    static let outline       = Color(uiColor: Palette.uiColor(Palette.outline, highContrast: Palette.textSecondary))
    static let separator     = Color(uiColor: Palette.uiColor(Palette.separator))
    static let destructive   = Color(uiColor: Palette.uiColor(Palette.destructive))

    // MARK: Legacy names (existing views). Mapped onto the new palette so the
    // whole app re-themes without layout changes. Phase 3+ migrates call sites.

    static var surface: Color { surface1 }
    static var border: Color  { separator }
    static var text: Color    { textPrimary }
    static var textSec: Color { textSecondary }
    static var navy: Color    { accent }
    static var protein: Color { macroProtein }
    static var carbs: Color   { macroCarbs }
    static var fat: Color     { macroFat }

    // MARK: Spacing scale (4-pt grid)

    static let sp4:  CGFloat = 4
    static let sp8:  CGFloat = 8
    static let sp10: CGFloat = 10
    static let sp12: CGFloat = 12
    static let sp14: CGFloat = 14
    static let sp16: CGFloat = 16
    static let sp20: CGFloat = 20
    static let sp24: CGFloat = 24
    static let sp32: CGFloat = 32
    static let sp40: CGFloat = 40
    static let sp48: CGFloat = 48

    // MARK: Corner radii

    static let r8:  CGFloat = 8
    static let r12: CGFloat = 12
    static let r14: CGFloat = 14
    static let r16: CGFloat = 16
    static let r20: CGFloat = 20

    // MARK: Shadow

    static let shadowOpacity: Double = 0.06
    static let shadowRadius:  CGFloat = 10
    static let shadowY:       CGFloat = 2

    // MARK: Macro role color

    static func roleColor(_ role: FoodRole) -> Color {
        switch role {
        case .protein: return protein
        case .carb:    return carbs
        case .produce: return fat
        case .fat:     return fat
        case .other:   return .secondary
        }
    }
}

// MARK: - Card modifier

struct CPCardModifier: ViewModifier {
    var padding: CGFloat = CP.sp16
    var radius: CGFloat  = CP.r16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(CP.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shadow(color: .black.opacity(CP.shadowOpacity), radius: CP.shadowRadius, x: 0, y: CP.shadowY)
    }
}

extension View {
    func cpCard(_ padding: CGFloat = CP.sp16, radius: CGFloat = CP.r16) -> some View {
        modifier(CPCardModifier(padding: padding, radius: radius))
    }
}

// MARK: - Press feedback button style (used by all CP buttons)

struct CPPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// Row-style button: background highlight only, no movement — matches standard iOS list row feel.
struct CPRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.gray.opacity(0.12) : Color.clear)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

// MARK: - Primary button

struct CPPrimaryButton: View {
    let title: String
    var icon: String?    = nil
    var isLoading: Bool  = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: CP.sp8) {
                if isLoading {
                    ProgressView().tint(CP.onAccent).scaleEffect(0.85)
                } else {
                    if let icon { Image(systemName: icon).font(.subheadline.weight(.medium)) }
                    Text(title).fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(isDisabled ? CP.track : CP.accent)
            .foregroundStyle(isDisabled ? CP.textSecondary : CP.onAccent)
            .clipShape(RoundedRectangle(cornerRadius: CP.r12))
        }
        .buttonStyle(CPPressStyle())
        .disabled(isLoading || isDisabled)
    }
}

// MARK: - Secondary button

struct CPSecondaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: CP.sp8) {
                if let icon { Image(systemName: icon).font(.caption.weight(.medium)) }
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundStyle(Color.primary)
            .overlay(RoundedRectangle(cornerRadius: CP.r12).stroke(CP.border, lineWidth: 1))
        }
        .buttonStyle(CPPressStyle())
    }
}

// MARK: - Macro progress bar

struct CPMacroBar: View {
    let label: String
    let value: Double
    let target: Double
    let unit: String
    let color: Color

    private var fraction: Double {
        guard target > 0 else { return 0 }
        return min(1.0, value / target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CP.sp4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(Int(value)) / \(Int(target)) \(unit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.18)).frame(height: 6)
                    Capsule().fill(color)
                        .frame(width: geo.size.width * fraction, height: 6)
                        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: fraction)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Calorie progress ring

struct CPProgressRing: View {
    let consumed: Double
    let target: Double
    var size: CGFloat       = 170
    var strokeWidth: CGFloat = 14

    private var fraction: Double {
        guard target > 0 else { return 0 }
        return min(1.0, consumed / target)
    }
    private var isOver: Bool { consumed > target * 1.05 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(CP.navy.opacity(0.12), lineWidth: strokeWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    isOver ? CP.carbs : CP.navy,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: fraction)

            VStack(spacing: 2) {
                if isOver {
                    Text("+\(Int(consumed - target))")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(CP.carbs)
                    Text("over budget")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(Int(max(0, target - consumed)).formatted())
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("kcal left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Section label (uppercase tracked)

struct CPSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.8)
    }
}

// MARK: - Hair divider

struct CPDivider: View {
    var body: some View {
        Divider()
    }
}

// MARK: - Macro stat trio cell

struct CPMacroStat: View {
    let value: Double
    let unit: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text("\(Int(value))")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(color)
                Text(unit)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(color.opacity(0.8))
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
