import Carbon.HIToolbox
import XCTest
@testable import WicherCore

final class HotKeyComboTests: XCTestCase {
    func testReverseAddsShift() {
        let reverse = HotKeyCombo.defaultCombo.reverse
        XCTAssertEqual(reverse?.keyCode, HotKeyCombo.defaultCombo.keyCode)
        XCTAssertEqual(reverse?.carbonModifiers, UInt32(optionKey | shiftKey))
    }

    func testComboWithShiftHasNoReverse() {
        let combo = HotKeyCombo(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(optionKey | shiftKey))
        XCTAssertTrue(combo.containsShift)
        XCTAssertNil(combo.reverse)
    }
}
