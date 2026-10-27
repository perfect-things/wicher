import AppKit
// AXObserver/AXUIElement predate Sendable; they cross to the main thread here.
@preconcurrency import ApplicationServices
import CoreGraphics

/// The windows discovered in one enumeration pass.
struct Enumeration {
    let windows: [WindowInfo]
    let appsWithoutWindows: [WindowInfo]
    let currentSpaceWindowIDs: Set<CGWindowID>
    /// Window bounds by id, in global display coordinates (see `CGWindowFact.origin`).
    let windowFrames: [CGWindowID: CGRect]

    static var empty: Enumeration {
        Enumeration(windows: [], appsWithoutWindows: [], currentSpaceWindowIDs: [], windowFrames: [:])
    }
}

extension NSWindow {
    /// This window's `CGWindowID`, or nil if it does not have one.
    ///
    /// `windowNumber` is an `Int`, and not every AppKit window has a number
    /// that is a real CGWindowID. A window with no backing device reports zero
    /// or negative, and the status-bar item's window reports 2^32 — positive,
    /// but out of `CGWindowID`'s range, so converting it unconditionally traps
    /// at runtime. Neither kind appears in CGWindowList, so nil is the right
    /// answer for both.
    var cgWindowID: CGWindowID? {
        guard windowNumber > 0 else { return nil }
        return CGWindowID(exactly: windowNumber)
    }
}

/// One of wicher's own windows, read in-process rather than through AX.
private struct SelfWindow {
    let number: CGWindowID
    let title: String
    let minimized: Bool
}

/// Which apps a background refresh must ask again.
private enum RefreshScope: Equatable {
    case none
    /// Only these; every other app keeps its last AX answer (`rescan`).
    case apps(Set<pid_t>)
    /// Every app (`performScan`).
    case all

    mutating func merge(_ other: RefreshScope) {
        switch other {
        case .none:
            return
        case .all:
            self = .all
        case let .apps(theirs):
            if case let .apps(mine) = self {
                self = .apps(mine.union(theirs))
            } else if self == .none {
                self = other
            }
        }
    }
}

/// An unordered scan result. MRU ordering is applied at read time, not here,
/// so a cached snapshot still reflects the newest recency stamps.
struct Snapshot {
    let windows: [WindowInfo]
    let appsWithoutWindows: [WindowInfo]
    let currentSpaceWindowIDs: Set<CGWindowID>
    let windowFrames: [CGWindowID: CGRect]
    let takenAt: Date
}

/// Discovers switchable windows via the Accessibility API and keeps a
/// most-recently-used ordering — at window granularity where possible, falling
/// back to application granularity.
///
/// Scanning is kept *off* the summon path: `start()` installs AX observers and
/// a low-frequency refresh so a snapshot is almost always warm, and
/// `enumerate()` serves that snapshot. An AX notification names the app it
/// came from, so most refreshes ask that one app again (`rescan`) and keep
/// every other app's last answer; only the safety timer, a Space or display
/// change, and a summon run the full pass. The cold path (no usable snapshot)
/// still scans synchronously, but queries every app in parallel rather than
/// serially.
///
/// Concurrency: `@unchecked Sendable`, synchronized by hand rather than by an
/// actor, because the summon path (`enumerate()`) must stay synchronous. State
/// is split two ways:
/// - main-actor: MRU, refresh machinery and the API callers use — marked
///   `@MainActor`, so the compiler checks it;
/// - lock-guarded (`lock`): the snapshot and caches, which `performScan`
///   writes from `scanQueue` and the main thread reads.
/// Scanning code (`performScan`, `scanApps`, `reconcile`) touches only the
/// lock-guarded half and immutable configuration.
///
/// The diagnostics report and the AX observers live in extensions in
/// `WindowEnumerator+Diagnostics.swift` and `WindowEnumerator+Observers.swift`;
/// what they touch is internal rather than private for that reason only.
final class WindowEnumerator: @unchecked Sendable {
    static let shared = WindowEnumerator()

