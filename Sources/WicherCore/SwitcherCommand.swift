import AppKit
import Carbon.HIToolbox

/// What a key press in the open panel means. Pure: `SwitcherController`
/// reads the event and acts on the result.
enum SwitcherCommand: Equatable {
    case commit
    /// Esc: clears a non-empty search, else closes the panel.
    case cancelOrClear
    /// Tab/Right/Left: through the rows in order.
    case advance(Int)
    /// Up/Down: to the other row of the Icons layout (elsewhere like `advance`).
    case moveRows(Int)
    case deleteBackward
    case type(Character)
    case openSettings

    /// - Parameters:
    ///   - modifiers: the event's modifier flags.
    ///   - trigger: the switcher shortcut's modifiers, held to keep the panel
    ///     open — they are subtracted, so ⌘-held typing searches when the
    ///     shortcut is ⌘Tab, and ⇧ in the shortcut doesn't reverse Tab.
    ///   - chars: `charactersIgnoringModifiers`.
    static func from(keyCode: Int,
                     modifiers: NSEvent.ModifierFlags,
                     trigger: NSEvent.ModifierFlags,
                     chars: String?) -> SwitcherCommand? {
        // Checked before the trigger is subtracted, so with a ⌘Tab shortcut
        // (⌘ already held) a bare "," does it.
        if modifiers.contains(.command), chars == "," { return .openSettings }
        let mods = modifiers.intersection(.deviceIndependentFlagsMask).subtracting(trigger)
        switch keyCode {
        case kVK_Escape: return .cancelOrClear
        case kVK_Return, kVK_ANSI_KeypadEnter: return .commit
        case kVK_Tab: return .advance(mods.contains(.shift) ? -1 : 1)
        case kVK_RightArrow: return .advance(1)
        case kVK_LeftArrow: return .advance(-1)
        case kVK_DownArrow: return .moveRows(1)
        case kVK_UpArrow: return .moveRows(-1)
        case kVK_Delete: return .deleteBackward
        default:
            guard !mods.contains(.command), !mods.contains(.control),
                  let chars, chars.count == 1,
                  let scalar = chars.unicodeScalars.first,
                  scalar.value >= 0x20, scalar.value != 0x7F,
                  // AppKit's function-key range: F-keys, Home/End, ⌦…
                  !(0xF700...0xF8FF).contains(scalar.value)
            else { return nil }
            return .type(Character(scalar))
        }
    }
}
