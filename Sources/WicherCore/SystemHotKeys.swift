import AppKit
import Darwin

/// The system's own ("symbolic") hot keys — ⌘Tab, ⌘⇧Tab, ⌘`, Spotlight,
/// Mission Control and the rest — and wicher's ability to stand in for them.
///
/// A Carbon hot key cannot take a chord the system already owns: ⌘Tab goes to
/// the Dock's app switcher before any `RegisterEventHotKey` handler sees it.
/// So when a switcher's shortcut (or its ⌘⇧ reverse) matches an enabled system
/// hot key, wicher switches that system hot key off for as long as it runs,
/// and turns it back on when the shortcut changes or wicher quits.
///
/// This uses three private CoreGraphics functions, resolved with `dlsym` like
/// `_AXUIElementGetWindow`. If they disappear, nothing is overridden and such
/// a shortcut simply does not fire — the same graceful degradation.
///
/// Measured on macOS 26: id 1 is ⌘Tab, id 2 is ⌘⇧Tab, and modifiers use the
/// `NSEvent.ModifierFlags` bit layout (⌘ = 0x100000).
enum SystemHotKeys {
    private typealias GetValueFn = @convention(c) (Int32, UnsafeMutablePointer<UInt16>,
                                                   UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias IsEnabledFn = @convention(c) (Int32) -> Bool
    private typealias SetEnabledFn = @convention(c) (Int32, Bool) -> Int32

    private static let functions: (get: GetValueFn, isEnabled: IsEnabledFn, setEnabled: SetEnabledFn)? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let get = dlsym(handle, "CGSGetSymbolicHotKeyValue"),
              let isEnabled = dlsym(handle, "CGSIsSymbolicHotKeyEnabled"),
              let setEnabled = dlsym(handle, "CGSSetSymbolicHotKeyEnabled")
        else { return nil }
        return (unsafeBitCast(get, to: GetValueFn.self),
                unsafeBitCast(isEnabled, to: IsEnabledFn.self),
                unsafeBitCast(setEnabled, to: SetEnabledFn.self))
    }()

    static var isAvailable: Bool { functions != nil }

    /// Names for the system hot keys a switcher is likely to take over.
    static let knownNames: [Int32: String] = [
        1: "the macOS app switcher (⌘Tab)",
        2: "the macOS app switcher (⌘⇧Tab)",
        27: "“Move focus to next window”",
        64: "Spotlight",
    ]

    /// Symbolic hot key ids are small integers; this covers every one in use.
    private static let idRange: Range<Int32> = 0..<512

    /// One system hot key's chord.
    struct Binding: Equatable {
        let id: Int32
        let keyCode: UInt16
        /// `NSEvent.ModifierFlags` raw value.
        let modifiers: UInt32
    }

    /// The modifier bits that make a chord distinct (⇧ ⌃ ⌥ ⌘). Others, such as
    /// the fn flag some system bindings carry, are ignored.
    private static let chordMask = NSEvent.ModifierFlags([.shift, .control, .option, .command]).rawValue

    /// Pure: does a system binding claim the same chord as `combo`?
    static func binding(_ binding: Binding, matches combo: HotKeyCombo) -> Bool {
        UInt32(binding.keyCode) == combo.keyCode
            && UInt(binding.modifiers) & chordMask == combo.eventModifierFlags.rawValue & chordMask
    }

    /// Enabled system hot keys that claim `combo`. Empty when the private API
    /// is unavailable.
    static func enabledConflicts(with combo: HotKeyCombo) -> [Int32] {
        enabledConflicts(with: [combo]).sorted()
    }

    /// Enabled system hot keys that claim any of `combos`. Reads the system
    /// table once (≈13 ms), however many combos there are.
    static func enabledConflicts(with combos: [HotKeyCombo]) -> Set<Int32> {
        guard !combos.isEmpty else { return [] }
        return Set(enabledBindings().filter { system in combos.contains { binding(system, matches: $0) } }.map(\.id))
    }

    /// Every enabled system hot key. Empty when the private API is unavailable.
    private static func enabledBindings() -> [Binding] {
        guard let functions else { return [] }
        return idRange.compactMap { id in
            var character: UInt16 = 0, keyCode: UInt16 = 0, modifiers: UInt32 = 0
            guard functions.get(id, &character, &keyCode, &modifiers) == 0, functions.isEnabled(id) else { return nil }
            return Binding(id: id, keyCode: keyCode, modifiers: modifiers)
        }
    }

