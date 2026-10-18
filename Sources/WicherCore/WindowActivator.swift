import AppKit
import ApplicationServices

/// Brings a chosen entry to the front.
///
/// - A real window: activate the app, un-minimize if needed, then raise.
/// - An app-only entry (no open windows, e.g. Finder) or a window we only know
///   via CGWindowList: reproduce a Dock-icon click, which asks the app to open
///   or restore a window (`applicationShouldHandleReopen`). `NSWorkspace`'s
///   open-with-reopen does this without relaunching the running instance.
enum WindowActivator {
    static func activate(_ info: WindowInfo) {
        let app = NSRunningApplication(processIdentifier: info.pid)

        // One of our own windows (Settings). We own it, so order it front
        // directly — AX and the Dock-click reopen would both be indirections
        // around something we can simply do.
        if info.isOwnWindow {
            if let window = NSApp.windows.first(where: { $0.cgWindowID == info.cgWindowID }) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                activateSelf()
                window.makeKeyAndOrderFront(nil)
                if let wid = info.cgWindowID {
                    WindowEnumerator.shared.noteActivatedWindow(wid, pid: info.pid)
                }
                return
            }
        }

        if let axWindow = info.axWindow, !info.isAppOnly {
            // Activate the owning app first; some apps won't honor an
            // un-minimize/raise on a background process.
            bringToFront(app)

            if info.isMinimized {
                DeminiaturizeWaiter.unminimizeThenRaise(axWindow, pid: info.pid)
            } else {
                raise(axWindow)
            }
        } else {
            // App-only / CGWindowList-only: emulate a Dock-icon click so a
            // window-less app (Finder) opens or reveals a window.
            reopen(app, info: info)
        }

        if let wid = info.cgWindowID {
            WindowEnumerator.shared.noteActivatedWindow(wid, pid: info.pid)
        } else {
            WindowEnumerator.shared.noteActivated(pid: info.pid)
        }
    }

    /// Makes wicher the active app. Only the deprecated
    /// `activate(ignoringOtherApps: true)` does this from the background:
    /// `NSApp.activate()` and `NSRunningApplication.current.activate()` are
    /// cooperative on macOS 14+ and are ignored while another app is active
    /// (an `.accessory` app is, nearly always), and `orderFrontRegardless`
    /// still lands below the active app's windows. Called through
    /// `SelfActivating` so the deprecation doesn't warn at every call site.
    static func activateSelf() {
        (NSApp as SelfActivating).activateIgnoringOtherApps()
    }

    static func raise(_ axWindow: AXUIElement) {
        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
    }

    private static func bringToFront(_ app: NSRunningApplication?) {
        app?.activate()
    }

    /// Reproduce a Dock-icon click: activate, and ask the app to reopen a window.
    private static func reopen(_ app: NSRunningApplication?, info: WindowInfo) {
        guard let url = app?.bundleURL ?? bundleURL(forPID: info.pid) else {
            bringToFront(app)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        // openApplication on an already-running app sends it a reopen event
        // (the Dock-click behavior) instead of launching a second instance.
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    private static func bundleURL(forPID pid: pid_t) -> URL? {
        NSRunningApplication(processIdentifier: pid)?.bundleURL
    }
}

private protocol SelfActivating { func activateIgnoringOtherApps() }

extension NSApplication: SelfActivating {
    @available(macOS, deprecated: 14)
    fileprivate func activateIgnoringOtherApps() { activate(ignoringOtherApps: true) }
}

/// Un-minimizes a window and raises it once the Dock animation has finished.
///
/// Raising straight after clearing `kAXMinimized` races the animation: the
/// window is not on screen yet, so the raise is lost (or, for some apps, the
/// un-minimize itself is ignored until the app is active). Waiting for
/// `kAXWindowDeminiaturizedNotification` removes the race; the timeout covers
/// apps that never send it, and re-applies the un-minimize if it did not take.
private final class DeminiaturizeWaiter {
    /// Keeps waiters alive until they finish.
    private static var pending: [ObjectIdentifier: DeminiaturizeWaiter] = [:]
    private static let timeout: TimeInterval = 0.6

    private let window: AXUIElement
    private var observer: AXObserver?
    private var finished = false

    static func unminimizeThenRaise(_ window: AXUIElement, pid: pid_t) {
        let waiter = DeminiaturizeWaiter(window: window)
        pending[ObjectIdentifier(waiter)] = waiter
        waiter.start(pid: pid)
    }

    private init(window: AXUIElement) { self.window = window }

    private func start(pid: pid_t) {
        // Observe first, then act, so the notification cannot be missed.
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<DeminiaturizeWaiter>.fromOpaque(refcon).takeUnretainedValue().finish()
        }
        if AXObserverCreate(pid, callback, &observer) == .success, let observer,
           AXObserverAddNotification(observer, window, kAXWindowDeminiaturizedNotification as CFString,
                                     Unmanaged.passUnretained(self).toOpaque()) == .success {
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            self.observer = observer
        }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        if let observer {
            AXObserverRemoveNotification(observer, window, kAXWindowDeminiaturizedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &ref) == .success,
           (ref as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        WindowActivator.raise(window)
        // Released on the next turn of the run loop, after the AX callback
        // that may have called us has returned.
        DispatchQueue.main.async { Self.pending[ObjectIdentifier(self)] = nil }
    }
}
