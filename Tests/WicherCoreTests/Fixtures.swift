import Foundation
import ApplicationServices
import CoreGraphics
@testable import WicherCore

/// Hand-built window: no AX element, no icon.
func window(_ title: String,
            pid: pid_t = 1,
            app: String = "App",
            minimized: Bool = false,
            hidden: Bool = false,
            onCurrentSpace: Bool = true,
            appOnly: Bool = false,
            wid: CGWindowID? = nil,
            bundle: String? = nil) -> WindowInfo {
    WindowInfo(pid: pid, bundleID: bundle, appName: app, appIcon: nil, title: title,
               axWindow: nil, isMinimized: minimized, isAppHidden: hidden,
               isAppOnly: appOnly, cgWindowID: wid, onCurrentSpace: onCurrentSpace)
}

func appOnly(_ app: String, pid: pid_t, bundle: String? = nil) -> WindowInfo {
    window("", pid: pid, app: app, appOnly: true, bundle: bundle)
}

func enumeration(_ windows: [WindowInfo], apps: [WindowInfo] = [],
                 frames: [CGWindowID: CGRect] = [:]) -> Enumeration {
    Enumeration(windows: windows, appsWithoutWindows: apps, currentSpaceWindowIDs: [], windowFrames: frames)
}

/// Two side-by-side 1000×800 displays; the switcher opens on the left one.
let twoDisplays = DisplayLayout(displays: [CGRect(x: 0, y: 0, width: 1000, height: 800),
                                           CGRect(x: 1000, y: 0, width: 1000, height: 800)],
                                current: CGRect(x: 0, y: 0, width: 1000, height: 800))
/// A window frame lying mostly on the right-hand display of `twoDisplays`.
let rightDisplayFrame = CGRect(x: 900, y: 100, width: 600, height: 400)

func profile(scope: WindowScope = .allApps,
             otherDisplays: Placement = .show,
             otherSpaces: Placement = .show,
             minimized: Placement = .showAtBottom,
             hidden: Placement = .showAtBottom,
             apps: Placement = .showAtBottom,
             keyCode: UInt32 = 0,
             carbonModifiers: UInt32 = 0) -> SwitcherProfile {
    SwitcherProfile(id: UUID(), name: "Test", keyCode: keyCode, carbonModifiers: carbonModifiers,
                    scope: scope, otherDisplays: otherDisplays, otherSpaces: otherSpaces,
                    minimized: minimized,
                    hidden: hidden, appsWithoutWindows: apps)
}

// MARK: - Enumeration inputs (`WindowAssembly`)

func meta(_ pid: pid_t, _ name: String, hidden: Bool = false, regular: Bool = true) -> AppMeta {
    AppMeta(pid: pid, bundleID: "test.\(name)", name: name, icon: nil, isHidden: hidden, isRegular: regular)
}

func fact(_ id: CGWindowID, pid: pid_t, onscreen: Bool = true, layer: Int = 0,
          size: CGSize = CGSize(width: 800, height: 600)) -> CGWindowFact {
    CGWindowFact(id: id, pid: pid, layer: layer, isOnscreen: onscreen, order: Int(id), size: size, alpha: 1)
}

func ax(_ wid: CGWindowID?, _ title: String, minimized: Bool = false) -> ScannedWindow {
    ScannedWindow(element: AXUIElementCreateApplication(1), title: title, minimized: minimized, wid: wid)
}

func answered(_ windows: [ScannedWindow]) -> AppScan {
    AppScan(windows: windows, answered: !windows.isEmpty, responded: true)
}

var timedOut: AppScan { AppScan(windows: [], answered: false, responded: false) }
