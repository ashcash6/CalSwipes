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

// MARK: - CalPlate Design Tokens

enum CP {

    // MARK: Backgrounds — adaptive light/dark

    /// Warm off-white in light mode, system grouped dark in dark mode
    static let bg = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemGroupedBackground
            : UIColor(hex: "F8F8F5")
    })

    /// Elevated card surface
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .secondarySystemGroupedBackground
            : .white
    })

    /// Secondary surface (inset cards, option backgrounds)
    static let surface2 = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .tertiarySystemGroupedBackground
            : UIColor(hex: "F1F2F0")
    })

    /// Divider / border line
    static let border = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.separator
            : UIColor(hex: "DDE1E5")
    })

    // MARK: Text — fully adaptive so contrast is always guaranteed

    /// Primary text — adapts to light/dark automatically
    static let text: Color    = .primary
    /// Secondary / label text
    static let textSec: Color = .secondary

    // MARK: Brand accent — adaptive so it reads on both light and dark surfaces

    /// Brand navy: deep #12315B in light mode, cornflower-blue in dark mode
    static let navy = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(hex: "6EA8D8")   // readable on dark backgrounds
            : UIColor(hex: "12315B")   // rich dark navy on light backgrounds
    })

    // MARK: Macro colours — fixed accent, light-safe

    /// Protein — muted rose      #D9828B
    static let protein  = Color(hex: "D9828B")
    /// Carbohydrates — muted amber  #D99A4A
    static let carbs    = Color(hex: "D99A4A")
    /// Fat — muted teal          #6E9B9A
    static let fat      = Color(hex: "6E9B9A")

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
                    ProgressView().tint(.white).scaleEffect(0.85)
                } else {
                    if let icon { Image(systemName: icon).font(.subheadline.weight(.medium)) }
                    Text(title).fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(isDisabled ? CP.navy.opacity(0.35) : CP.navy)
            .foregroundStyle(.white)
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