    static func setEnabled(_ id: Int32, _ enabled: Bool) {
        _ = functions?.setEnabled(id, enabled)
    }

    // MARK: - Pausing every global hot key (while recording)

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SetModeFn = @convention(c) (Int32, Int32) -> Int32

    private static let operatingMode: (connection: MainConnectionFn, setMode: SetModeFn)? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let connection = dlsym(handle, "CGSMainConnectionID"),
              let setMode = dlsym(handle, "CGSSetGlobalHotKeyOperatingMode")
        else { return nil }
        return (unsafeBitCast(connection, to: MainConnectionFn.self), unsafeBitCast(setMode, to: SetModeFn.self))
    }()

    /// Pauses (or resumes) every global hot key — the system's and every
    /// app's — so the next chord is delivered as an ordinary key press.
    ///
    /// The public `PushSymbolicHotKeyMode` does this only for the system's
    /// shortcuts and only while the process is trusted for Accessibility,
    /// which an ad-hoc rebuild silently revokes; the window server then hands
    /// ⌘Tab to the Dock anyway. This private call is scoped to wicher's
    /// window-server connection, so the window server drops it if wicher dies
    /// mid-recording.
    static func setAllPaused(_ paused: Bool) {
        guard let operatingMode else { return }
        // 0 = enabled, 1 = disabled.
        _ = operatingMode.setMode(operatingMode.connection(), paused ? 1 : 0)
    }
}

/// Tracks which system hot keys wicher has switched off, so it can always
/// switch exactly those back on.
///
/// The ids are persisted as soon as they are disabled: the system remembers a
/// disabled hot key after the process is gone, so if wicher is killed without
/// a chance to clean up, the next launch re-enables them before anything else.
final class SystemHotKeyOverride {
    static let shared = SystemHotKeyOverride()

    private let defaults: UserDefaults
    private static let key = "disabledSystemHotKeys"
    private var signalSources: [DispatchSourceSignal] = []

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The system hot keys currently switched off by wicher.
    private(set) var disabled: [Int32] {
        get { (defaults.array(forKey: Self.key) as? [Int]).map { $0.map(Int32.init) } ?? [] }
        set { defaults.set(newValue.map(Int.init), forKey: Self.key) }
    }

    /// Call once at launch: undoes whatever a previous run left switched off
    /// (crash, `kill -9`) and makes sure SIGTERM/SIGINT restore before exiting.
    func recoverAndInstallSignalHandlers() {
        restoreAll()
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.restoreAll()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Switches off exactly the system hot keys that `combos` claim, and turns
    /// back on any wicher switched off before that are no longer claimed.
    func apply(for combos: [HotKeyCombo]) {
        let needed = SystemHotKeys.enabledConflicts(with: combos)
            .union(Set(disabled).filter { id in combos.contains { claims(id, $0) } })
        for id in Set(disabled).subtracting(needed) { SystemHotKeys.setEnabled(id, true) }
        // Persist first, so a crash between the two leaves a record to undo.
        disabled = needed.sorted()
        for id in needed { SystemHotKeys.setEnabled(id, false) }
    }

    /// The macOS shortcut `combo` takes over (or already has), described for
    /// the user, or nil if it does not collide with one.
    func overriddenShortcut(for combo: HotKeyCombo) -> String? {
        let ids = SystemHotKeys.enabledConflicts(with: combo) + disabled.filter { claims($0, combo) }
        guard let id = ids.min() else { return nil }
        return SystemHotKeys.knownNames[id] ?? "a macOS keyboard shortcut"
    }

    func restoreAll() {
        for id in disabled { SystemHotKeys.setEnabled(id, true) }
        disabled = []
    }

    /// Whether the (possibly already disabled) system hot key `id` claims `combo`.
    private func claims(_ id: Int32, _ combo: HotKeyCombo) -> Bool {
        SystemHotKeys.binding(for: id).map { SystemHotKeys.binding($0, matches: combo) } ?? false
    }
}

extension SystemHotKeys {
    /// The chord of system hot key `id`, enabled or not.
    static func binding(for id: Int32) -> Binding? {
        guard let functions else { return nil }
        var character: UInt16 = 0, keyCode: UInt16 = 0, modifiers: UInt32 = 0
        guard functions.get(id, &character, &keyCode, &modifiers) == 0 else { return nil }
        return Binding(id: id, keyCode: keyCode, modifiers: modifiers)
    }
}
