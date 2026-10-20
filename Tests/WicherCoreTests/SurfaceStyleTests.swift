import AppKit
import XCTest
@testable import WicherCore

final class SurfaceStyleTests: XCTestCase {
    func testZeroOpacityIsNoTint() {
        XCTAssertNil(Tint(color: .black, opacity: 0).nsColor)
        XCTAssertEqual(Tint(color: .white, opacity: 50).nsColor?.alphaComponent ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(Tint(color: .white, opacity: 250).alpha, 1, "clamped")
    }

    func testDefaultsMatchTheUnconfigurableLook() {
        XCTAssertEqual(SurfaceAppearance.defaultBackground.style, .clearGlass)
        XCTAssertEqual(SurfaceAppearance.defaultHighlight.style, .glass)
        XCTAssertEqual(SurfaceStyle.allCases, [.glass, .clearGlass, .blurred, .solid], "the picker's order")
        XCTAssertEqual(SurfaceAppearance.defaultBackground.light.opacity, 12)
        XCTAssertNil(SurfaceAppearance.defaultBackground.dark.nsColor)
        XCTAssertEqual(SurfaceAppearance.defaultHighlight.light.opacity, 16)
        XCTAssertNil(SurfaceAppearance.defaultHighlight.dark.nsColor)
    }

    func testRGBColorRoundTripsThroughNSColor() {
        let red = RGBColor(NSColor(srgbRed: 1, green: 0.25, blue: 0, alpha: 0.3))
        XCTAssertEqual(red, RGBColor(red: 1, green: 0.25, blue: 0))
    }

    func testDefaultTintsKeepTheModesOwnText() {
        for dark in [false, true] {
            let bg = SurfaceAppearance.defaultBackground.tint(dark: dark)
            let hl = SurfaceAppearance.defaultHighlight.tint(dark: dark)
            XCTAssertEqual(TextContrast.isDark([bg, hl], darkMode: dark), dark)
        }
    }

    func testStrongTintsFlipTheText() {
        let accent = Tint(color: RGBColor(red: 0, green: 0.48, blue: 1), opacity: 100)
        XCTAssertTrue(TextContrast.isDark([accent], darkMode: false), "white text on a solid accent")
        XCTAssertFalse(TextContrast.isDark([Tint(color: .white, opacity: 90)], darkMode: true))
        XCTAssertTrue(TextContrast.isDark([Tint(color: .white, opacity: 10)], darkMode: true), "a faint tint changes nothing")
        // The highlight is laid over the background.
        let black = Tint(color: .black, opacity: 100)
        let faintWhite = Tint(color: .white, opacity: 20)
        XCTAssertTrue(TextContrast.isDark([black, faintWhite], darkMode: false))
    }
}
