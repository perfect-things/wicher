import AppKit
import ApplicationServices
import CoreGraphics

/// The windows discovered in one enumeration pass.
struct Enumeration {
    let windows: [WindowInfo]
    let appsWithoutWindows: [WindowInfo]
    let currentSpaceWindowIDs: Set<CGWindowID>
}

/// On-screen window facts read from CGWindowList (numbers/pids/bounds only —
/// no window *names*, so no Screen Recording permission is needed).
private struct CGWindowFact {
    let id: CGWindowID
    let pid: pid_t
    let order: Int        // front-to-back index within the current Space
}

/// Discovers switchable windows via the Accessibility API and keeps a
/// most-recently-used ordering — at window granularity where possible, falling
/// back to application granularity.
final class WindowEnumerator {
    static let shared = WindowEnumerator()

    /// Application pids, most-recently-active first.
    private var mruPIDs: [pid_t] = []

    /// Per-window recency: a monotonically increasing stamp per CGWindowID.
    /// Larger = more recently frontmost. Lets a quick ⌥Tab flip the two most
    /// recent *windows*, not just the two most recent apps.
    private var windowStamps: [CGWindowID: Int] = [:]
    private var clock = 0

    private init() {}

    // MARK: - MRU bookkeeping

    func noteActivated(pid: pid_t) {
        mruPIDs.removeAll { $0 == pid }
        mruPIDs.insert(pid, at: 0)
        // Record the app's current frontmost window as the most-recent window.
        if let wid = frontmostWindowID(ofPID: pid) { stampWindow(wid) }
    }

    /// Record that a specific window just became frontmost.
    func noteActivatedWindow(_ wid: CGWindowID, pid: pid_t) {
        noteActivated(pid: pid)
        stampWindow(wid)
    }

    private func stampWindow(_ wid: CGWindowID) {
        clock += 1
        windowStamps[wid] = clock
    }

    /// Refresh only the window stamp for `pid`'s current frontmost window,
    /// without touching the app MRU order. Called at session start so the
    /// window in front is rank 0 and the previous window is rank 1.
    func noteFrontmost(pid: pid_t) {
        if let wid = frontmostWindowID(ofPID: pid) { stampWindow(wid) }
    }

