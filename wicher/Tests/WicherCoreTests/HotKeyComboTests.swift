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

    func testAnyModifiedChordIsAllowed() {
        XCTAssertNil(combo(kVK_Tab, cmdKey).problem(amongOthers: []), "⌘Tab")
        XCTAssertNil(combo(kVK_Tab, optionKey | shiftKey).problem(amongOthers: []), "Shift is allowed now")
        XCTAssertNil(combo(kVK_Space, controlKey).problem(amongOthers: []))
    }

    func testBareFunctionKeysAllowedBareTypingKeysNot() {
        XCTAssertNil(combo(kVK_F13, 0).problem(amongOthers: []))
        XCTAssertNil(combo(kVK_F5, shiftKey).problem(amongOthers: []))
        XCTAssertNotNil(combo(kVK_Tab, 0).problem(amongOthers: []))
        XCTAssertNotNil(combo(kVK_ANSI_A, shiftKey).problem(amongOthers: []), "⇧A is just typing")
        XCTAssertNotNil(combo(kVK_LeftArrow, 0).problem(amongOthers: []))
    }

    func testCollisionsWithOtherSwitchersAreRejected() {
        let others = [combo(kVK_Tab, optionKey)]
        XCTAssertNotNil(combo(kVK_Tab, optionKey).problem(amongOthers: others))
        XCTAssertNotNil(combo(kVK_Tab, optionKey | shiftKey).problem(amongOthers: others), "another's reverse")
        // An existing ⌥⇧Tab switcher collides with ⌥Tab's reverse.
        XCTAssertNotNil(combo(kVK_Tab, optionKey).problem(amongOthers: [combo(kVK_Tab, optionKey | shiftKey)]))
        XCTAssertNil(combo(kVK_Tab, controlKey).problem(amongOthers: others))
    }
}

final class SystemHotKeysTests: XCTestCase {
    private let cmdTab = HotKeyCombo(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(cmdKey))

    func testBindingMatchesOnKeyAndChordModifiers() {
        // As measured: ⌘Tab is id 1, keycode 48, modifiers 0x100000.
        let system = SystemHotKeys.Binding(id: 1, keyCode: 48, modifiers: 0x100000)
        XCTAssertTrue(SystemHotKeys.binding(system, matches: cmdTab))
        XCTAssertFalse(SystemHotKeys.binding(system, matches: cmdTab.reverse!))
        let reverse = SystemHotKeys.Binding(id: 2, keyCode: 48, modifiers: 0x120000)
        XCTAssertTrue(SystemHotKeys.binding(reverse, matches: cmdTab.reverse!))
    }

    func testFnFlagIsIgnored() {
        let withFn = SystemHotKeys.Binding(id: 9, keyCode: 48, modifiers: 0x100000 | 0x800000)
        XCTAssertTrue(SystemHotKeys.binding(withFn, matches: cmdTab))
    }

    func testDifferentKeyDoesNotMatch() {
        let grave = SystemHotKeys.Binding(id: 27, keyCode: 50, modifiers: 0x100000)
        XCTAssertFalse(SystemHotKeys.binding(grave, matches: cmdTab))
    }

    func testCommandTabIsAKnownSystemShortcutHere() throws {
        // Read-only: on a Mac with the private API, ⌘Tab maps to id 1 (enabled
        // unless wicher, or something else, has switched it off).
        try XCTSkipUnless(SystemHotKeys.isAvailable)
        let binding = try XCTUnwrap(SystemHotKeys.binding(for: 1))
        XCTAssertTrue(SystemHotKeys.binding(binding, matches: cmdTab))
    }
}

final class KeyNameTests: XCTestCase {
    func testNames() {
        XCTAssertEqual(KeyCodeNames.name(for: UInt32(kVK_Tab)), "Tab")
        XCTAssertEqual(KeyCodeNames.name(for: UInt32(kVK_F13)), "F13")
        XCTAssertEqual(KeyCodeNames.name(for: UInt32(kVK_UpArrow)), "↑")
        XCTAssertEqual(HotKeyCombo(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(cmdKey | shiftKey)).displayString, "⇧⌘Tab")
    }

    func testModifierFlagsInitAndGlyphs() {
        let combo = HotKeyCombo(keyCode: 48, modifierFlags: [.command, .option])
        XCTAssertEqual(combo.carbonModifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(HotKeyCombo.modifierGlyphs([.command, .control, .shift]), "⌃⇧⌘")
    }
}
