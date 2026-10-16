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

        // One of our own windows (Preferences). We own it, so order it front
        // directly — AX and the Dock-click reopen would both be indirections
        // around something we can simply do.
        if info.pid == ProcessInfo.processInfo.processIdentifier, !info.isAppOnly {
            if let window = NSApp.windows.first(where: { $0.cgWindowID == info.cgWindowID }) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
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
                // Un-minimizing can need a moment after activation to take; set
                // the attribute, and retry once on the next runloop if it is
                // still minimized.
                AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    var ref: CFTypeRef?
                    if AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &ref) == .success,
                       (ref as? Bool) == true {
                        AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    }
                    AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                }
            } else {
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
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

    /// `.activateIgnoringOtherApps` is deprecated from macOS 14 and has no
    /// effect there; `activate()` is the replacement.
    private static func bringToFront(_ app: NSRunningApplication?) {
        if #available(macOS 14, *) {
            app?.activate()
        } else {
            app?.activate(options: [.activateIgnoringOtherApps])
        }
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