    func seedMRU() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != selfPID {
            noteActivated(pid: front.processIdentifier)
        }
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular
            && app.processIdentifier != selfPID
            && !mruPIDs.contains(app.processIdentifier) {
            mruPIDs.append(app.processIdentifier)
        }
    }

    // MARK: - Enumeration

    /// Enumerate current standard windows (plus app-only entries), ordered by
    /// window recency, then application MRU.
    func enumerate() -> Enumeration {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let cgFacts = onScreenWindowFacts()
        let currentSpace = Set(cgFacts.map { $0.id })
        // All on-screen window numbers at *any* layer, used to tell a real
        // (layer-0) window from a fullscreen system shim: a shim is on-screen
        // but not in `currentSpace` (which is layer-0 only).
        let onScreenAnyLayer = Set(onScreenWindowFactsAnyLayer().map { $0.id })

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && !$0.isTerminated
        }

        var windows: [WindowInfo] = []
        var appsWithoutWindows: [WindowInfo] = []
        // Apps for which AX returned at least one standard window. The
        // CGWindowList fallback must only fire for apps AX missed *entirely*,
        // otherwise a full-screen app (whose single AX window is already listed)
        // would gain phantom extra rows from its system/background CGWindows.
        var appsWithAXWindows = Set<pid_t>()
        var appsWithWindows = Set<pid_t>()

        for app in apps {
            let pid = app.processIdentifier
            let appName = app.localizedName ?? "Unknown"
            let axApp = AXUIElementCreateApplication(pid)
            // Don't let an unresponsive app stall enumeration, but allow enough
            // time that minimized/off-Space windows still report reliably.
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            var value: CFTypeRef?
            let axWindows: [AXUIElement]
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
               let list = value as? [AXUIElement] {
                axWindows = list
            } else {
                axWindows = []
            }

            for axWindow in axWindows {
                if let subrole = copyString(axWindow, kAXSubroleAttribute),
                   subrole != (kAXStandardWindowSubrole as String) {
                    continue
                }
                let title = copyString(axWindow, kAXTitleAttribute) ?? ""
                let minimized = copyBool(axWindow, kAXMinimizedAttribute) ?? false
                if title.isEmpty && appName == "Unknown" { continue }
                // Skip wicher's own chrome (the borderless HUD), but keep its
                // real titled windows such as Preferences.
                if pid == selfPID && title.isEmpty { continue }

                let wid = AXPrivate.windowID(of: axWindow)
                // Reject fullscreen system shims: an AX "standard" window whose
                // CGWindowID is on-screen but *not* at layer 0 is one of the
                // helper windows macOS creates for a fullscreen Space, not a
                // real window. (A genuine window on another Space is not
                // on-screen at all, so it is kept.)
                if let wid, onScreenAnyLayer.contains(wid), !currentSpace.contains(wid) {
                    continue
                }
                // If we cannot resolve a window id, assume current Space (don't
                // wrongly exclude it when "Visible Spaces" is selected).
                let onCurrentSpace = wid.map { currentSpace.contains($0) } ?? true

                windows.append(WindowInfo(pid: pid,
                                          bundleID: app.bundleIdentifier,
                                          appName: appName,
                                          appIcon: app.icon,
                                          title: title,
                                          axWindow: axWindow,
                                          isMinimized: minimized,
                                          isAppHidden: app.isHidden,
                                          cgWindowID: wid,
                                          onCurrentSpace: onCurrentSpace))
                appsWithAXWindows.insert(pid)
                appsWithWindows.insert(pid)
            }
        }

        // Fallback for apps AX reported *no* windows for at all — typically a
        // full-screen app living on another Space. Add exactly one representative
        // window so the app is switchable and not misfiled as "no windows". We
        // pick the frontmost layer-0 CGWindow the app owns. selfPID is allowed
        // here too, so wicher's own Preferences window surfaces when it lives on
        // another Space (AX only reports our windows on the active Space); the
        // borderless HUD never appears because it is not a layer-0 CGWindow.
        for app in apps {
            let pid = app.processIdentifier
            guard app.activationPolicy == .regular,
                  !appsWithAXWindows.contains(pid),
                  let fact = cgFacts.first(where: { $0.pid == pid })
            else { continue }
            let appName = app.localizedName ?? "Unknown"
            if appName == "Unknown" { continue }
            windows.append(WindowInfo(pid: pid,
                                      bundleID: app.bundleIdentifier,
                                      appName: appName,
                                      appIcon: app.icon,
                                      title: "",            // name needs Screen Recording; fall back to app name
                                      axWindow: nil,
                                      isMinimized: false,
                                      isAppHidden: app.isHidden,
                                      cgWindowID: fact.id,
                                      onCurrentSpace: true)) // present in the on-screen list
            appsWithWindows.insert(pid)
        }

        // "Apps without windows" lists only regular (Dock) apps that produced no
        // real window at all — so background agents and off-Space apps that we
        // *did* find windows for are never dumped here.
        for app in apps {
            let pid = app.processIdentifier
            guard app.activationPolicy == .regular,
                  pid != selfPID,
                  !appsWithWindows.contains(pid) else { continue }
            let appName = app.localizedName ?? "Unknown"
            appsWithoutWindows.append(WindowInfo(pid: pid,
                                                 bundleID: app.bundleIdentifier,
                                                 appName: appName,
                                                 appIcon: app.icon,
                                                 title: appName,
                                                 axWindow: AXUIElementCreateApplication(pid),
                                                 isMinimized: false,
                                                 isAppHidden: app.isHidden,
                                                 isAppOnly: true))
        }

        let ordered = windows.enumerated().sorted { lhs, rhs in
            // 1) window recency (more-recent first), 2) app MRU, 3) stable order.
            let wa = windowRank(lhs.element.cgWindowID)
            let wb = windowRank(rhs.element.cgWindowID)
            if wa != wb { return wa < wb }
            let a = mruRank(lhs.element.pid)
            let b = mruRank(rhs.element.pid)
            if a != b { return a < b }
            return lhs.offset < rhs.offset
        }.map { $0.element }

        let orderedApps = appsWithoutWindows.sorted { mruRank($0.pid) < mruRank($1.pid) }

        return Enumeration(windows: ordered,
                           appsWithoutWindows: orderedApps,
                           currentSpaceWindowIDs: currentSpace)
    }

    private func mruRank(_ pid: pid_t) -> Int { mruPIDs.firstIndex(of: pid) ?? Int.max }

    /// Lower rank = more recently frontmost. Windows we have never seen stamped
    /// sort after all stamped ones (so app-MRU then breaks the tie).
    private func windowRank(_ wid: CGWindowID?) -> Int {
        guard let wid, let stamp = windowStamps[wid] else { return Int.max }
        return -stamp  // larger stamp → smaller (earlier) rank
    }

    // MARK: - CGWindowList

    /// On-screen windows (current Space), front-to-back, with id + owner pid.
    /// Reading numbers/pids/layer/bounds does NOT require Screen Recording.
    private func onScreenWindowFacts() -> [CGWindowFact] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var facts: [CGWindowFact] = []
        for (index, info) in infos.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                  // Normal window layer only (0) — skip menus, the Dock, etc.
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0
            else { continue }
            facts.append(CGWindowFact(id: number, pid: owner, order: index))
        }
        return facts
    }

    /// On-screen windows at *any* layer (used to detect fullscreen shims, which
    /// are on-screen but not at layer 0).
    private func onScreenWindowFactsAnyLayer() -> [CGWindowFact] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var facts: [CGWindowFact] = []
        for (index, info) in infos.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t
            else { continue }
            facts.append(CGWindowFact(id: number, pid: owner, order: index))
        }
        return facts
    }

    /// The frontmost normal window id owned by `pid`, if any is on-screen.
    private func frontmostWindowID(ofPID pid: pid_t) -> CGWindowID? {
        onScreenWindowFacts().first { $0.pid == pid }?.id
    }

    // MARK: - AX attribute helpers

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? Bool
    }
}
