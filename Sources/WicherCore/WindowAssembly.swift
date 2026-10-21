import AppKit
import ApplicationServices
import CoreGraphics

// The pure half of window enumeration: given what CGWindowList, NSWorkspace
// and the Accessibility API reported, decide which rows exist. No IPC, no
// globals, no clocks — `WindowEnumerator` collects the inputs and calls
// `WindowAssembly.assemble`, and the tests call it with hand-built inputs.

/// Window facts read from CGWindowList — numbers/pids/layer/bounds only, never
/// `kCGWindowName`, so no Screen Recording permission is needed.
///
/// The list is taken with `.optionAll`, which includes windows that are *not*
/// on screen: minimized ones, windows of hidden apps, and windows living on
/// other Spaces (including full-screen Spaces). `isOnscreen` then tells the
/// current Space apart from the rest.
struct CGWindowFact {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let isOnscreen: Bool
    let order: Int
    let size: CGSize
    let alpha: Double
    /// Exists but is in no Space: an inactive tab of a native tab group, or a
    /// window its app closed but kept alive. Neither is a switch target, and
    /// both would otherwise pass for a window on another Space. Only resolved
    /// for off-screen windows during a full scan (see `SpacesPrivate`).
    var isOrderedOut = false

    /// Could plausibly be a user-facing window.
    ///
    /// Every app owns a handful of layer-0 windows that are not: one 1728×33
    /// strip per display (menu-bar backing), 64×64 icon caches, and assorted
    /// off-screen scratch windows. The size floor rejects those; it is a
    /// *necessary*, not sufficient, test — see `representativeWindow`.
    var isPlausibleWindow: Bool {
        layer == 0 && alpha > 0.01 && size.width >= 200 && size.height >= 120
    }

    /// A window on screen at a layer other than 0 is one of the helper windows
    /// macOS makes for a full-screen Space, not a real window. A genuine window
    /// on another Space is not on screen at all, so it never matches.
    var isFullScreenShim: Bool { isOnscreen && layer != 0 }
}

/// Flat, thread-safe description of one running app, captured once per scan so
/// the parallel AX workers never touch `NSRunningApplication`.
struct AppMeta {
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?
    let isHidden: Bool
    let isRegular: Bool
}

/// One window as the Accessibility API reported it.
struct ScannedWindow {
    let element: AXUIElement
    let title: String
    let minimized: Bool
    let wid: CGWindowID?
}

struct AppScan {
    let windows: [ScannedWindow]
    /// AX answered with at least one standard window. False means AX gave us
    /// nothing — either the app genuinely has no windows, or it was too slow /
    /// too asleep to answer, which is why the CGWindowList fallback exists.
    let answered: Bool
    /// AX replied at all. Distinct from `answered`: an app that responded with
    /// an empty window list has genuinely closed its last window, which is
    /// worth acting on, whereas a timeout tells us nothing.
    let responded: Bool
}

/// What wicher remembers per window between scans, so a window keeps its
/// title, raise-ability and minimized flag while its app is too asleep (or
/// too hidden) to answer AX.
struct WindowCaches {
    /// Last known AX title. Survives an app going to sleep, so a hidden or
    /// off-Space window keeps its real title instead of decaying to the bare
    /// app name.
    var titles: [CGWindowID: String] = [:]
    /// Last known AX element, so a window we can currently only see via
    /// CGWindowList can still be raised individually.
    var elements: [CGWindowID: AXUIElement] = [:]
    /// Last known minimized flag. CGWindowList cannot tell a minimized window
    /// from one on another Space, but AX told us the last time it answered.
    var minimized: [CGWindowID: Bool] = [:]

    /// Drops entries for windows that no longer exist.
    func pruned(to live: Set<CGWindowID>) -> WindowCaches {
        WindowCaches(titles: titles.filter { live.contains($0.key) },
                     elements: elements.filter { live.contains($0.key) },
                     minimized: minimized.filter { live.contains($0.key) })
    }
}

/// The result of one assembly: rows plus the updated caches.
struct AssembledScan {
    let windows: [WindowInfo]
    let appsWithoutWindows: [WindowInfo]
    let currentSpaceWindowIDs: Set<CGWindowID>
    /// Already pruned to windows that still exist.
    let caches: WindowCaches
}

