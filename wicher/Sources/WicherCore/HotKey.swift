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

    /// Shift is how every switcher cycles backwards (combo+Shift is registered
    /// as the reverse hot key, and Shift-Tab steps back inside the panel), so a
    /// combo that already contains Shift would collide with its own reverse.
    var containsShift: Bool { carbonModifiers & UInt32(shiftKey) != 0 }

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
        actions[id] = handler
        refs[id] = ref
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs[id] { UnregisterEventHotKey(ref) }
        refs[id] = nil
        actions[id] = nil
    }
}

/// Minimal key-code → label map for the shortcut display/recorder.
enum KeyCodeNames {
    static func name(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Esc"
        case kVK_ANSI_Grave: return "`"
        default:
            if let s = Self.characterForKeyCode(keyCode) { return s.uppercased() }
            return "Key \(keyCode)"
        }
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
