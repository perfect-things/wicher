import AppKit
import ApplicationServices
import CoreGraphics

/// One switchable entry: a real window, or (when `isAppOnly`) an application
/// that currently has no standard windows.
///
/// Design note: wicher reads titles/minimized state via AX (`kAXTitleAttribute`,
/// `kAXMinimizedAttribute`) rather than `kCGWindowName`, so it needs only the
/// Accessibility permission it already requires to raise windows — not the
/// Screen Recording permission that `kCGWindowName` would demand.
final class WindowInfo {
    let pid: pid_t
    let bundleID: String?
    let appName: String
    let appIcon: NSImage?
    let title: String
    let axWindow: AXUIElement?
    let isMinimized: Bool
    let isAppHidden: Bool
    let isAppOnly: Bool
    let cgWindowID: CGWindowID?
    let onCurrentSpace: Bool

    init(pid: pid_t,
         bundleID: String?,
         appName: String,
         appIcon: NSImage?,
         title: String,
         axWindow: AXUIElement?,
         isMinimized: Bool,
         isAppHidden: Bool,
         isAppOnly: Bool = false,
         cgWindowID: CGWindowID? = nil,
         onCurrentSpace: Bool = true) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.appIcon = appIcon
        self.title = title
        self.axWindow = axWindow
        self.isMinimized = isMinimized
        self.isAppHidden = isAppHidden
        self.isAppOnly = isAppOnly
        self.cgWindowID = cgWindowID
        self.onCurrentSpace = onCurrentSpace
    }

    /// Primary label: window title, falling back to the app name.
    var displayTitle: String { title.isEmpty ? appName : title }
}
