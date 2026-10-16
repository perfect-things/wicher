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

final class HotKeyComboProblemTests: XCTestCase {
    private func combo(_ key: Int, _ mods: Int) -> HotKeyCombo {
        HotKeyCombo(keyCode: UInt32(key), carbonModifiers: UInt32(mods))
    }

    func testValidShortcut() {
        XCTAssertNil(combo(kVK_Tab, optionKey).problem(amongOthers: [combo(kVK_ANSI_Grave, optionKey)]))
        XCTAssertNil(combo(kVK_Tab, cmdKey | controlKey).problem(amongOthers: []))
    }

    func testShiftAndBareKeysAreRejected() {
        XCTAssertNotNil(combo(kVK_Tab, optionKey | shiftKey).problem(amongOthers: []))
        XCTAssertNotNil(combo(kVK_Tab, 0).problem(amongOthers: []))
    }

    func testCollisionsWithOtherSwitchersAreRejected() {
        let others = [combo(kVK_Tab, optionKey)]
        XCTAssertNotNil(combo(kVK_Tab, optionKey).problem(amongOthers: others))
        // An old profile saved as ⌥⇧Tab would collide with ⌥Tab's reverse.
        XCTAssertNotNil(combo(kVK_Tab, optionKey).problem(amongOthers: [combo(kVK_Tab, optionKey | shiftKey)]))
        XCTAssertNil(combo(kVK_Tab, controlKey).problem(amongOthers: others))
    }
}
