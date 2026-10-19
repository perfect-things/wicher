import AppKit
import Carbon.HIToolbox

/// Records a new shortcut for `ShortcutField`, the button that shows it.
///
/// While recording it captures *any* chord, including ones the system or
/// wicher itself would normally take first:
/// - wicher's own hot keys are suspended (`HotKeyCenter.suspend()`), so
///   pressing an existing switcher's shortcut reaches the recorder;
/// - the system's symbolic hot keys (⌘Tab, ⌘`, Spotlight…) are switched off
///   with the public `PushSymbolicHotKeyMode`, for exactly as long as the
///   recording lasts.
///
/// Held modifiers are shown live. Esc, a click elsewhere, or the window losing
/// focus cancels; a chord `validate` rejects shows the reason and keeps
/// recording.
///
/// A model, not an `NSButton`: the button itself is SwiftUI, so it takes part
/// in the Form's keyboard focus like the controls around it.
@Observable
final class ShortcutRecorder {
    var combo: HotKeyCombo {
        didSet { if !isRecording { title = combo.displayString } }
    }
    /// Returns why a chord cannot be used, or nil to accept it.
    @ObservationIgnored var validate: (HotKeyCombo) -> String? = { _ in nil }
    /// Called with an accepted chord.
    @ObservationIgnored var onChange: (HotKeyCombo) -> Void = { _ in }
    /// Called when recording starts (true) and ends (false).
    @ObservationIgnored var onRecordingChanged: (Bool) -> Void = { _ in }

    private(set) var title: String
    private(set) var isRecording = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var symbolicModeToken: UnsafeMutableRawPointer?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var messageWork: DispatchWorkItem?
    /// The click that cancelled recording. If it was on the button, its
    /// mouse-up then toggles, and must not start recording again.
    @ObservationIgnored private var cancellingClick: Int?

    private static let prompt = "Type shortcut…"

    init(combo: HotKeyCombo) {
        self.combo = combo
        title = combo.displayString
    }

    deinit { stopRecording() }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording { return stopRecording() }
        if let event = NSApp.currentEvent, event.type == .leftMouseUp,
           event.eventNumber == cancellingClick { return }
        startRecording()
    }

    private func startRecording() {
        guard !isRecording, let window = NSApp.keyWindow else { return }
        isRecording = true
        title = Self.prompt

        HotKeyCenter.shared.suspend()
        symbolicModeToken = PushSymbolicHotKeyMode(OptionBits(kHIHotKeyModeAllDisabled))
        SystemHotKeys.setAllPaused(true)
        onRecordingChanged(true)

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in self?.stopRecording() }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        SystemHotKeys.setAllPaused(false)
        if let symbolicModeToken { PopSymbolicHotKeyMode(symbolicModeToken) }
        symbolicModeToken = nil
        HotKeyCenter.shared.resume()
        onRecordingChanged(false)
        messageWork?.cancel()
        title = combo.displayString
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if Int(event.keyCode) == kVK_Escape, flags.isDisjoint(with: [.command, .option, .control, .shift]) {
                stopRecording()
                return nil
            }
            guard !event.isARepeat else { return nil }
            let candidate = HotKeyCombo(keyCode: UInt32(event.keyCode), modifierFlags: flags)
            if let problem = validate(candidate) {
                flash(problem)
            } else {
                combo = candidate
                stopRecording()
                onChange(candidate)
            }
            return nil
        case .flagsChanged:
            messageWork?.cancel()
            let held = HotKeyCombo.modifierGlyphs(event.modifierFlags)
            title = held.isEmpty ? Self.prompt : held + "…"
            return event
        default:
            // Any click cancels, the button's own included.
            cancellingClick = event.eventNumber
            stopRecording()
            return event
        }
    }

    /// Shows `message` in place of the prompt for a moment.
    private func flash(_ message: String) {
        messageWork?.cancel()
        title = message
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            self.title = Self.prompt
        }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

extension HotKeyCombo {
    init(keyCode: UInt32, modifierFlags flags: NSEvent.ModifierFlags) {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        self.init(keyCode: keyCode, carbonModifiers: mods)
    }

    /// "⌃⌥⇧⌘" for whichever of those `flags` holds, in the standard order.
    static func modifierGlyphs(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }
}
