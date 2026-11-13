import XCTest
@testable import CalSwipes

/// Spec §2.1: every text/background pair must be >= 4.5:1, meaningful non-text UI >= 3:1,
/// in both light and dark mode. Computed from the raw Palette hex values (WCAG 2.x formula).
final class ContrastTests: XCTestCase {

    private func luminance(_ hex: String) -> Double {
        let v = Int(hex, radix: 16)!
        let rgb = [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF].map { Double($0) / 255 }
        let lin = rgb.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    }

    private func ratio(_ a: String, _ b: String) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private typealias P = Palette

    private let textPairs: [(String, Palette.Pair, Palette.Pair)] = [
        ("textPrimary/surface1", P.textPrimary, P.surface1),
        ("textPrimary/bg", P.textPrimary, P.bg),
        ("textPrimary/surface2", P.textPrimary, P.surface2),
        ("textSecondary/surface1", P.textSecondary, P.surface1),
        ("textSecondary/bg", P.textSecondary, P.bg),
        ("textSecondary/surface2", P.textSecondary, P.surface2),
        ("onAccent/accent", P.onAccent, P.accent),
        ("accent/surface1", P.accent, P.surface1),
        ("accent/bg", P.accent, P.bg),
        ("macroProtein/surface1", P.macroProtein, P.surface1),
        ("macroCarbs/surface1", P.macroCarbs, P.surface1),
        ("macroFat/surface1", P.macroFat, P.surface1),
        ("destructive/surface1", P.destructive, P.surface1),
    ]

    private let uiPairs: [(String, Palette.Pair, Palette.Pair)] = [
        ("outline/surface1", P.outline, P.surface1),
        ("outline/bg", P.outline, P.bg),
    ]

    func testTextContrastAtLeast4_5() {
        for (name, fg, bg) in textPairs {
            XCTAssertGreaterThanOrEqual(ratio(fg.light, bg.light), 4.5, "\(name) light")
            XCTAssertGreaterThanOrEqual(ratio(fg.dark, bg.dark), 4.5, "\(name) dark")
        }
    }

    func testNonTextContrastAtLeast3() {
        for (name, fg, bg) in uiPairs {
            XCTAssertGreaterThanOrEqual(ratio(fg.light, bg.light), 3, "\(name) light")
            XCTAssertGreaterThanOrEqual(ratio(fg.dark, bg.dark), 3, "\(name) dark")
        }
    }

    func testNoPureBlackBackgroundOrPureWhiteDarkText() {
        XCTAssertNotEqual(P.bg.dark, "000000")
        XCTAssertNotEqual(P.textPrimary.dark, "FFFFFF")
    }
}
