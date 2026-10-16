import AppKit
import ApplicationServices
import CoreGraphics

/// The windows discovered in one enumeration pass.
struct Enumeration {
    let windows: [WindowInfo]
    let appsWithoutWindows: [WindowInfo]
    let currentSpaceWindowIDs: Set<CGWindowID>

    static let empty = Enumeration(windows: [], appsWithoutWindows: [], currentSpaceWindowIDs: [])
}

/// Window facts read from CGWindowList — numbers/pids/layer/bounds only, never
/// `kCGWindowName`, so no Screen Recording permission is needed.
///
/// The list is taken with `.optionAll`, which includes windows that are *not*
/// on screen: minimized ones, windows of hidden apps, and windows living on
/// other Spaces (including full-screen Spaces). `isOnscreen` then tells the
/// current Space apart from the rest.
private struct CGWindowFact {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let isOnscreen: Bool
    let order: Int
    let size: CGSize
    let alpha: Double

    /// Could plausibly be a user-facing window.
    ///
    /// Every app owns a handful of layer-0 windows that are not: one 1728×33
    /// strip per display (menu-bar backing), 64×64 icon caches, and assorted
    /// off-screen scratch windows. The size floor rejects those; it is a
    /// *necessary*, not sufficient, test — see `representativeWindow`.
    var isPlausibleWindow: Bool {
        layer == 0 && alpha > 0.01 && size.width >= 200 && size.height >= 120
    }
}

/// Flat, thread-safe description of one running app, captured once per scan so
/// the parallel AX workers never touch `NSRunningApplication`.
private struct AppMeta {
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?
    let isHidden: Bool
    let isRegular: Bool
}

/// One window as the Accessibility API reported it.
private struct ScannedWindow {
    let element: AXUIElement
    let title: String
    let minimized: Bool
    let wid: CGWindowID?
}

/// One of wicher's own windows, read in-process rather than through AX.
private struct SelfWindow {
    let number: CGWindowID
    let title: String
    let minimized: Bool
}

private struct AppScan {
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

/// An unordered scan result. MRU ordering is applied at read time, not here,
/// so a cached snapshot still reflects the newest recency stamps.
private struct Snapshot {
    let windows: [WindowInfo]
    let appsWithoutWindows: [WindowInfo]
    let currentSpaceWindowIDs: Set<CGWindowID>
    let takenAt: Date
}

/// Discovers switchable windows via the Accessibility API and keeps a
/// most-recently-used ordering — at window granularity where possible, falling
/// back to application granularity.
///
/// Scanning is kept *off* the summon path: `start()` installs AX observers and
/// a low-frequency refresh so a snapshot is almost always warm, and
/// `enumerate()` serves that snapshot. The cold path (no usable snapshot) still
/// scans synchronously, but queries every app in parallel rather than serially.
final class WindowEnumerator {
    static let shared = WindowEnumerator()

    // MARK: - MRU state (main thread only)

    /// Application pids, most-recently-active first.
    private var mruPIDs: [pid_t] = []

    /// Per-window recency: a monotonically increasing stamp per CGWindowID.
    /// Larger = more recently frontmost. Lets a quick ⌥Tab flip the two most
    /// recent *windows*, not just the two most recent apps.
    private var windowStamps: [CGWindowID: Int] = [:]
    private var clock = 0

    // MARK: - Snapshot + caches (lock-guarded, touched from the scan queue)

    private let lock = NSLock()
    private var snapshot: Snapshot?
    /// Last known AX title per window. Survives an app going to sleep, so a
    /// hidden/off-Space window keeps its real title instead of decaying to the
    /// bare app name.
    private var titleCache: [CGWindowID: String] = [:]
    /// Display sizes, refreshed on the main thread — `NSScreen` is not safe to
    /// read from the scan queue.
    private var screenSizes: [CGSize] = []
    /// wicher's own windows, read from `NSApp` on the main thread.
    private var selfWindowsCache: [SelfWindow] = []
    /// Last known AX element per window, so a window we can currently only see
    /// via CGWindowList can still be raised individually.
    private var axCache: [CGWindowID: AXUIElement] = [:]
    /// Last known minimized flag per window. CGWindowList cannot tell a
    /// minimized window from a window on another Space, but AX told us the last
    /// time it answered — and it answers at the moment of minimizing, because
    /// `kAXWindowMiniaturized` triggers a refresh while the app is still awake.
    private var minimizedCache: [CGWindowID: Bool] = [:]

