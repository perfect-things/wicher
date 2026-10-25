import AppKit
import Carbon.HIToolbox
import XCTest
@testable import WicherCore

final class SwitcherCommandTests: XCTestCase {
    private func command(_ keyCode: Int, _ mods: NSEvent.ModifierFlags = [],
                         trigger: NSEvent.ModifierFlags = .option, chars: String? = nil) -> SwitcherCommand? {
        SwitcherCommand.from(keyCode: keyCode, modifiers: mods, trigger: trigger, chars: chars)
    }

    func testNavigationKeys() {
        XCTAssertEqual(command(kVK_Escape), .cancelOrClear)
        XCTAssertEqual(command(kVK_Return), .commit)
        XCTAssertEqual(command(kVK_ANSI_KeypadEnter), .commit)
        XCTAssertEqual(command(kVK_Tab), .advance(1))
        XCTAssertEqual(command(kVK_Tab, .shift), .advance(-1))
        XCTAssertEqual(command(kVK_RightArrow), .advance(1))
        XCTAssertEqual(command(kVK_LeftArrow), .advance(-1))
        XCTAssertEqual(command(kVK_DownArrow), .moveRows(1))
        XCTAssertEqual(command(kVK_UpArrow), .moveRows(-1))
        XCTAssertEqual(command(kVK_Delete), .deleteBackward)
    }

    func testTriggerModifiersAreSubtractedSoCommandHeldTypingSearches() {
        XCTAssertEqual(command(kVK_ANSI_A, .command, trigger: .command, chars: "a"), .type("a"))
        XCTAssertNil(command(kVK_ANSI_A, .command, trigger: .option, chars: "a"), "⌘A with ⌥Tab is not typing")
    }

    func testShiftInTheTriggerDoesNotReverseTab() {
        XCTAssertEqual(command(kVK_Tab, [.option, .shift], trigger: [.option, .shift]), .advance(1))
    }

    func testCommandCommaOpensSettingsEvenWhenCommandIsTheTrigger() {
        XCTAssertEqual(command(kVK_ANSI_Comma, .command, trigger: .command, chars: ","), .openSettings)
        XCTAssertEqual(command(kVK_ANSI_Comma, .command, chars: ","), .openSettings)
        XCTAssertEqual(command(kVK_ANSI_Comma, chars: ","), .type(","))
    }

    func testControlCharactersAndChordsAreIgnored() {
        XCTAssertNil(command(kVK_ANSI_A, .control, chars: "a"))
        XCTAssertNil(command(kVK_ANSI_A, chars: "\u{7F}"))
        XCTAssertNil(command(kVK_ANSI_A, chars: "\u{01}"))
        XCTAssertNil(command(kVK_ANSI_A, chars: nil))
        XCTAssertNil(command(kVK_ANSI_A, chars: "ab"))
    }

    /// F-keys, Home/End, ⌦ etc. arrive as AppKit's private-use characters.
    func testFunctionKeyCharactersAreNotTyped() {
        func key(_ code: Int) -> String { String(UnicodeScalar(code)!) }
        XCTAssertNil(command(kVK_F1, chars: key(NSF1FunctionKey)))
        XCTAssertNil(command(kVK_F19, chars: key(NSF19FunctionKey)))
        XCTAssertNil(command(kVK_Home, chars: key(NSHomeFunctionKey)))
        XCTAssertNil(command(kVK_End, chars: key(NSEndFunctionKey)))
        XCTAssertNil(command(kVK_ForwardDelete, chars: key(NSDeleteFunctionKey)))
        XCTAssertNil(command(kVK_PageUp, chars: key(NSPageUpFunctionKey)))
        XCTAssertNil(command(0, chars: "\u{F8FF}"))
        XCTAssertEqual(command(0, chars: "\u{F6FF}"), .type("\u{F6FF}"))
        XCTAssertEqual(command(0, chars: "\u{F900}"), .type("\u{F900}"))
    }

    func testDeviceDependentBitsAreIgnored() {
        let raw = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
        XCTAssertEqual(command(kVK_ANSI_X, raw, chars: "x"), .type("x"))
    }
}
