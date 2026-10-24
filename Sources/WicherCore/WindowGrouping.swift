import Foundation
import CoreGraphics

/// The switcher's entries: the main group, then every category placed "at
/// bottom", merged into one group. Each bottom entry carries a short note
/// saying why it is there.
struct WindowGroups {
    var main: [WindowInfo] = []
    var bottom: [(window: WindowInfo, note: String)] = []

    var isEmpty: Bool { main.isEmpty && bottom.isEmpty }
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

/// Turns a raw enumeration into ordered, filtered groups according to a
/// profile's scope / placement options. Pure function — easy to reason
/// about and independent of any UI.
enum WindowGrouping {
    /// The placement categories, in the order their windows appear in the
    /// bottom group.
    enum Category: CaseIterable {
        case otherDisplay, otherSpace, minimized, hidden

        /// The bottom group's note for one of these windows.
        var note: String {
            switch self {
            case .otherDisplay: return "Other Display"
            case .otherSpace: return "Other Space"
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

    /// The bottom group's note for an app-only entry.
    static let appOnlyNote = "No Windows"
    /// The bottom group's note for a window an exception moved there.
    static let exceptionNote = "Exception"

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
    /// Spaces / other displays and windows an exception hides. Minimized and
    /// hidden-app windows stay searchable whatever their placement; app-only
    /// entries never are.
    static func searchPool(for profile: SwitcherProfile,
                           enumeration: Enumeration,
                           activeAppPID: pid_t?,
                           display: DisplayLayout? = nil,
                           exceptions: ExceptionRules = .none) -> [WindowInfo] {
        scoped(enumeration.windows, profile, activeAppPID).filter { w in
            if exceptions.outcome(for: w) == .hide { return false }
            if profile.otherSpaces == .hide, !w.onCurrentSpace { return false }
            if profile.otherDisplays == .hide, w.onCurrentSpace,
               let display, let wid = w.cgWindowID, let frame = enumeration.windowFrames[wid],
               display.isOnOtherDisplay(frame) { return false }
            return true
        }
    }

    /// The note `groups` would give `window` in the bottom group, or nil when
    /// its category is shown in the main group (or it has none). For search
    /// results, which are one flat list but keep saying why a window would
    /// be at the bottom.
    static func note(for window: WindowInfo, profile: SwitcherProfile, enumeration: Enumeration,
                     display: DisplayLayout? = nil, exceptions: ExceptionRules = .none) -> String? {
        let demoted = exceptions.outcome(for: window) == .bottom
        if window.isAppOnly {
            return profile.appsWithoutWindows == .showAtBottom || demoted ? appOnlyNote : nil
        }
        if demoted { return exceptionNote }
        guard let c = category(of: window, enumeration: enumeration, display: display),
              c.placement(in: profile) == .showAtBottom else { return nil }
        return c.note
    }

    /// Exceptions apply after the profile: a window the profile hides stays
    /// hidden, one an exception demotes goes to the bottom group (after the
    /// placement categories, noted "Exception"), and one it hides is dropped.
    /// An app-only entry keeps its "No Windows" note when demoted.
    static func groups(for profile: SwitcherProfile,
                       enumeration: Enumeration,
                       activeAppPID: pid_t?,
                       display: DisplayLayout? = nil,
                       exceptions: ExceptionRules = .none) -> WindowGroups {
        var groups = WindowGroups()
        var byCategory: [Category: [WindowInfo]] = [:]
        var demoted: [WindowInfo] = []
        for w in scoped(enumeration.windows, profile, activeAppPID) {
            let c = category(of: w, enumeration: enumeration, display: display)
            switch exceptions.outcome(for: w) {
            case .hide: continue
            case .bottom:
                if c?.placement(in: profile) != .hide { demoted.append(w) }
            case nil:
                if let c { byCategory[c, default: []].append(w) } else { groups.main.append(w) }
            }
        }

        func place(_ items: [WindowInfo], _ placement: Placement, note: String) {
            switch placement {
            case .hide: break
            case .show: groups.main.append(contentsOf: items)
            case .showAtBottom: groups.bottom.append(contentsOf: items.map { ($0, note) })
            }
        }

        for c in Category.allCases {
            place(byCategory[c] ?? [], c.placement(in: profile), note: c.note)
        }
        place(demoted, .showAtBottom, note: exceptionNote)
        let apps = scoped(enumeration.appsWithoutWindows, profile, activeAppPID)
            .filter { exceptions.outcome(for: $0) != .hide }
        let appsPlacement = profile.appsWithoutWindows
        place(apps.filter { exceptions.outcome(for: $0) == nil }, appsPlacement, note: appOnlyNote)
        place(apps.filter { exceptions.outcome(for: $0) == .bottom },
              appsPlacement == .hide ? .hide : .showAtBottom, note: appOnlyNote)
        return groups
    }

    /// Scope: all apps vs the app that was active when the switcher opened.
    private static func scoped(_ items: [WindowInfo], _ profile: SwitcherProfile,
                               _ activeAppPID: pid_t?) -> [WindowInfo] {
        guard profile.scope == .activeApp, let pid = activeAppPID else { return items }
        return items.filter { $0.pid == pid }
    }
}