    // MARK: - Refresh machinery (main thread only)

    private var observers: [pid_t: AXObserver] = [:]
    private var refreshTimer: Timer?
    private var pendingRefresh: DispatchWorkItem?
    private var refreshRequestedAt: Date?
    private var refreshInFlight = false
    private var refreshAgain = false
    private var suspended = false
    private var started = false

    private let scanQueue = DispatchQueue(label: "co.wicher.scan", qos: .userInitiated)
    private let workerQueue = DispatchQueue(label: "co.wicher.scan.workers",
                                            qos: .userInitiated,
                                            attributes: .concurrent)

    /// How old a snapshot may be and still be served to a summon.
    private let maxSnapshotAge: TimeInterval = 2.5
    /// Safety-net refresh cadence. AX observers do most of the work; this
    /// catches apps whose observers never attached and keeps the next summon
    /// instant even after a long idle period.
    private let refreshInterval: TimeInterval = 2.0
    /// AX messaging timeout for background scans — generous, because nothing
    /// is waiting on them.
    private let backgroundTimeout: TimeInterval = 1.0
    /// AX messaging timeout when a summon has to scan synchronously. Short, so
    /// one wedged app cannot stall the HUD; the title/AX caches cover whatever
    /// a timeout loses.
    private let foregroundTimeout: TimeInterval = 0.2

    private static let observedNotifications: [String] = [
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXTitleChangedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]

    private init() {}

    // MARK: - Lifecycle

    /// Seed MRU, start watching the system, and warm the first snapshot.
    func start() {
        guard !started else { return }
        started = true
        seedMRU()
        cacheScreenSizes()
        observeWorkspace()
        installObservers(for: NSWorkspace.shared.runningApplications)

        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshIfStale()
        }
        timer.tolerance = refreshInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        scheduleRefresh(after: 0)
    }

    // MARK: - MRU bookkeeping