    /// Posted on the main thread after a background scan replaces the snapshot.
    static let didRefresh = Notification.Name("WicherWindowEnumeratorDidRefresh")

    // MARK: - MRU state (main thread only)

    /// Application pids, most-recently-active first.
    @MainActor private var mruPIDs: [pid_t] = []

    /// Per-window recency: a monotonically increasing stamp per CGWindowID.
    /// Larger = more recently frontmost. Lets a quick ⌥Tab flip the two most
    /// recent *windows*, not just the two most recent apps.
    @MainActor private var windowStamps: [CGWindowID: Int] = [:]
    @MainActor private var clock = 0

    // MARK: - Snapshot + caches (lock-guarded, touched from the scan queue)

    let lock = NSLock()
    var snapshot: Snapshot?
    /// Per-window title / element / minimized memory; see `WindowCaches`.
    var caches = WindowCaches()
    /// Every app's AX answer from the last pass, so `rescan` can ask one app
    /// and rebuild the snapshot with the rest as they were.
    private var lastScans: [pid_t: AppScan] = [:]
    /// When `performScan` last ran. The safety timer keys off this, not the
    /// snapshot's age: per-app rescans keep the snapshot young, and the apps
    /// without observers need the full pass.
    private var fullScanAt: Date?
    /// `AppMeta` by pid from the last full pass, updated per app since; nil
    /// marks a process that is skipped (`.prohibited`). Every
    /// `NSRunningApplication` property read — `processIdentifier` included —
    /// is a LaunchServices round trip, ~0.1 ms, and `runningApplications`
    /// has a couple of hundred entries, so walking it costs ~20 ms. Only the
    /// full pass does; a rescan and `reconcile` work from this cache. See
    /// `runningMetas(refreshing:)`.
    private var metaCache: [pid_t: AppMeta?] = [:]
    /// App icons by bundle id (or pid, for the odd app without one).
    /// `NSRunningApplication.icon` is not free, and a scan runs every 2 s.
    private var iconCache: [String: NSImage] = [:]
    /// Display sizes, refreshed on the main thread — `NSScreen` is not safe to
    /// read from the scan queue.
    private var screenSizes: [CGSize] = []
    /// wicher's own windows, read from `NSApp` on the main thread.
    private var selfWindowsCache: [SelfWindow] = []

    // MARK: - Refresh machinery (main thread only)

    @MainActor var observers: [pid_t: AXObserver] = [:]
    @MainActor private var refreshTimer: Timer?
    @MainActor private var pendingRefresh: DispatchWorkItem?
    @MainActor private var refreshRequestedAt: Date?
    @MainActor private var refreshInFlight = false
    /// What the pending refresh must cover; grows as requests coalesce.
    @MainActor private var pendingScope = RefreshScope.none
    /// Requests that arrived during a scan, run after it.
    @MainActor private var refreshAgainScope = RefreshScope.none
    @MainActor private var suspended = false
    @MainActor private var started = false

    let scanQueue = DispatchQueue(label: "co.wicher.scan", qos: .userInitiated)
    private let workerQueue = DispatchQueue(label: "co.wicher.scan.workers",
                                            qos: .userInitiated,
                                            attributes: .concurrent)

