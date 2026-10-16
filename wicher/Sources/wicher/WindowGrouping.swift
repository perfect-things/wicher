import Foundation

/// A labelled group of entries in the switcher list. A nil title means the
/// main (ungrouped) section shown at the top.
struct WindowSection {
    let title: String?
    let items: [WindowInfo]
}

/// Turns a raw enumeration into ordered, filtered sections according to a
/// profile's scope / Space / placement options. Pure function — easy to reason
/// about and independent of any UI.
enum WindowGrouping {
    static func sections(for profile: SwitcherProfile,
                         enumeration: Enumeration,
                         activeAppPID: pid_t?) -> [WindowSection] {
        var pool = enumeration.windows
        var apps = enumeration.appsWithoutWindows

        // Scope: all apps vs the app that was active when the switcher opened.
        if profile.scope == .activeApp, let pid = activeAppPID {
            pool = pool.filter { $0.pid == pid }
            apps = apps.filter { $0.pid == pid }
        }

        // Spaces: optionally restrict to the current Space.
        if profile.spaces == .visibleSpaces {
            pool = pool.filter { $0.onCurrentSpace }
        }

        // Categorize: minimized takes precedence, then hidden-app, then normal.
        var normal: [WindowInfo] = []
        var minimized: [WindowInfo] = []
        var hidden: [WindowInfo] = []
        for w in pool {
            if w.isMinimized { minimized.append(w) }
            else if w.isAppHidden { hidden.append(w) }
            else { normal.append(w) }
        }

        var main = normal
        var bottom: [WindowSection] = []

        func place(_ items: [WindowInfo], _ placement: Placement, title: String) {
            guard !items.isEmpty else { return }
            switch placement {
            case .hide: break
            case .show: main.append(contentsOf: items)
            case .showAtBottom: bottom.append(WindowSection(title: title, items: items))
            }
        }

        place(minimized, profile.minimized, title: "Minimized")
        place(hidden, profile.hidden, title: "Hidden")
        place(apps, profile.appsWithoutWindows, title: "Apps")

        var sections = [WindowSection(title: nil, items: main)]
        sections.append(contentsOf: bottom)
        // Drop a possibly-empty main section only if nothing else exists either.
        return sections.filter { !$0.items.isEmpty }
    }
}
