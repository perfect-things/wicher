import AppKit
import Carbon.HIToolbox

/// A key-code + Carbon-modifier combination for a global hot key.
struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// Default trigger: Option-Tab. Chosen to avoid clashing with the system's
    /// own Command-Tab switcher, so wicher never has to intercept/replace it.
    static let defaultCombo = HotKeyCombo(keyCode: UInt32(kVK_Tab),
                                          carbonModifiers: UInt32(optionKey))

    /// Default trigger for the "current app" switcher: Option-Backtick.
    static let currentAppCombo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_Grave),
                                             carbonModifiers: UInt32(optionKey))

    /// The AppKit modifier flags equivalent (used to detect modifier release).
    var eventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    /// Combo+Shift is registered as the reverse hot key, so a combo that
    /// already contains Shift has no reverse (see `reverse`).
    var containsShift: Bool { carbonModifiers & UInt32(shiftKey) != 0 }

    /// Holds ⌘, ⌥ or ⌃. Shift alone does not count: ⇧+letter is just typing.
    var hasCommandModifier: Bool {
        !eventModifierFlags.isDisjoint(with: [.command, .option, .control])
    }

    /// Why `self` cannot be used as a switcher shortcut, or nil if it can.
    ///
    /// Almost anything goes — including chords the system owns, such as ⌘Tab
    /// (see `SystemHotKeys`). Two things do not:
    /// - A plain typing key (a letter, Tab, Space, an arrow…) without ⌘, ⌥ or
    ///   ⌃ would be swallowed system-wide, making it impossible to type.
    ///   Function keys are fine on their own.
    /// - A chord another switcher already uses, as its shortcut or its
    ///   reverse, cannot be registered twice.
    func problem(amongOthers others: [HotKeyCombo]) -> String? {
        if !hasCommandModifier && !KeyCodeNames.isFunctionKey(keyCode) { return "Add ⌘, ⌥ or ⌃" }
        let taken = others.flatMap { [$0] + ($0.reverse.map { [$0] } ?? []) }
        if taken.contains(self) || reverse.map(taken.contains) == true { return "Used by another switcher" }
        return nil
    }

    /// The reverse-cycling combo: this one plus Shift. Nil when the combo
    /// already holds Shift, since the two would be the same key chord.
    var reverse: HotKeyCombo? {
        containsShift ? nil : HotKeyCombo(keyCode: keyCode, carbonModifiers: carbonModifiers | UInt32(shiftKey))
    }

    /// Human-readable form, e.g. "⌥Tab".
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += KeyCodeNames.name(for: keyCode)
        return s
    }
}

/// Registers Carbon global hot keys and dispatches presses to Swift closures.
///
/// `RegisterEventHotKey` is the same public mechanism Contexts links (observed),
/// but wicher uses it only to *summon/advance* the switcher — not to swallow
/// the system Command-Tab, which would require an always-on event tap.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var actions: [UInt32: (Bool) -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var combos: [UInt32: HotKeyCombo] = [:]
    /// While suspended (a shortcut is being recorded), registrations are kept
    /// but not live, so pressing an existing shortcut reaches the recorder.
    private(set) var isSuspended = false
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?

    private init() { installHandler() }

    deinit {
        refs.values.forEach { UnregisterEventHotKey($0) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private func installHandler() {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyReleased)),
        ]
        // `userData` carries `self` (unretained: the handler is removed in
        // `deinit`, before `self` goes away) rather than reaching for `shared`.
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           OSType(kEventParamDirectObject),
                                           OSType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hkID)
            if status == noErr {
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                center.actions[hkID.id]?(pressed)
            }
            return noErr
        }, 2, &specs, userData, &handlerRef)
    }

    /// Registers a combo. The handler is called with `true` on press and
    /// `false` on release. Returns an opaque id (nil if the OS rejected it).
    @discardableResult
    func register(_ combo: HotKeyCombo, handler: @escaping (Bool) -> Void) -> UInt32? {
        let id = nextID
        nextID += 1
        if !isSuspended {
            guard let ref = registerCarbon(combo, id: id) else { return nil }
            refs[id] = ref
        }
        actions[id] = handler
        combos[id] = combo
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs[id] { UnregisterEventHotKey(ref) }
        refs[id] = nil
        actions[id] = nil
        combos[id] = nil
    }

    /// Takes every hot key off the system without forgetting it.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    /// Puts every hot key back after `suspend()`.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        for (id, combo) in combos {
            refs[id] = registerCarbon(combo, id: id)
        }
    }

    private func registerCarbon(_ combo: HotKeyCombo, id: UInt32) -> EventHotKeyRef? {
        let hkID = EventHotKeyID(signature: OSType(0x57494348 /* 'WICH' */), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode,
                                         combo.carbonModifiers,
                                         hkID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else {
            NSLog("wicher: RegisterEventHotKey(%@) failed: %d", combo.displayString, status)
            return nil
        }
        return ref
    }
}

/// Key-code → label map for the shortcut display/recorder.
enum KeyCodeNames {
    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// Named keys whose label is not the character they type.
    private static let special: [Int: String] = [
        kVK_Tab: "Tab", kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "Esc",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_ANSI_KeypadEnter: "⌤",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "Help",
        kVK_ANSI_Grave: "`",
    ]

    static func isFunctionKey(_ keyCode: UInt32) -> Bool { functionKeys[Int(keyCode)] != nil }

    static func name(for keyCode: UInt32) -> String {
        if let name = functionKeys[Int(keyCode)] ?? special[Int(keyCode)] { return name }
        if let s = Self.characterForKeyCode(keyCode), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s.uppercased()
        }
        return "Key \(keyCode)"
    }

    /// Best-effort translation of a key code to its character using the
    /// current keyboard layout.
    private static func characterForKeyCode(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = unsafeBitCast(layoutData, to: CFData.self) as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let result = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(layout,
                                  UInt16(keyCode),
                                  UInt16(kUCKeyActionDisplay),
                                  0,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState,
                                  chars.count,
                                  &length,
                                  &chars)
        }
        guard result == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