    /// Safety-net full-scan cadence. AX observers drive per-app rescans; this
    /// catches apps whose observers never attached (and anything a
    /// notification missed) and keeps the next summon instant even after a
    /// long idle period. A full pass is ~200 AX round trips that wake napping
    /// apps, hence seconds rather than the two it used to be.
    private let refreshInterval: TimeInterval = 5.0
    /// How old a snapshot may be and still be served to a summon. Past the
    /// timer's cadence, so a quiet desktop never falls into a synchronous
    /// scan; `reconcile` covers what changed meanwhile.
    private var maxSnapshotAge: TimeInterval { refreshInterval + 2.5 }
    /// AX messaging timeout for background scans — generous, because nothing
    /// is waiting on them.
    let backgroundTimeout: TimeInterval = 1.0
    /// AX messaging timeout when a summon has to scan synchronously. Short, so
    /// one wedged app cannot stall the HUD; the title/AX caches cover whatever
    /// a timeout loses.
    private let foregroundTimeout: TimeInterval = 0.2
    /// AX messaging timeout for `reconcile`'s look at the frontmost app, which
    /// runs on every summon: a busy app (compiling, loading a page) must not
    /// hold the panel. `scanApp` gives up at the first timeout, so this bounds
    /// the wait at two round trips.
    private let reconcileTimeout: TimeInterval = 0.05

