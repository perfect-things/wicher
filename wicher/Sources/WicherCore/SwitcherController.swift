import AppKit
import Carbon.HIToolbox

/// Orchestrates a switcher session: summon/advance (with an optional pre-show
/// delay), hold-to-repeat, event monitors, and commit-on-modifier-release —
/// all without an event tap.
///
/// What is on offer and what is selected lives in `SwitcherSession`; turning
/// that into views lives in `SwitcherListView`. This class wires the two to
/// hot keys, monitors and the panel.
final class SwitcherController: NSObject, SwitcherRowViewDelegate {
    private let panel = SwitcherPanel()
    private let listView = SwitcherListView()

    /// Non-nil exactly while a session is active.
    private var session: SwitcherSession?
    private var panelShown = false
    private var pendingShow: DispatchWorkItem?
    /// The screen the session opened on. Fixed for the session, so a live
    /// refresh resizes the panel in place instead of chasing the mouse.
    private var sessionScreen: NSScreen?
    private var metrics = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7)

    private var localMonitor: Any?
    private var globalMonitor: Any?

    // Auto-repeat while the trigger is held down.
    private var holdDirection: Int?
    private var holdTimer: Timer?
    private var holdStart = Date()
    private let holdInitialDelay: TimeInterval = 0.30
    private let holdRepeatInterval: TimeInterval = 0.05

    override init() {
        super.init()
        listView.rowDelegate = self
        panel.contentView = listView
        NotificationCenter.default.addObserver(self, selector: #selector(windowsRefreshed),
                                               name: WindowEnumerator.didRefresh, object: nil)
    }

    /// A background scan finished. If the panel is up, show the fresh state —
    /// new titles, windows opened or closed since summon — without losing the
    /// user's place. Not before the panel is shown: a quick tap must switch to
    /// exactly the window that was preselected.
    @objc private func windowsRefreshed() {
        guard panelShown, let latest = WindowEnumerator.shared.latestSnapshot(),
              session?.update(enumeration: latest) == true else { return }
        renderRows()
        updateSelectionHighlight()
    }

    // MARK: - Entry points

    /// Menu entry point: open the switcher (no hold behavior).
    func summon(profile: SwitcherProfile, forward: Bool) {
        if session != nil {
            advance(by: forward ? 1 : -1)
        } else {
            beginSession(profile: profile, forward: forward)
        }
    }

    /// Hot-key entry point. `pressed` is true on key-down, false on key-up, so
    /// we can auto-repeat while the key is held and stop when it is released.
    func hotKey(profile: SwitcherProfile, forward: Bool, pressed: Bool) {
        let dir = forward ? 1 : -1
        if pressed {
            // Guard against any OS-generated repeat presses: clamp, keep timer.
            if session != nil, holdDirection == dir {
                advance(by: dir, wrap: false)
                return
            }
            holdDirection = dir
            if session != nil {
                advance(by: dir, wrap: true) // a fresh discrete press wraps
                startHoldTimer()
            } else {
                beginSession(profile: profile, forward: forward)
            }
        } else {
            if holdDirection == dir {
                holdDirection = nil
                stopHoldTimer()
            }
        }
    }

    // MARK: - Session lifecycle

    private func beginSession(profile: SwitcherProfile, forward: Bool) {
        metrics = HUDMetrics.make(iconSize: Settings.shared.iconSize,
                                  textSize: Settings.shared.textSize,
                                  rowPadding: Settings.shared.rowPadding)
        sessionScreen = screenWithMouse() ?? NSScreen.main
        let activeAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Make sure the window currently in front is the most-recent one, so a
        // quick tap selects the genuine previous window (see SwitcherSession.init).
        if let pid = activeAppPID { WindowEnumerator.shared.noteFrontmost(pid: pid) }
        session = SwitcherSession(profile: profile,
                                  enumeration: WindowEnumerator.shared.enumerate(),
                                  activeAppPID: activeAppPID,
                                  forward: forward)
        listView.setQuery("")
        // Without Accessibility trust, every row comes from the CGWindowList
        // fallback, which has no titles — say so rather than silently listing
        // bare app names.
        listView.setNotice(AXIsProcessTrusted()
            ? nil
            : "Accessibility access is off — window titles unavailable. Re-enable Wicher in System Settings.")

        panelShown = false
        startMonitors()

        let delay = Settings.shared.showDelayMs
        if delay <= 0 {
            showPanelNow()
        } else {
            let work = DispatchWorkItem { [weak self] in self?.showPanelNow() }
            pendingShow = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
        }
    }

    private func showPanelNow() {
        guard session != nil, !panelShown else { return }
        renderRows()
        panel.makeKeyAndOrderFront(nil)
        panelShown = true
        updateSelectionHighlight()
        if holdDirection != nil { startHoldTimer() }
    }

    private func endSession() {
        pendingShow?.cancel()
        pendingShow = nil
        stopHoldTimer()
        holdDirection = nil
        stopMonitors()
        if panelShown { panel.orderOut(nil) }
        listView.clear()
        session = nil
        sessionScreen = nil
        panelShown = false
    }

    private func commit() {
        guard let session else { return }
        let target = session.selectedWindow
        endSession()
        if let target { WindowActivator.activate(target) }
    }

    private func cancel() { endSession() }

    // MARK: - Monitors

    private func startMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .scrollWheel]) { [weak self] event in
            self?.handleLocal(event) ?? event
        }
        // Global monitor: observes events routed to *other* apps. Needed while
        // the panel is not yet key (during the show-delay) to catch the trigger
        // modifier being released, and to dismiss on an outside click.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .flagsChanged]) { [weak self] event in
            guard let self else { return }
            if event.type == .flagsChanged {
                if self.triggerReleased(by: event) { self.commit() }
            } else {
                self.cancel()
            }
        }
    }

    private func stopMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    /// True when `event` no longer holds the active profile's trigger modifiers.
    private func triggerReleased(by event: NSEvent) -> Bool {
        guard let trigger = session?.profile.combo.eventModifierFlags, !trigger.isEmpty else { return false }
        return !event.modifierFlags.contains(trigger)
    }

    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            if triggerReleased(by: event) { commit() }
            return event
        case .scrollWheel:
            if panelShown, Settings.shared.selectOnScroll, event.deltaY != 0 {
                advance(by: event.deltaY < 0 ? 1 : -1)
                return nil
            }
            return event
        case .keyDown:
            handleKeyDown(event)
            return nil // swallow every key while a session is active (no beeps)
        default:
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // The trigger's own modifiers are being held to keep the panel open;
        // they must not stop ⌘-held typing from searching when the shortcut
        // is ⌘Tab, nor count as Shift-Tab when the shortcut includes ⇧.
        let trigger = session?.profile.combo.eventModifierFlags ?? []
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(trigger)
        switch Int(event.keyCode) {
        case kVK_Escape:
            cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            commit()
        case kVK_Tab:
            advance(by: mods.contains(.shift) ? -1 : 1)
        case kVK_DownArrow:
            advance(by: 1)
        case kVK_UpArrow:
            advance(by: -1)
        case kVK_Delete:
            if session?.deleteBackward() == true { queryChanged() }
        default:
            guard !mods.contains(.command), !mods.contains(.control),
                  let chars = event.charactersIgnoringModifiers, chars.count == 1,
                  let scalar = chars.unicodeScalars.first,
                  scalar.value >= 0x20, scalar.value != 0x7F
            else { return }
            session?.appendToQuery(Character(scalar))
            queryChanged()
        }
    }

    // MARK: - Selection

    private func queryChanged() {
        guard let session else { return }
        listView.setQuery(session.query)
        if panelShown {
            renderRows()
            updateSelectionHighlight()
        } else {
            showPanelNow()
        }
    }

    private func advance(by step: Int, wrap: Bool = true) {
        session?.advance(by: step, wrap: wrap)
        if panelShown { updateSelectionHighlight() }
    }

    private func updateSelectionHighlight() {
        listView.highlight(rowIndex: session?.selectedRowIndex)
    }

    // MARK: - Auto-repeat while held

    private func startHoldTimer() {
        guard panelShown, holdDirection != nil else { return }
        stopHoldTimer()
        holdStart = Date()
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdRepeatInterval, repeats: true) { [weak self] _ in
            guard let self, self.panelShown, let dir = self.holdDirection else { return }
            // Honor an initial delay before the auto-repeat kicks in.
            if Date().timeIntervalSince(self.holdStart) < self.holdInitialDelay { return }
            // Auto-repeat clamps at the ends; explicit presses wrap.
            self.advance(by: dir, wrap: false)
        }
    }

    private func stopHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    // MARK: - Panel

    /// Renders the session's rows, then sizes the panel to them and centers it
    /// on the screen with the mouse.
    private func renderRows() {
        guard let session else { return }
        listView.render(session.rows, metrics: metrics)

        let frame = sessionScreen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = listView.preferredHeight(maxListHeight: frame.height * 0.7)
        let origin = NSPoint(x: frame.midX - metrics.panelWidth / 2,
                             y: frame.midY - height / 2)
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: metrics.panelWidth, height: height), display: true)
        // The window shadow is cached from the previous opaque shape; without
        // this it keeps the old (or square) outline after a resize.
        panel.invalidateShadow()
    }

    private func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    // MARK: - SwitcherRowViewDelegate

    func rowHovered(displayIndex: Int) {
        guard Settings.shared.selectOnHover, session?.select(rowIndex: displayIndex) == true else { return }
        updateSelectionHighlight()
    }

    func rowClicked(displayIndex: Int) {
        guard session?.select(rowIndex: displayIndex) == true else { return }
        commit()
    }
}