    func noteActivated(pid: pid_t) {
        mruPIDs.removeAll { $0 == pid }
        mruPIDs.insert(pid, at: 0)
        // Record the app's current frontmost window as the most-recent window.
        if let wid = frontmostWindowID(ofPID: pid) { stampWindow(wid) }
        scheduleRefresh(after: 0.1)
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

    // MARK: - Enumeration (the summon path)

    /// Current switchable windows (plus app-only entries), ordered by window
    /// recency, then application MRU.
    ///
    /// Serves the cached snapshot when one is fresh enough — that is what makes
    /// a summon instant regardless of how long wicher sat idle.
    func enumerate() -> Enumeration {
        cacheSelfWindows()
        lock.lock()
        let cached = snapshot
        lock.unlock()

        if let cached, Date().timeIntervalSince(cached.takenAt) < maxSnapshotAge {
            scheduleRefresh(after: 0)   // keep the next summon warm
            return order(reconcile(cached))
        }
        return order(performScan(timeout: foregroundTimeout))
    }

    /// Brings a cached snapshot up to date without a full AX pass.
    ///
    /// A snapshot can be two seconds old, and two seconds is plenty of time to
    /// close, minimize or hide the window you are about to switch away from —
    /// so the panel would open showing the state you just left behind. Most of
    /// what changes is readable *without* talking to other processes:
    /// CGWindowList knows which windows still exist and which are on this
    /// Space, and `NSRunningApplication` knows which apps are hidden. Only
    /// minimize needs AX, and only for the app you just acted on, which is
    /// frontmost and awake — one cheap round trip.
    ///
    /// Costs a few milliseconds, so it runs on every summon.
    private func reconcile(_ snap: Snapshot) -> Snapshot {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let facts = windowFacts()
        let currentSpace = Set(facts.filter { $0.layer == 0 && $0.isOnscreen }.map(\.id))
        let live = Set(facts.map(\.id))

        var hiddenByPID: [pid_t: Bool] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            hiddenByPID[app.processIdentifier] = app.isHidden
        }

        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var frontWindows: [CGWindowID: ScannedWindow] = [:]
        var frontIsAuthoritative = false
        if let frontPID, frontPID != selfPID, hiddenByPID[frontPID] != nil {
            let scan = Self.scanApp(pid: frontPID, timeout: foregroundTimeout)
            frontIsAuthoritative = scan.responded
            for window in scan.windows where window.wid != nil {
                frontWindows[window.wid!] = window
            }
        }

        lock.lock()
        let selfWindows = selfWindowsCache
        var titles = titleCache
        lock.unlock()

        var windows: [WindowInfo] = []
        var seen = Set<CGWindowID>()

        for window in snap.windows {
            guard let isHidden = hiddenByPID[window.pid] else { continue }  // app quit
            if let wid = window.cgWindowID, !live.contains(wid) { continue } // window closed

            var title = window.title
            var minimized = window.isMinimized
            var element = window.axWindow

            // wicher's own windows come from `NSApp`, never from the snapshot.
            if window.pid == selfPID { continue }

            // Only a window we can identify can be matched against the fresh
            // scan; without `_AXUIElementGetWindow` there are no ids at all, and
            // dropping every front-app window would be a poor way to degrade.
            if window.pid == frontPID, frontIsAuthoritative, let wid = window.cgWindowID {
                guard let fresh = frontWindows[wid] else { continue }
                minimized = fresh.minimized
                element = fresh.element
                if !fresh.title.isEmpty { title = fresh.title; titles[wid] = fresh.title }
            }

            if let wid = window.cgWindowID { seen.insert(wid) }
            windows.append(copy(window,
                                title: title,
                                element: element,
                                minimized: minimized,
                                hidden: isHidden,
                                onCurrentSpace: spaceMembership(wid: window.cgWindowID,
                                                                minimized: minimized,
                                                                hidden: isHidden,
                                                                currentSpace: currentSpace)))
        }

        // Windows the front app has opened since the snapshot was taken.
        if let frontPID, frontIsAuthoritative,
           let app = NSRunningApplication(processIdentifier: frontPID) {
            let isHidden = hiddenByPID[frontPID] ?? false
            for (wid, window) in frontWindows.sorted(by: { $0.key < $1.key }) where !seen.contains(wid) {
                guard !window.title.isEmpty else { continue }
                if let fact = facts.first(where: { $0.id == wid }), fact.isOnscreen, fact.layer != 0 {
                    continue    // full-screen shim, as in `performScan`
                }
                windows.append(WindowInfo(pid: frontPID,
                                          bundleID: app.bundleIdentifier,
                                          appName: app.localizedName ?? "Unknown",
                                          appIcon: app.icon,
                                          title: window.title,
                                          axWindow: window.element,
                                          isMinimized: window.minimized,
                                          isAppHidden: isHidden,
                                          cgWindowID: wid,
                                          onCurrentSpace: spaceMembership(wid: wid,
                                                                          minimized: window.minimized,
                                                                          hidden: isHidden,
                                                                          currentSpace: currentSpace)))
                titles[wid] = window.title
            }
        }

        windows.append(contentsOf: ownWindowRows(selfWindows, currentSpace: currentSpace))

        // An app whose last window just closed belongs under "Apps"; one that
        // just opened its first must leave it.
        let pidsWithWindows = Set(windows.map(\.pid))
        var appsWithoutWindows = snap.appsWithoutWindows.compactMap { entry -> WindowInfo? in
            guard let isHidden = hiddenByPID[entry.pid], !pidsWithWindows.contains(entry.pid) else { return nil }
            return copy(entry, title: entry.title, element: entry.axWindow,
                        minimized: false, hidden: isHidden, onCurrentSpace: true)
        }
        if let frontPID, frontIsAuthoritative, !pidsWithWindows.contains(frontPID),
           !appsWithoutWindows.contains(where: { $0.pid == frontPID }),
           let app = NSRunningApplication(processIdentifier: frontPID),
           app.activationPolicy == .regular, let name = app.localizedName {
            appsWithoutWindows.append(WindowInfo(pid: frontPID,
                                                 bundleID: app.bundleIdentifier,
                                                 appName: name,
                                                 appIcon: app.icon,
                                                 title: name,
                                                 axWindow: AXUIElementCreateApplication(frontPID),
                                                 isMinimized: false,
                                                 isAppHidden: app.isHidden,
                                                 isAppOnly: true))
        }

        lock.lock()
        titleCache = titles.filter { live.contains($0.key) }
        lock.unlock()

        return Snapshot(windows: windows,
                        appsWithoutWindows: appsWithoutWindows,
                        currentSpaceWindowIDs: currentSpace,
                        takenAt: snap.takenAt)
    }

