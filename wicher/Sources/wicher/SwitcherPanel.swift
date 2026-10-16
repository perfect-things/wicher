import AppKit

/// A floating, non-activating panel for the switcher HUD.
///
/// `.nonactivatingPanel` lets the panel become key and receive keyboard events
/// *without* making wicher the active application, so the window you switch
/// away from stays visually in place until you commit — the standard approach
/// for Spotlight-style HUDs.
final class SwitcherPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Absorb key events silently. The switcher drives all keyboard handling
    /// from an NSEvent monitor; without these overrides an unhandled plain key
    /// (a letter while filtering) would bubble up and trigger the system beep,
    /// exactly like pressing an unbound key on the Desktop.
    override func keyDown(with event: NSEvent) { /* swallow — no beep */ }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
}