enum WindowAssembly {
    /// Layer-0 windows on screen right now — i.e. on the current Space.
    static func currentSpace(_ facts: [CGWindowFact]) -> Set<CGWindowID> {
        Set(facts.filter { $0.layer == 0 && $0.isOnscreen }.map(\.id))
    }

    /// Turns one scan's raw inputs into rows.
    ///
    /// - Parameters:
    ///   - facts: every CGWindowList entry (`.optionAll`).
    ///   - metas: running apps, in enumeration order.
    ///   - scans: AX results by pid. A missing entry means the app was not
    ///     scanned (wicher itself) and is treated like a timeout.
    ///   - caches: per-window memory from previous scans.
    ///   - ownRows: wicher's own windows, read in-process from `NSApp`.
    ///   - screenSizes: display sizes, for spotting full-screen windows.
    ///   - selfPID: wicher's pid; its AX scan (if any) is ignored.
    static func assemble(facts: [CGWindowFact],
                         metas: [AppMeta],
                         scans: [pid_t: AppScan],
                         caches: WindowCaches,
                         ownRows: [WindowInfo],
                         screenSizes: [CGSize],
                         selfPID: pid_t) -> AssembledScan {
        var factByID: [CGWindowID: CGWindowFact] = [:]
        for fact in facts where factByID[fact.id] == nil { factByID[fact.id] = fact }
        let currentSpace = currentSpace(facts)
        let liveIDs = Set(facts.map(\.id))

        var caches = caches
        var windows: [WindowInfo] = []
        var emitted = Set<CGWindowID>()
        var appsWithAXWindows = Set<pid_t>()
        var appsWithWindows = Set<pid_t>()

        // 1) What AX reported.
        for meta in metas {
            // Our own windows come from `NSApp`, which — unlike AX — is not
            // limited to the active Space. Appended below.
            if meta.pid == selfPID { continue }
            guard let scan = scans[meta.pid], scan.answered else { continue }
            for window in scan.windows {
                if let wid = window.wid, let fact = factByID[wid], fact.isFullScreenShim { continue }
                if let wid = window.wid, emitted.contains(wid) { continue }

                // Prefer the live title; fall back to the last one we saw for
                // this window before the app went quiet.
                var title = window.title
                if title.isEmpty, let wid = window.wid, let cached = caches.titles[wid] { title = cached }

                if title.isEmpty && meta.name == "Unknown" { continue }

                windows.append(WindowInfo(pid: meta.pid,
                                          bundleID: meta.bundleID,
                                          appName: meta.name,
                                          appIcon: meta.icon,
                                          title: title,
                                          axWindow: window.element,
                                          isMinimized: window.minimized,
                                          isAppHidden: meta.isHidden,
                                          cgWindowID: window.wid,
                                          onCurrentSpace: spaceMembership(wid: window.wid,
                                                                          minimized: window.minimized,
                                                                          hidden: meta.isHidden,
                                                                          currentSpace: currentSpace)))
                appsWithAXWindows.insert(meta.pid)
                appsWithWindows.insert(meta.pid)
                if let wid = window.wid {
                    emitted.insert(wid)
                    caches.elements[wid] = window.element
                    caches.minimized[wid] = window.minimized
                    if !window.title.isEmpty { caches.titles[wid] = window.title }
                }
            }
        }

        // 2) Fallback for apps AX reported no windows for — a full-screen app on
        // another Space, a hidden app that declined to answer, or one that was
        // asleep and timed out. CGWindowList with `.optionAll` still knows those
        // windows exist, and the caches usually still know what they are called
        // and how to raise them.
        //
        // Must stay gated on `appsWithAXWindows`: an app AX *did* answer for
        // also owns off-screen layer-0 windows, and those would become phantom
        // rows.
        //
        // Ordered-out windows are skipped even with a cached title: AX titled
        // every tab of a group while it was selected (one row per tab once the
        // app is on another Space), and a closed-but-retained window stays
        // alive, so its cache entry would never be pruned. A minimized window
        // keeps its Space; the cache check only guards against that changing.
        for meta in metas where meta.name != "Unknown" && meta.pid != selfPID
            && !appsWithAXWindows.contains(meta.pid) {
            let candidates = facts.filter {
                $0.pid == meta.pid && $0.isPlausibleWindow && !emitted.contains($0.id)
                    && !($0.isOrderedOut && caches.minimized[$0.id] != true)
            }
            guard !candidates.isEmpty else { continue }

            // High confidence: on screen now, or a window we have previously
            // read a title from via AX. Those get a row each, with a real title
            // and (from the element cache) individual raise.
            let confident = candidates.filter { $0.isOnscreen || caches.titles[$0.id] != nil }
            // Guessing a stand-in row is only reasonable for a Dock app; an
            // agent app's off-screen window is far more likely to be chrome.
            let chosen = confident.isEmpty
                ? (meta.isRegular
                    ? [representativeWindow(among: candidates, screenSizes: screenSizes)].compactMap { $0 }
                    : [])
                : confident

            for fact in chosen {
                let minimized = caches.minimized[fact.id] ?? false
                windows.append(WindowInfo(pid: meta.pid,
                                          bundleID: meta.bundleID,
                                          appName: meta.name,
                                          appIcon: meta.icon,
                                          title: caches.titles[fact.id] ?? "",
                                          axWindow: caches.elements[fact.id],
                                          isMinimized: minimized,
                                          isAppHidden: meta.isHidden,
                                          cgWindowID: fact.id,
                                          onCurrentSpace: spaceMembership(wid: fact.id,
                                                                          minimized: minimized,
                                                                          hidden: meta.isHidden,
                                                                          currentSpace: currentSpace)))
                emitted.insert(fact.id)
                appsWithWindows.insert(meta.pid)
            }
        }

        // 3) wicher's own windows.
        for row in ownRows {
            windows.append(row)
            if let wid = row.cgWindowID { emitted.insert(wid) }
            appsWithWindows.insert(row.pid)
        }

        // 4) "Apps without windows" means exactly that: a Dock app for which
        // neither AX nor CGWindowList found a single window. Full-screen,
        // off-Space, hidden and minimized apps all produced rows above, so they
        // can never land here.
        let appsWithoutWindows = metas
            .filter { $0.isRegular && $0.pid != selfPID && !appsWithWindows.contains($0.pid) }
            .map { appOnlyRow(for: $0) }

        return AssembledScan(windows: windows,
                             appsWithoutWindows: appsWithoutWindows,
                             currentSpaceWindowIDs: currentSpace,
                             caches: caches.pruned(to: liveIDs))
    }