    /// `WindowInfo` is immutable, so updating a flag means rebuilding it.
    private func copy(_ info: WindowInfo,
                      title: String,
                      element: AXUIElement?,
                      minimized: Bool,
                      hidden: Bool,
                      onCurrentSpace: Bool) -> WindowInfo {
        WindowInfo(pid: info.pid,
                   bundleID: info.bundleID,
                   appName: info.appName,
                   appIcon: info.appIcon,
                   title: title,
                   axWindow: element,
                   isMinimized: minimized,
                   isAppHidden: hidden,
                   isAppOnly: info.isAppOnly,
                   cgWindowID: info.cgWindowID,
                   onCurrentSpace: onCurrentSpace)
    }

    /// Applies the current MRU ordering to a snapshot.
    private func order(_ snap: Snapshot) -> Enumeration {
        let ordered = snap.windows.enumerated().sorted { lhs, rhs in
            // 1) window recency (more-recent first), 2) app MRU, 3) stable order.
            let wa = windowRank(lhs.element.cgWindowID)
            let wb = windowRank(rhs.element.cgWindowID)
            if wa != wb { return wa < wb }
            let a = mruRank(lhs.element.pid)
            let b = mruRank(rhs.element.pid)
            if a != b { return a < b }
            return lhs.offset < rhs.offset
        }.map { $0.element }

        let orderedApps = snap.appsWithoutWindows.sorted { mruRank($0.pid) < mruRank($1.pid) }
        return Enumeration(windows: ordered,
                           appsWithoutWindows: orderedApps,
                           currentSpaceWindowIDs: snap.currentSpaceWindowIDs)
    }

    private func mruRank(_ pid: pid_t) -> Int { mruPIDs.firstIndex(of: pid) ?? Int.max }

    /// Lower rank = more recently frontmost. Windows we have never seen stamped
    /// sort after all stamped ones (so app-MRU then breaks the tie).
    private func windowRank(_ wid: CGWindowID?) -> Int {
        guard let wid, let stamp = windowStamps[wid] else { return Int.max }
        return -stamp  // larger stamp → smaller (earlier) rank
    }

    // MARK: - Refresh scheduling

    /// Coalesced background refresh. Several callers (AX notifications, app
    /// activation, the summon path) ask for one at once; only one scan runs.
    private func scheduleRefresh(after delay: TimeInterval) {
        guard started, !suspended else { return }
        // A chatty app (title changes while you type) would otherwise push the
        // pending refresh out forever. Once a request has waited this long, let
        // it run instead of rescheduling it again.
        if let first = refreshRequestedAt, Date().timeIntervalSince(first) > 0.5, pendingRefresh != nil {
            return
        }
        if pendingRefresh == nil { refreshRequestedAt = Date() }
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runRefresh() }
        pendingRefresh = work
        if delay <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func refreshIfStale() {
        lock.lock()
        let age = snapshot.map { Date().timeIntervalSince($0.takenAt) } ?? .greatestFiniteMagnitude
        lock.unlock()
        if age >= refreshInterval { scheduleRefresh(after: 0) }
    }