    /// Registered on each app element. Window destruction is not among them:
    /// `kAXUIElementDestroyedNotification` on an *app* element reports the
    /// app's own destruction, so it is registered per window instead (see
    /// `observeDestruction`).
    static let observedNotifications: [String] = [
        kAXWindowCreatedNotification,
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
    @MainActor func start() {
        guard !started else { return }
        started = true
        seedMRU()
        cacheScreenSizes()
        observeWorkspace()
        installObservers(for: NSWorkspace.shared.runningApplications)

        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfStale() }   // added to RunLoop.main
        }
        timer.tolerance = refreshInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        scheduleRefresh(after: 0)
    }

    /// Call when Accessibility trust arrives while running (it is lost on every
    /// ad-hoc rebuild). Observers that failed to attach without trust are
    /// retried, and the snapshot — built from CGWindowList alone, so untitled —
    /// is dropped instead of being served for another refresh cycle.
    @MainActor func accessibilityGranted() {
        installObservers(for: NSWorkspace.shared.runningApplications)
        lock.lock()
        snapshot = nil
        lock.unlock()
        scheduleRefresh(after: 0)
    }

    // MARK: - MRU bookkeeping

    @MainActor func noteActivated(pid: pid_t) {
        mruPIDs.removeAll { $0 == pid }
        mruPIDs.insert(pid, at: 0)
        // Record the app's current frontmost window as the most-recent window.
        if let wid = frontmostWindowID(ofPID: pid) { stampWindow(wid) }
        scheduleRefresh(pid: pid, after: 0.1)
    }

    /// Record that a specific window just became frontmost.
    @MainActor func noteActivatedWindow(_ wid: CGWindowID, pid: pid_t) {
        noteActivated(pid: pid)
        stampWindow(wid)
    }

    @MainActor private func stampWindow(_ wid: CGWindowID) {
        clock += 1
        windowStamps[wid] = clock
    }

    /// Refresh only the window stamp for `pid`'s current frontmost window,
    /// without touching the app MRU order. Called at session start so the
    /// window in front is rank 0 and the previous window is rank 1.
    @MainActor func noteFrontmost(pid: pid_t) {
        if let wid = frontmostWindowID(ofPID: pid) { stampWindow(wid) }
    }

    @MainActor func seedMRU() {
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
    @MainActor func enumerate() -> Enumeration {
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

    /// The latest snapshot, MRU-ordered, with no IPC and no refresh scheduled —
    /// for updating an already-open panel after `didRefresh`.
    @MainActor func latestSnapshot() -> Enumeration? {
        lock.lock()
        let cached = snapshot
        lock.unlock()
        return cached.map(order)
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
    /// Costs a few milliseconds, so it runs on every summon — and the one AX
    /// round trip is capped by `reconcileTimeout`, so a busy frontmost app
    /// cannot hold the panel; the snapshot then stands as it was.
    private func reconcile(_ snap: Snapshot) -> Snapshot {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let facts = windowFacts(resolvingSpaces: false)
        let live = Set(facts.map(\.id))

        // Hidden flags from the metadata cache (a hide/unhide refreshes its
        // app at once), minus apps that have quit. Not from
        // `runningApplications`: walking it is ~20 ms of LaunchServices round
        // trips, and this is the summon path. Only a frontmost app launched
        // since the last pass is read live — one app.
        lock.lock()
        let cachedMetas = metaCache
        let selfWindows = selfWindowsCache
        let cachedTitleIDs = Set(caches.titles.keys)
        lock.unlock()
        var hiddenByPID: [pid_t: Bool] = [:]
        for case let (pid, meta?) in cachedMetas where Self.isAlive(pid) { hiddenByPID[pid] = meta.isHidden }

        var front: (meta: AppMeta, scan: AppScan)?
        if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier, frontPID != selfPID {
            var meta = hiddenByPID[frontPID] != nil ? cachedMetas[frontPID] ?? nil : nil
            if meta == nil, let app = NSRunningApplication(processIdentifier: frontPID) {
                meta = Self.meta(of: app, pid: frontPID, icon: icon(for:))
            }
            if let meta {
                hiddenByPID[frontPID] = meta.isHidden
                front = (meta, Self.scanApp(pid: frontPID, timeout: reconcileTimeout))
            }
        }

        let reconciled = WindowAssembly.reconcile(
            windows: snap.windows,
            appsWithoutWindows: snap.appsWithoutWindows,
            facts: facts,
            hiddenByPID: hiddenByPID,
            front: front,
            ownRows: ownWindowRows(selfWindows, currentSpace: WindowAssembly.currentSpace(facts)),
            selfPID: selfPID)

        // Merge, don't overwrite: a background scan may have stored titles
        // since we read the cache, and they'd be lost until the next scan.
        // Only entries for windows seen closed here are dropped.
        lock.lock()
        caches.titles.merge(reconciled.freshTitles) { _, fresh in fresh }
        for wid in cachedTitleIDs where !live.contains(wid) { caches.titles[wid] = nil }
        lock.unlock()

        return Snapshot(windows: reconciled.windows,
                        appsWithoutWindows: reconciled.appsWithoutWindows,
                        currentSpaceWindowIDs: WindowAssembly.currentSpace(facts),
                        windowFrames: WindowAssembly.windowFrames(facts),
                        takenAt: snap.takenAt)
    }

    /// Applies the current MRU ordering to a snapshot.
    @MainActor private func order(_ snap: Snapshot) -> Enumeration {
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
                           currentSpaceWindowIDs: snap.currentSpaceWindowIDs,
                           windowFrames: snap.windowFrames)
    }

    @MainActor private func mruRank(_ pid: pid_t) -> Int { mruPIDs.firstIndex(of: pid) ?? Int.max }

    /// Lower rank = more recently frontmost. Windows we have never seen stamped
    /// sort after all stamped ones (so app-MRU then breaks the tie).
    @MainActor private func windowRank(_ wid: CGWindowID?) -> Int {
        guard let wid, let stamp = windowStamps[wid] else { return Int.max }
        return -stamp  // larger stamp → smaller (earlier) rank
    }

    // MARK: - Refresh scheduling

    /// Coalesced background refresh. Several callers (AX notifications, app
    /// activation, the summon path) ask for one at once; only one scan runs,
    /// covering the union of what they asked for — one app, a few, or all.
    @MainActor func scheduleRefresh(after delay: TimeInterval) {
        scheduleRefresh(.all, after: delay)
    }

    /// A refresh of `pid` alone (see `rescan`).
    @MainActor func scheduleRefresh(pid: pid_t, after delay: TimeInterval) {
        scheduleRefresh(.apps([pid]), after: delay)
    }

    /// `app` alone — or everything, when a notification named no app.
    @MainActor private func scheduleRefresh(app: NSRunningApplication?, after delay: TimeInterval) {
        scheduleRefresh(app.map { RefreshScope.apps([$0.processIdentifier]) } ?? .all, after: delay)
    }

    @MainActor private func scheduleRefresh(_ scope: RefreshScope, after delay: TimeInterval) {
        guard started, !suspended else { return }
        pendingScope.merge(scope)
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

    @MainActor private func refreshIfStale() {
        lock.lock()
        let age = fullScanAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        lock.unlock()
        if age >= refreshInterval { scheduleRefresh(after: 0) }
    }

    @MainActor private func runRefresh() {
        pendingRefresh = nil
        refreshRequestedAt = nil
        let scope = pendingScope
        pendingScope = .none
        guard !suspended, scope != .none else { return }
        // A notification that lands *during* a scan describes state that scan
        // may already have read past, so remember it and run again rather than
        // dropping the request on the floor.
        guard !refreshInFlight else { refreshAgainScope.merge(scope); return }
        refreshInFlight = true
        cacheSelfWindows()
        scanQueue.async { [weak self] in
            guard let self else { return }
            switch scope {
            case .all, .none: self.performScan(timeout: self.backgroundTimeout)
            case let .apps(pids): self.rescan(pids, timeout: self.backgroundTimeout)
            }
            DispatchQueue.main.async {
                self.refreshInFlight = false
                NotificationCenter.default.post(name: Self.didRefresh, object: self)
                let again = self.refreshAgainScope
                self.refreshAgainScope = .none
                if again != .none { self.scheduleRefresh(again, after: 0) }
            }
        }
    }

    // MARK: - Scanning

    /// One full AX + CGWindowList pass. Stores the result as the new snapshot
    /// and returns it. Safe to call from any thread.
    @discardableResult
    private func performScan(timeout: TimeInterval) -> Snapshot {
        let facts = windowFacts()
        let metas = runningMetas(refreshing: nil)
        let scans = scanApps(metas, timeout: timeout)
        let snap = assembleSnapshot(facts: facts, metas: metas, scans: scans)
        lock.lock()
        fullScanAt = snap.takenAt
        lock.unlock()
        return snap
    }

    /// Asks `pids` again — one app's worth of AX round trips, typically — and
    /// rebuilds the snapshot from fresh CGWindowList facts and every other
    /// app's last answer. Before any full pass has run there is nothing to
    /// reuse, so it runs one. Safe to call from any thread.
    @discardableResult
    private func rescan(_ pids: Set<pid_t>, timeout: TimeInterval) -> Snapshot {
        lock.lock()
        let previous = lastScans
        lock.unlock()
        guard !previous.isEmpty else { return performScan(timeout: timeout) }

        let facts = windowFacts()
        let metas = runningMetas(refreshing: pids)
        let fresh = scanApps(metas.filter { pids.contains($0.pid) }, timeout: timeout)
        // An app that quit drops out; one that just launched is in `fresh`.
        let running = Set(metas.map(\.pid))
        let scans = previous.filter { running.contains($0.key) }.merging(fresh) { _, new in new }
        return assembleSnapshot(facts: facts, metas: metas, scans: scans)
    }

    /// The running apps as flat `AppMeta`s, icons from the cache, in pid
    /// order (stable across passes, so rows don't shuffle under an open
    /// panel). `refreshing` nil — the full pass — walks `runningApplications`
    /// and reads every app afresh. A set — a rescan — reads just those apps
    /// and takes the rest from `metaCache`, dropping pids that have died
    /// (`isAlive`, no IPC). A hidden/unhidden app is always among the
    /// refreshed (see `observeWorkspace`); an app launched since the last
    /// full pass is picked up by its launch notification, or the next pass.
    private func runningMetas(refreshing pids: Set<pid_t>?) -> [AppMeta] {
        var fresh: [pid_t: AppMeta?] = [:]
        func read(_ app: NSRunningApplication, pid: pid_t) {
            fresh[pid] = .some(Self.meta(of: app, pid: pid, icon: icon(for:)))
        }
        if let pids {
            lock.lock()
            let cached = metaCache
            lock.unlock()
            for (pid, entry) in cached where !pids.contains(pid) && Self.isAlive(pid) { fresh[pid] = entry }
            for pid in pids {
                if let app = NSRunningApplication(processIdentifier: pid) { read(app, pid: pid) }
            }
        } else {
            for app in NSWorkspace.shared.runningApplications { read(app, pid: app.processIdentifier) }
        }
        lock.lock()
        metaCache = fresh
        lock.unlock()
        return fresh.keys.sorted().compactMap { fresh[$0] ?? nil }
    }

    /// `app` as an `AppMeta`, or nil for a process that is skipped
    /// (`.prohibited`, or gone). Several LaunchServices round trips.
    private static func meta(of app: NSRunningApplication, pid: pid_t,
                             icon: (NSRunningApplication) -> NSImage?) -> AppMeta? {
        guard app.activationPolicy != .prohibited, !app.isTerminated else { return nil }
        return AppMeta(pid: pid,
                       bundleID: app.bundleIdentifier,
                       name: app.localizedName ?? "Unknown",
                       icon: icon(app),
                       isHidden: app.isHidden,
                       isRegular: app.activationPolicy == .regular)
    }

    /// Whether `pid` is still running: a signal probe, no IPC. Pid reuse is
    /// covered by `didTerminateApplicationNotification` (`forget(pid:)`).
    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// An app quit: drop what the per-app caches know about its pid, before
    /// a new process can reuse it.
    @MainActor private func forget(pid: pid_t) {
        lock.lock()
        metaCache[pid] = nil
        lastScans[pid] = nil
        lock.unlock()
    }

    /// Classifies one pass's inputs and stores the result as the new snapshot.
    private func assembleSnapshot(facts: [CGWindowFact], metas: [AppMeta], scans: [pid_t: AppScan]) -> Snapshot {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        lock.lock()
        let previous = caches
        let selfWindows = selfWindowsCache
        let screenSizes = self.screenSizes
        lock.unlock()

        let assembled = WindowAssembly.assemble(
            facts: facts,
            metas: metas,
            scans: scans,
            caches: previous,
            ownRows: ownWindowRows(selfWindows, currentSpace: WindowAssembly.currentSpace(facts)),
            screenSizes: screenSizes,
            selfPID: selfPID)

        let snap = Snapshot(windows: assembled.windows,
                            appsWithoutWindows: assembled.appsWithoutWindows,
                            currentSpaceWindowIDs: assembled.currentSpaceWindowIDs,
                            windowFrames: assembled.windowFrames,
                            takenAt: Date())

        let running = Set(metas.map { $0.bundleID ?? "pid:\($0.pid)" })
        lock.lock()
        snapshot = snap
        caches = assembled.caches
        lastScans = scans
        iconCache = iconCache.filter { running.contains($0.key) }
        lock.unlock()

        return snap
    }

    /// The app's icon, cached by bundle id. Thread-safe.
    private func icon(for app: NSRunningApplication) -> NSImage? {
        let key = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        lock.lock()
        let cached = iconCache[key]
        lock.unlock()
        if let cached { return cached }
        guard let icon = app.icon else { return nil }
        lock.lock()
        iconCache[key] = icon
        lock.unlock()
        return icon
    }

    /// Query every app's AX window list in parallel. Serially this is the
    /// dominant cost of a summon: each app is an IPC round trip, and an app
    /// that has been idle (App Nap) can take hundreds of milliseconds to answer.
    private func scanApps(_ metas: [AppMeta], timeout: TimeInterval) -> [pid_t: AppScan] {
        guard !metas.isEmpty else { return [:] }
        nonisolated(unsafe) var results: [pid_t: AppScan] = [:]   // guarded by resultLock
        let resultLock = NSLock()
        let group = DispatchGroup()
        let gate = DispatchSemaphore(value: 16)

        let selfPID = ProcessInfo.processInfo.processIdentifier
        for meta in metas {
            if meta.pid == selfPID { continue }
            gate.wait()
            workerQueue.async(group: group) {
                let scan = Self.scanApp(pid: meta.pid, timeout: timeout)
                resultLock.lock()
                results[meta.pid] = scan
                resultLock.unlock()
                gate.signal()
            }
        }
        group.wait()
        return results
    }

    static func scanApp(pid: pid_t, timeout: TimeInterval) -> AppScan {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Float(timeout))

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement]
        else { return AppScan(windows: [], answered: false, responded: false) }

        var windows: [ScannedWindow] = []
        for element in list {
            // Each element carries its own timeout; set it rather than rely
            // on the app element's being inherited.
            AXUIElementSetMessagingTimeout(element, Float(timeout))
            let attrs = attributes(of: element)
            if attrs.error == .cannotComplete {
                // Timed out: the app is busy, and every window after this one
                // would wait as long. Give up now, as a timeout on the windows
                // list does, and let the caches and CGWindowList stand in.
                return AppScan(windows: [], answered: false, responded: false)
            }
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
        -> (subrole: String?, title: String?, minimized: Bool?, error: AXError) {
        let names = [kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute] as CFArray
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element,
                                                           names,
                                                           AXCopyMultipleAttributeOptions(rawValue: 0),
                                                           &values)
        guard error == .success, let array = values as? [AnyObject], array.count == 3
        else { return (nil, nil, nil, error == .success ? .failure : error) }
        // Attributes the element does not support come back as an AXValue error
        // placeholder, which simply fails the casts below.
        return (array[0] as? String, array[1] as? String, array[2] as? Bool, .success)
    }

    // MARK: - CGWindowList

    /// Every window in the session — on screen or not — with id, owner, layer
    /// and size. Reading those does NOT require Screen Recording; only
    /// `kCGWindowName` would.
    ///
    /// `resolvingSpaces` also sets `isOrderedOut` and `isInCurrentSpace` — one
    /// window-server call per plausible off-screen window plus one for the
    /// displays' current Spaces, so not on the summon path (`reconcile`).
    func windowFacts(resolvingSpaces: Bool = true) -> [CGWindowFact] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let currentSpaces = resolvingSpaces ? SpacesPrivate.currentSpaces() : nil
        var facts: [CGWindowFact] = []
        facts.reserveCapacity(infos.count)
        for (index, info) in infos.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int
            else { continue }
            var rect = CGRect.zero
            if let bounds = info[kCGWindowBounds as String] as? NSDictionary {
                rect = CGRect(dictionaryRepresentation: bounds) ?? .zero
            }
            var fact = CGWindowFact(id: number,
                                    pid: owner,
                                    layer: layer,
                                    isOnscreen: (info[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                                    order: index,
                                    size: rect.size,
                                    alpha: (info[kCGWindowAlpha as String] as? Double) ?? 1,
                                    origin: rect.origin)
            if resolvingSpaces, !fact.isOnscreen, fact.isPlausibleWindow {
                if let spaces = SpacesPrivate.spaces(of: number) {
                    fact.isOrderedOut = spaces.isEmpty
                    if let currentSpaces { fact.isInCurrentSpace = !spaces.isDisjoint(with: currentSpaces) }
                }
            }
            facts.append(fact)
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
    /// Settings vanished from the list whenever you switched away from the
    /// Space it was open on. In-process there is no such limit — `NSApp.windows`
    /// is every window we own, wherever it lives — and `windowNumber` is the
    /// same identifier CGWindowList uses, so Space membership still resolves.
    ///
    /// Main thread only; `NSApp` is not safe to read from the scan queue.
    @MainActor private func cacheSelfWindows() {
        let list: [SelfWindow] = NSApp.windows.compactMap { window in
            guard let number = window.cgWindowID,
                  !(window is SwitcherPanel),            // the borderless HUD
                  !window.title.isEmpty,
                  // Settings is kept alive after closing
                  // (`isReleasedWhenClosed = false`), so it stays in
                  // `NSApp.windows` and must be filtered out by visibility. A
                  // window on another Space is still "visible"; a minimized one
                  // is not, but belongs in the list.
                  window.isVisible || window.isMiniaturized
            else { return nil }
            return SelfWindow(number: number,
                              title: window.title,
                              minimized: window.isMiniaturized)
        }
        lock.lock()
        selfWindowsCache = list
        lock.unlock()
    }

    /// Read once: each property is a LaunchServices round trip.
    private static let selfApp: (pid: pid_t, bundleID: String?, name: String) = {
        let app = NSRunningApplication.current
        return (app.processIdentifier, app.bundleIdentifier, app.localizedName ?? "Wicher")
    }()

    private func ownWindowRows(_ windows: [SelfWindow], currentSpace: Set<CGWindowID>) -> [WindowInfo] {
        guard !windows.isEmpty else { return [] }
        let app = Self.selfApp
        return windows.map { window in
            WindowInfo(pid: app.pid,
                       bundleID: app.bundleID,
                       appName: app.name,
                       appIcon: icon(for: NSRunningApplication.current),
                       title: window.title,
                       axWindow: nil,               // activated in-process, see WindowActivator
                       isMinimized: window.minimized,
                       isAppHidden: false,
                       cgWindowID: window.number,
                       onCurrentSpace: WindowAssembly.spaceMembership(wid: window.number,
                                                       minimized: window.minimized,
                                                       hidden: false,
                                                       currentSpace: currentSpace))
        }
    }

    // MARK: - Watching the system

    @MainActor private func cacheScreenSizes() {
        let sizes = NSScreen.screens.map(\.frame.size)
        lock.lock()
        screenSizes = sizes
        lock.unlock()
    }

    @MainActor private func observeWorkspace() {
        observe(NSApplication.didChangeScreenParametersNotification, on: .default) { this, _ in
            this.cacheScreenSizes()
            this.scheduleRefresh(after: 0.1)
        }
        let center = NSWorkspace.shared.notificationCenter
        // One app changed: ask that app alone. A Space change moves every
        // app's windows on or off screen, and AX answers differ per Space,
        // so that one is a full pass.
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observe(name, on: center) { this, app in this.scheduleRefresh(app: app, after: 0) }
        }
        observe(NSWorkspace.activeSpaceDidChangeNotification, on: center) { this, _ in
            this.scheduleRefresh(after: 0.1)
        }
        observe(NSWorkspace.didLaunchApplicationNotification, on: center) { this, app in
            if let app { this.installObservers(for: [app]) }
            this.scheduleRefresh(app: app, after: 0.3)
        }
        observe(NSWorkspace.didTerminateApplicationNotification, on: center) { this, app in
            if let app {
                this.removeObserver(pid: app.processIdentifier)
                this.forget(pid: app.processIdentifier)
            }
            this.scheduleRefresh(app: app, after: 0.1)
        }
        // Don't poke every app while the display is asleep.
        observe(NSWorkspace.screensDidSleepNotification, on: center) { this, _ in this.suspended = true }
        observe(NSWorkspace.screensDidWakeNotification, on: center) { this, _ in
            this.suspended = false
            this.scheduleRefresh(after: 0)
        }
    }

    /// `addObserver(forName:object:queue: .main)`, with the block run on the
    /// main actor (which `.main` guarantees) and `self` held weakly. The
    /// handler gets the notification's app, if it names one.
    @MainActor private func observe(_ name: NSNotification.Name, on center: NotificationCenter,
                                    _ handler: @escaping @MainActor @Sendable (WindowEnumerator, NSRunningApplication?) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, app)
            }
        }
    }
}
