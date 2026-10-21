import Foundation
import CoreGraphics

/// A labelled group of entries in the switcher list. A nil title means the
/// main (ungrouped) section shown at the top.
struct WindowSection {
    let title: String?
    let items: [WindowInfo]
}

/// The displays, in global display coordinates (as CGWindowList bounds), and
/// the one the switcher opens on.
struct DisplayLayout {
    let displays: [CGRect]
    let current: CGRect

    /// Whether most of `frame` lies on a display other than `current`. A
    /// window on no display at all (or with a single display) is not.
    func isOnOtherDisplay(_ frame: CGRect) -> Bool {
        var best: (display: CGRect, area: CGFloat)?
        for display in displays {
            let overlap = display.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (display, area) }
        }
        guard let best else { return false }
        return best.display != current
    }
}

/// Turns a raw enumeration into ordered, filtered sections according to a
/// profile's scope / placement options. Pure function — easy to reason
/// about and independent of any UI.
enum WindowGrouping {
    /// The placement categories, in the order their bottom sections appear.
    enum Category: CaseIterable {
        case otherDisplay, otherSpace, minimized, hidden

        var title: String {
            switch self {
            case .otherDisplay: return "Other Displays"
            case .otherSpace: return "Other Spaces"
            case .minimized: return "Minimized"
            case .hidden: return "Hidden"
            }
        }

        func placement(in profile: SwitcherProfile) -> Placement {
            switch self {
            case .otherDisplay: return profile.otherDisplays
            case .otherSpace: return profile.otherSpaces
            case .minimized: return profile.minimized
            case .hidden: return profile.hidden
            }
        }
    }

    /// Minimized takes precedence, then hidden-app, then other Space, then
    /// other display; nil is a plain window. Without a `display` layout no
    /// window counts as on another display.
    static func category(of window: WindowInfo, enumeration: Enumeration,
                         display: DisplayLayout?) -> Category? {
        if window.isMinimized { return .minimized }
        if window.isAppHidden { return .hidden }
        if !window.onCurrentSpace { return .otherSpace }
        if let display, let wid = window.cgWindowID, let frame = enumeration.windowFrames[wid],
           display.isOnOtherDisplay(frame) { return .otherDisplay }
        return nil
    }

    /// The windows a search ranks: the profile's scope, minus hidden other
    /// Spaces / other displays. Minimized and hidden-app windows stay
    /// searchable whatever their placement; app-only entries never are.
    static func searchPool(for profile: SwitcherProfile,
                           enumeration: Enumeration,
                           activeAppPID: pid_t?,
                           display: DisplayLayout? = nil) -> [WindowInfo] {
        scoped(enumeration.windows, profile, activeAppPID).filter { w in
            if profile.otherSpaces == .hide, !w.onCurrentSpace { return false }
            if profile.otherDisplays == .hide, w.onCurrentSpace,
               let display, let wid = w.cgWindowID, let frame = enumeration.windowFrames[wid],
               display.isOnOtherDisplay(frame) { return false }
            return true
        }
    }

    static func sections(for profile: SwitcherProfile,
                         enumeration: Enumeration,
                         activeAppPID: pid_t?,
                         display: DisplayLayout? = nil) -> [WindowSection] {
        var main: [WindowInfo] = []
        var byCategory: [Category: [WindowInfo]] = [:]
        for w in scoped(enumeration.windows, profile, activeAppPID) {
            if let c = category(of: w, enumeration: enumeration, display: display) {
                byCategory[c, default: []].append(w)
            } else {
                main.append(w)
            }
        }

        var bottom: [WindowSection] = []

        func place(_ items: [WindowInfo], _ placement: Placement, title: String) {
            guard !items.isEmpty else { return }
            switch placement {
            case .hide: break
            case .show: main.append(contentsOf: items)
            case .showAtBottom: bottom.append(WindowSection(title: title, items: items))
            }
        }

        for c in Category.allCases {
            place(byCategory[c] ?? [], c.placement(in: profile), title: c.title)
        }
        place(scoped(enumeration.appsWithoutWindows, profile, activeAppPID),
              profile.appsWithoutWindows, title: "Apps")

        var sections = [WindowSection(title: nil, items: main)]
        sections.append(contentsOf: bottom)
        // Drop a possibly-empty main section only if nothing else exists either.
        return sections.filter { !$0.items.isEmpty }
    }

    /// Scope: all apps vs the app that was active when the switcher opened.
    private static func scoped(_ items: [WindowInfo], _ profile: SwitcherProfile,
                               _ activeAppPID: pid_t?) -> [WindowInfo] {
        guard profile.scope == .activeApp, let pid = activeAppPID else { return items }
        return items.filter { $0.pid == pid }
    }
}