    private func runRefresh() {
        pendingRefresh = nil
        refreshRequestedAt = nil
        guard !suspended else { return }
        // A notification that lands *during* a scan describes state that scan
        // may already have read past, so remember it and run again rather than
        // dropping the request on the floor.
        guard !refreshInFlight else { refreshAgain = true; return }
        refreshInFlight = true
        cacheSelfWindows()
        scanQueue.async { [weak self] in
            guard let self else { return }
            _ = self.performScan(timeout: self.backgroundTimeout)
            DispatchQueue.main.async {
                self.refreshInFlight = false
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.scheduleRefresh(after: 0)
                }
            }
        }
    }

    // MARK: - Scanning

    /// One full AX + CGWindowList pass. Stores the result as the new snapshot
    /// and returns it. Safe to call from any thread.
    @discardableResult
    private func performScan(timeout: TimeInterval) -> Snapshot {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let facts = windowFacts()
        var factByID: [CGWindowID: CGWindowFact] = [:]
        for fact in facts where factByID[fact.id] == nil { factByID[fact.id] = fact }
        let currentSpace = Set(facts.filter { $0.layer == 0 && $0.isOnscreen }.map(\.id))
        let liveIDs = Set(facts.map(\.id))

        let metas = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited && !$0.isTerminated }
            .map {
                AppMeta(pid: $0.processIdentifier,
                        bundleID: $0.bundleIdentifier,
                        name: $0.localizedName ?? "Unknown",
                        icon: $0.icon,
                        isHidden: $0.isHidden,
                        isRegular: $0.activationPolicy == .regular)
            }

        let scans = scanApps(metas, timeout: timeout)

        lock.lock()
        var titles = titleCache
        var elements = axCache
        var minimizedStates = minimizedCache
        lock.unlock()

        var windows: [WindowInfo] = []
        var emitted = Set<CGWindowID>()
        var appsWithAXWindows = Set<pid_t>()
        var appsWithWindows = Set<pid_t>()

        for (index, meta) in metas.enumerated() {
            // Our own windows come from `NSApp`, which — unlike AX — is not
            // limited to the active Space. Appended after this loop.
            if meta.pid == selfPID { continue }
            guard let scan = scans[index], scan.answered else { continue }
            for window in scan.windows {
                // Reject full-screen system shims: an AX "standard" window whose
                // CGWindowID is on screen but *not* at layer 0 is one of the
                // helper windows macOS makes for a full-screen Space, not a real
                // window. A genuine window on another Space is not on screen at
                // all, so it survives this test.
                if let wid = window.wid, let fact = factByID[wid], fact.isOnscreen, fact.layer != 0 {
                    continue
                }
                if let wid = window.wid, emitted.contains(wid) { continue }

                // Prefer the live title; fall back to the last one we saw for
                // this window before the app went quiet.
                var title = window.title
                if title.isEmpty, let wid = window.wid, let cached = titles[wid] { title = cached }

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
                    elements[wid] = window.element
                    minimizedStates[wid] = window.minimized
                    if !window.title.isEmpty { titles[wid] = window.title }
                }
            }
        }

        // Fallback for apps AX reported no windows for — a full-screen app on
        // another Space, a hidden app that declined to answer, or one that was
        // asleep and timed out. CGWindowList with `.optionAll` still knows those
        // windows exist, and the title/element caches usually still know what
        // they are called and how to raise them.
        lock.lock()
        let screenSizes = self.screenSizes
        lock.unlock()
        for meta in metas where meta.name != "Unknown" && meta.pid != selfPID
            && !appsWithAXWindows.contains(meta.pid) {
            let candidates = facts.filter { $0.pid == meta.pid && $0.isPlausibleWindow && !emitted.contains($0.id) }
            guard !candidates.isEmpty else { continue }

            // High confidence: on screen now, or a window we have previously
            // read a title from via AX. Those get a row each, with a real title
            // and (from the element cache) individual raise.
            let confident = candidates.filter { $0.isOnscreen || titles[$0.id] != nil }
            // Guessing a stand-in row is only reasonable for a Dock app; an
            // agent app's off-screen window is far more likely to be chrome.
            let chosen = confident.isEmpty
                ? (meta.isRegular
                    ? [representativeWindow(among: candidates, screenSizes: screenSizes)].compactMap { $0 }
                    : [])
                : confident
            guard !chosen.isEmpty else { continue }

            for fact in chosen {
                let minimized = minimizedStates[fact.id] ?? false
                windows.append(WindowInfo(pid: meta.pid,
                                          bundleID: meta.bundleID,
                                          appName: meta.name,
                                          appIcon: meta.icon,
                                          title: titles[fact.id] ?? "",
                                          axWindow: elements[fact.id],
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

        lock.lock()
        let selfWindows = selfWindowsCache
        lock.unlock()
        for row in ownWindowRows(selfWindows, currentSpace: currentSpace) {
            windows.append(row)
            if let wid = row.cgWindowID { emitted.insert(wid) }
            appsWithWindows.insert(row.pid)
        }

        // "Apps without windows" now means exactly that: a Dock app for which
        // neither AX nor CGWindowList found a single window. Full-screen,
        // off-Space, hidden and minimized apps all produced rows above, so they
        // can never land here.
        var appsWithoutWindows: [WindowInfo] = []
        for meta in metas where meta.isRegular && meta.pid != selfPID && !appsWithWindows.contains(meta.pid) {
            appsWithoutWindows.append(WindowInfo(pid: meta.pid,
                                                 bundleID: meta.bundleID,
                                                 appName: meta.name,
                                                 appIcon: meta.icon,
                                                 title: meta.name,
                                                 axWindow: AXUIElementCreateApplication(meta.pid),
                                                 isMinimized: false,
                                                 isAppHidden: meta.isHidden,
                                                 isAppOnly: true))
        }

        let snap = Snapshot(windows: windows,
                            appsWithoutWindows: appsWithoutWindows,
                            currentSpaceWindowIDs: currentSpace,
                            takenAt: Date())

        lock.lock()
        snapshot = snap
        titleCache = titles.filter { liveIDs.contains($0.key) }
        axCache = elements.filter { liveIDs.contains($0.key) }
        minimizedCache = minimizedStates.filter { liveIDs.contains($0.key) }
        lock.unlock()

        return snap
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
    private func representativeWindow(among candidates: [CGWindowFact],
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
    private func spaceMembership(wid: CGWindowID?,
                                 minimized: Bool,
                                 hidden: Bool,
                                 currentSpace: Set<CGWindowID>) -> Bool {
        if minimized || hidden { return true }
        guard let wid else { return true }   // unknown id: never exclude
        return currentSpace.contains(wid)
    }

    /// Query every app's AX window list in parallel. Serially this is the
    /// dominant cost of a summon: each app is an IPC round trip, and an app
    /// that has been idle (App Nap) can take hundreds of milliseconds to answer.
    private func scanApps(_ metas: [AppMeta], timeout: TimeInterval) -> [Int: AppScan] {
        guard !metas.isEmpty else { return [:] }
        var results: [Int: AppScan] = [:]
        let resultLock = NSLock()
        let group = DispatchGroup()
        let gate = DispatchSemaphore(value: 16)

        let selfPID = ProcessInfo.processInfo.processIdentifier
        for (index, meta) in metas.enumerated() {
            if meta.pid == selfPID { continue }
            gate.wait()
            workerQueue.async(group: group) {
                let scan = Self.scanApp(pid: meta.pid, timeout: timeout)
                resultLock.lock()
                results[index] = scan
                resultLock.unlock()
                gate.signal()
            }
        }
        group.wait()
        return results
    }

    private static func scanApp(pid: pid_t, timeout: TimeInterval) -> AppScan {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Float(timeout))

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement]
        else { return AppScan(windows: [], answered: false, responded: false) }

        var windows: [ScannedWindow] = []
        for element in list {
            let attrs = attributes(of: element)
            // Only standard windows; sheets, drawers and popovers are not
            // switch targets. A missing subrole is treated as standard.
            if let subrole = attrs.subrole, subrole != (kAXStandardWindowSubrole as String) { continue }
            windows.append(ScannedWindow(element: element,
                                         title: attrs.title ?? "",
                                         minimized: attrs.minimized ?? false,
                                         wid: AXPrivate.windowID(of: element)))
        }
        return AppScan(windows: windows, answered: !windows.isEmpty, responded: true)
    }

    /// Subrole, title and minimized state in a *single* AX round trip rather
    /// than three. Cuts per-window IPC by two thirds, which is the second
    /// biggest term in scan latency after per-app parallelism.
    private static func attributes(of element: AXUIElement)
        -> (subrole: String?, title: String?, minimized: Bool?) {
        let names = [kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element,
                                                     names,
                                                     AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &values) == .success,
              let array = values as? [AnyObject], array.count == 3
        else { return (nil, nil, nil) }
        // Attributes the element does not support come back as an AXValue error
        // placeholder, which simply fails the casts below.
        return (array[0] as? String, array[1] as? String, array[2] as? Bool)
    }

    // MARK: - CGWindowList

    /// Every window in the session — on screen or not — with id, owner, layer
    /// and size. Reading those does NOT require Screen Recording; only
    /// `kCGWindowName` would.
    private func windowFacts() -> [CGWindowFact] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var facts: [CGWindowFact] = []
        facts.reserveCapacity(infos.count)
        for (index, info) in infos.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int
            else { continue }
            var size = CGSize.zero
            if let bounds = info[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: bounds) {
                size = rect.size
            }
            facts.append(CGWindowFact(id: number,
                                      pid: owner,
                                      layer: layer,
                                      isOnscreen: (info[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                                      order: index,
                                      size: size,
                                      alpha: (info[kCGWindowAlpha as String] as? Double) ?? 1))
        }
        return facts
    }

    /// The frontmost normal window id owned by `pid`, if any is on screen.
    private func frontmostWindowID(ofPID pid: pid_t) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in infos {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0
            else { continue }
            return number
        }
        return nil
    }

    // MARK: - wicher's own windows

    /// Snapshot the app's own windows straight from `NSApp`.
    ///
    /// Asking the Accessibility API about our own process is both wasteful and
    /// unreliable: AX reports an app's windows on the *active* Space, so
    /// Preferences vanished from the list whenever you switched away from the
    /// Space it was open on. In-process there is no such limit — `NSApp.windows`
    /// is every window we own, wherever it lives — and `windowNumber` is the
    /// same identifier CGWindowList uses, so Space membership still resolves.
    ///
    /// Main thread only; `NSApp` is not safe to read from the scan queue.
    private func cacheSelfWindows() {
        let list: [SelfWindow] = NSApp.windows.compactMap { window in
            guard window.windowNumber > 0,
                  !(window is SwitcherPanel),            // the borderless HUD
                  !window.title.isEmpty,
                  // Preferences is kept alive after closing
                  // (`isReleasedWhenClosed = false`), so it stays in
                  // `NSApp.windows` and must be filtered out by visibility. A
                  // window on another Space is still "visible"; a minimized one
                  // is not, but belongs in the list.
                  window.isVisible || window.isMiniaturized
            else { return nil }
            return SelfWindow(number: CGWindowID(window.windowNumber),
                              title: window.title,
                              minimized: window.isMiniaturized)
        }
        lock.lock()
        selfWindowsCache = list
        lock.unlock()
    }

    private func ownWindowRows(_ windows: [SelfWindow], currentSpace: Set<CGWindowID>) -> [WindowInfo] {
        guard !windows.isEmpty else { return [] }
        let app = NSRunningApplication.current
        let name = app.localizedName ?? "Wicher"
        return windows.map { window in
            WindowInfo(pid: app.processIdentifier,
                       bundleID: app.bundleIdentifier,
                       appName: name,
                       appIcon: app.icon,
                       title: window.title,
                       axWindow: nil,               // activated in-process, see WindowActivator
                       isMinimized: window.minimized,
                       isAppHidden: false,
                       cgWindowID: window.number,
                       onCurrentSpace: spaceMembership(wid: window.number,
                                                       minimized: window.minimized,
                                                       hidden: false,
                                                       currentSpace: currentSpace))
        }
    }

    // MARK: - Diagnostics

    /// A human-readable dump of what AX and CGWindowList each report, per app.
    ///
    /// Window enumeration on macOS is mostly undocumented behavior, and the
    /// interesting cases (a hidden app, a full-screen app on another Space) are
    /// exactly the ones that cannot be reproduced from a shell. This is how to
    /// see the ground truth on a real machine: menu bar → Copy Diagnostics.
    func diagnosticsReport() -> String {
        var out = ""
        out += "wicher diagnostics — \(Date())\n"
        out += "AXIsProcessTrusted: \(AXIsProcessTrusted())\n"
        out += "_AXUIElementGetWindow available: \(AXPrivate.isAvailable)\n"

        let facts = windowFacts()
        var byPID: [pid_t: [CGWindowFact]] = [:]
        for fact in facts { byPID[fact.pid, default: []].append(fact) }
        out += "CGWindowList(.optionAll) entries: \(facts.count), onscreen: \(facts.filter(\.isOnscreen).count)\n"

        lock.lock()
        let age = snapshot.map { Date().timeIntervalSince($0.takenAt) }
        let cachedTitles = titleCache.count
        lock.unlock()
        out += "snapshot age: \(age.map { String(format: "%.2fs", $0) } ?? "none"), cached titles: \(cachedTitles)\n\n"

        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
        for app in apps {
            let pid = app.processIdentifier
            let started = Date()
            let scan = Self.scanApp(pid: pid, timeout: backgroundTimeout)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            out += "── \(app.localizedName ?? "?") pid=\(pid) hidden=\(app.isHidden) "
            out += "axWindows=\(scan.windows.count) answered=\(scan.answered) responded=\(scan.responded) [\(ms)ms]\n"
            for window in scan.windows {
                let fact = window.wid.flatMap { wid in facts.first { $0.id == wid } }
                out += "    AX wid=\(window.wid.map(String.init) ?? "-") min=\(window.minimized) "
                out += "layer=\(fact.map { String($0.layer) } ?? "-") on=\(fact.map { String($0.isOnscreen) } ?? "-") "
                out += "size=\(fact.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "-") "
                out += "title=\"\(window.title)\"\n"
            }
            let axIDs = Set(scan.windows.compactMap(\.wid))
            for fact in (byPID[pid] ?? []) where fact.layer == 0 && !axIDs.contains(fact.id) {
                out += "    CG-only wid=\(fact.id) on=\(fact.isOnscreen) "
                out += "size=\(Int(fact.size.width))x\(Int(fact.size.height)) alpha=\(fact.alpha) "
                out += "plausible=\(fact.isPlausibleWindow)\n"
            }
        }
        return out
    }

    // MARK: - Watching the system

    private func cacheScreenSizes() {
        let sizes = NSScreen.screens.map(\.frame.size)
        lock.lock()
        screenSizes = sizes
        lock.unlock()
    }

    private func observeWorkspace() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.cacheScreenSizes()
            self?.scheduleRefresh(after: 0.1)
        }
        let center = NSWorkspace.shared.notificationCenter
        let refreshing: [NSNotification.Name] = [
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in refreshing {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh(after: 0.1)
            }
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.installObservers(for: [app])
            }
            self?.scheduleRefresh(after: 0.3)
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.removeObserver(pid: app.processIdentifier)
            }
            self?.scheduleRefresh(after: 0.1)
        }
        // Don't poke every app while the display is asleep.
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.suspended = true
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.suspended = false
            self?.scheduleRefresh(after: 0)
        }
    }

    // MARK: - AX observers

    private static let observerCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let enumerator = Unmanaged<WindowEnumerator>.fromOpaque(refcon).takeUnretainedValue()
        enumerator.scheduleRefresh(after: 0.15)
    }

    private func installObservers(for apps: [NSRunningApplication]) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let pids = apps
            .filter { $0.activationPolicy != .prohibited && !$0.isTerminated && $0.processIdentifier != selfPID }
            .map(\.processIdentifier)
            .filter { observers[$0] == nil }
        guard !pids.isEmpty else { return }

        // Attaching to a sleeping app can block, so do it off the main thread.
        scanQueue.async { [weak self] in
            guard let self else { return }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for pid in pids {
                var observer: AXObserver?
                guard AXObserverCreate(pid, Self.observerCallback, &observer) == .success,
                      let observer else { continue }
                let axApp = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(axApp, Float(self.backgroundTimeout))
                var attached = false
                for name in Self.observedNotifications {
                    if AXObserverAddNotification(observer, axApp, name as CFString, refcon) == .success {
                        attached = true
                    }
                }
                guard attached else { continue }
                DispatchQueue.main.async {
                    guard self.observers[pid] == nil else { return }
                    self.observers[pid] = observer
                    CFRunLoopAddSource(CFRunLoopGetMain(),
                                       AXObserverGetRunLoopSource(observer),
                                       .defaultMode)
                }
            }
        }
    }

    private func removeObserver(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              AXObserverGetRunLoopSource(observer),
                              .defaultMode)
    }
}