    /// The "Apps" entry for a running app with no windows.
    static func appOnlyRow(for meta: AppMeta) -> WindowInfo {
        WindowInfo(pid: meta.pid,
                   bundleID: meta.bundleID,
                   appName: meta.name,
                   appIcon: meta.icon,
                   title: meta.name,
                   axWindow: AXUIElementCreateApplication(meta.pid),
                   isMinimized: false,
                   isAppHidden: meta.isHidden,
                   isAppOnly: true)
    }

    /// Pick a single stand-in row for an app we can see only through
    /// CGWindowList and have never read a title from.
    ///
    /// Emitting every plausible window here would invent rows: an app with no
    /// AX answer still owns off-screen scratch windows that pass a size test.
    /// One row is enough to make the app reachable — activating it performs the
    /// Dock-click reopen, which is also what brings a full-screen Space forward.
    /// A display-sized window is the signature of exactly that case, so it wins;
    /// otherwise take the largest.
    static func representativeWindow(among candidates: [CGWindowFact],
                                     screenSizes: [CGSize]) -> CGWindowFact? {
        func isDisplaySized(_ fact: CGWindowFact) -> Bool {
            screenSizes.contains { abs($0.width - fact.size.width) < 2 && abs($0.height - fact.size.height) < 60 }
        }
        if let fullScreen = candidates.first(where: isDisplaySized) { return fullScreen }
        return candidates.max { $0.size.width * $0.size.height < $1.size.width * $1.size.height }
    }

    /// A minimized window, or one belonging to a hidden app, is not on screen
    /// anywhere — but it is not "on another Space" either, and treating it as
    /// such makes it vanish under the "Visible Spaces" filter. Count it as
    /// current, which is what a user expects and what Contexts shows.
    static func spaceMembership(wid: CGWindowID?,
                                minimized: Bool,
                                hidden: Bool,
                                currentSpace: Set<CGWindowID>) -> Bool {
        if minimized || hidden { return true }
        guard let wid else { return true }   // unknown id: never exclude
        return currentSpace.contains(wid)
    }
}
