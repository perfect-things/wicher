import Foundation
@testable import WicherCore

/// Hand-built window: no AX element, no icon.
func window(_ title: String,
            pid: pid_t = 1,
            app: String = "App",
            minimized: Bool = false,
            hidden: Bool = false,
            onCurrentSpace: Bool = true,
            appOnly: Bool = false) -> WindowInfo {
    WindowInfo(pid: pid, bundleID: nil, appName: app, appIcon: nil, title: title,
               axWindow: nil, isMinimized: minimized, isAppHidden: hidden,
               isAppOnly: appOnly, onCurrentSpace: onCurrentSpace)
}

func appOnly(_ app: String, pid: pid_t) -> WindowInfo {
    window("", pid: pid, app: app, appOnly: true)
}

func enumeration(_ windows: [WindowInfo], apps: [WindowInfo] = []) -> Enumeration {
    Enumeration(windows: windows, appsWithoutWindows: apps, currentSpaceWindowIDs: [])
}

func profile(scope: WindowScope = .allApps,
             spaces: SpaceScope = .allSpaces,
             minimized: Placement = .showAtBottom,
             hidden: Placement = .showAtBottom,
             apps: Placement = .showAtBottom) -> SwitcherProfile {
    SwitcherProfile(id: UUID(), name: "Test", keyCode: 0, carbonModifiers: 0,
                    scope: scope, spaces: spaces, minimized: minimized,
                    hidden: hidden, appsWithoutWindows: apps)
}
