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

/// Which Spaces a switcher profile includes.
enum SpaceScope: Int, Codable, CaseIterable {
    case allSpaces = 0
    case visibleSpaces = 1

    var title: String {
        switch self {
        case .allSpaces: return "All Spaces"
        case .visibleSpaces: return "Visible Spaces"
        }
    }
}

/// How a category of windows (minimized / hidden / app-only) is placed.
enum Placement: Int, Codable, CaseIterable {
    case show = 0        // merged into the main list
    case showAtBottom = 1 // its own section at the bottom
    case hide = 2         // excluded

    var title: String {
        switch self {
        case .show: return "Show"
        case .showAtBottom: return "Show at bottom"
        case .hide: return "Do not show"
        }
    }
}

/// How a switcher's panel presents its windows.
enum SwitcherLayout: Int, Codable, CaseIterable {
    case list = 0   // rows: app name, icon, title
    case icons = 1  // one row of icons, like the system ⌘Tab switcher

    var title: String {
        switch self {
        case .list: return "List"
        case .icons: return "Icons"
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
    var spaces: SpaceScope
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
                            spaces: .allSpaces,
                            minimized: .showAtBottom,
                            hidden: .showAtBottom,
                            appsWithoutWindows: .showAtBottom),
            SwitcherProfile(id: UUID(),
                            name: "Current App",
                            keyCode: HotKeyCombo.currentAppCombo.keyCode,
                            carbonModifiers: HotKeyCombo.currentAppCombo.carbonModifiers,
                            scope: .activeApp,
                            spaces: .allSpaces,
                            minimized: .showAtBottom,
                            hidden: .hide,
                            appsWithoutWindows: .hide),
        ]
    }
}
