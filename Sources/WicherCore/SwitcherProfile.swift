import Foundation

/// Which applications' windows a switcher profile includes.
enum WindowScope: Int, Codable, CaseIterable {
    case allApps = 0
    case activeApp = 1

    var title: String {
        switch self {
        case .allApps: return "All apps"
        case .activeApp: return "Active app"
        }
    }
}

/// How a category of windows (other display / other Space / minimized /
/// hidden / app-only) is placed.
enum Placement: Int, Codable, CaseIterable {
    case show = 0        // merged into the main list
    case showAtBottom = 1 // in the one group at the bottom, behind a separator
    case hide = 2         // excluded

    var title: String {
        switch self {
        case .show: return "Show"
        case .showAtBottom: return "At bottom"
        case .hide: return "Hide"
        }
    }

    /// For a count of windows, as in "3 at bottom".
    var summaryTitle: String {
        switch self {
        case .show: return "shown"
        case .showAtBottom: return "at bottom"
        case .hide: return "hidden"
        }
    }
}

/// How a switcher's panel presents its windows.
enum SwitcherLayout: Int, Codable, CaseIterable {
    case list = 0   // rows: app name, icon, title
    case icons = 1  // one row of icons, like the system ⌘Tab switcher

    var title: String {
        switch self {
        case .list: return "List view"
        case .icons: return "Icons view"
        }
    }
}

/// One configurable switcher: a shortcut plus the filters that shape its list.
/// Several profiles can coexist (e.g. ⌥Tab for all windows, ⌥` for the active
/// app's windows) — each registers its own global hot key.
struct SwitcherProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var scope: WindowScope
    /// Windows on the current Space of a display other than the one the
    /// switcher opens on.
    var otherDisplays: Placement
    /// Windows on no display's current Space.
    var otherSpaces: Placement
    var minimized: Placement
    var hidden: Placement
    var appsWithoutWindows: Placement
    var layout: SwitcherLayout = .list

    var combo: HotKeyCombo {
        get { HotKeyCombo(keyCode: keyCode, carbonModifiers: carbonModifiers) }
        set { keyCode = newValue.keyCode; carbonModifiers = newValue.carbonModifiers }
    }

    static func defaults() -> [SwitcherProfile] {
        [
            SwitcherProfile(id: UUID(),
                            name: "All Windows",
                            keyCode: HotKeyCombo.defaultCombo.keyCode,
                            carbonModifiers: HotKeyCombo.defaultCombo.carbonModifiers,
                            scope: .allApps,
                            otherDisplays: .show,
                            otherSpaces: .show,
                            minimized: .showAtBottom,
                            hidden: .showAtBottom,
                            appsWithoutWindows: .showAtBottom),
            SwitcherProfile(id: UUID(),
                            name: "Current App",
                            keyCode: HotKeyCombo.currentAppCombo.keyCode,
                            carbonModifiers: HotKeyCombo.currentAppCombo.carbonModifiers,
                            scope: .activeApp,
                            otherDisplays: .show,
                            otherSpaces: .show,
                            minimized: .showAtBottom,
                            hidden: .hide,
                            appsWithoutWindows: .hide),
        ]
    }
}
