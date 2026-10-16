import ApplicationServices
import XCTest
@testable import WicherCore

/// The classification table from code-review §1.1, plus the guards around the
/// CGWindowList fallback. Every reported enumeration bug lived in this logic.
final class WindowAssemblyTests: XCTestCase {
    private let selfPID: pid_t = 999
    private let screen = CGSize(width: 1728, height: 1117)

    // MARK: - Builders

    private func meta(_ pid: pid_t, _ name: String, hidden: Bool = false, regular: Bool = true) -> AppMeta {
        AppMeta(pid: pid, bundleID: "test.\(name)", name: name, icon: nil, isHidden: hidden, isRegular: regular)
    }

    private func fact(_ id: CGWindowID, pid: pid_t, onscreen: Bool = true, layer: Int = 0,
                      size: CGSize = CGSize(width: 800, height: 600)) -> CGWindowFact {
        CGWindowFact(id: id, pid: pid, layer: layer, isOnscreen: onscreen, order: Int(id), size: size, alpha: 1)
    }

    private func ax(_ wid: CGWindowID?, _ title: String, minimized: Bool = false) -> ScannedWindow {
        ScannedWindow(element: AXUIElementCreateApplication(1), title: title, minimized: minimized, wid: wid)
    }

    private func answered(_ windows: [ScannedWindow]) -> AppScan {
        AppScan(windows: windows, answered: !windows.isEmpty, responded: true)
    }

    private let timedOut = AppScan(windows: [], answered: false, responded: false)

    private func assemble(facts: [CGWindowFact],
                          metas: [AppMeta],
                          scans: [pid_t: AppScan],
                          caches: WindowCaches = WindowCaches(),
                          ownRows: [WindowInfo] = []) -> AssembledScan {
        WindowAssembly.assemble(facts: facts, metas: metas, scans: scans, caches: caches,
                                ownRows: ownRows, screenSizes: [screen], selfPID: selfPID)
    }

    private func titles(_ scan: AssembledScan) -> [String] { scan.windows.map(\.displayTitle) }
    private func appNames(_ scan: AssembledScan) -> [String] { scan.appsWithoutWindows.map(\.appName) }

    // MARK: - §1.1 classification table

    func testAppWithGenuinelyNoWindowsIsAppOnly() {
        let r = assemble(facts: [], metas: [meta(1, "Finder")], scans: [1: answered([])])
        XCTAssertEqual(titles(r), [])
        XCTAssertEqual(appNames(r), ["Finder"])
    }

    func testFullScreenAppOnAnotherSpaceGetsARowNotAppOnly() {
        // AX says nothing (other Space), CGWindowList has a display-sized,
        // off-screen window plus off-screen scratch windows.
        let r = assemble(facts: [fact(10, pid: 1, onscreen: false, size: screen),
                                 fact(11, pid: 1, onscreen: false, size: CGSize(width: 500, height: 500))],
                         metas: [meta(1, "Zen")],
                         scans: [1: timedOut])
        XCTAssertEqual(r.windows.map(\.cgWindowID), [10], "one stand-in, the display-sized one")
        XCTAssertEqual(appNames(r), [])
    }

    func testHiddenAppThatTimedOutKeepsCachedTitles() {
        var caches = WindowCaches()
        caches.titles[20] = "Inbox — Mail"
        caches.titles[21] = "Drafts"
        let r = assemble(facts: [fact(20, pid: 2, onscreen: false), fact(21, pid: 2, onscreen: false)],
                         metas: [meta(2, "Mail", hidden: true)],
                         scans: [2: timedOut],
                         caches: caches)
        XCTAssertEqual(titles(r), ["Inbox — Mail", "Drafts"])
        XCTAssertTrue(r.windows.allSatisfy { $0.isAppHidden && $0.onCurrentSpace })
        XCTAssertEqual(appNames(r), [])
    }

    func testNappedAppWithOnscreenWindowsGetsRowsWithAppNameFallback() {
        let r = assemble(facts: [fact(30, pid: 3)], metas: [meta(3, "Things")], scans: [3: timedOut])
        XCTAssertEqual(titles(r), ["Things"])   // untitled → displayTitle falls back to app name
        XCTAssertEqual(r.windows.first?.title, "")
    }

    // MARK: - AX path

    func testAXWindowsBecomeRowsAndFillCaches() {
        let r = assemble(facts: [fact(40, pid: 4), fact(41, pid: 4, onscreen: false)],
                         metas: [meta(4, "Safari")],
                         scans: [4: answered([ax(40, "Apple"), ax(41, "Docs", minimized: true)])])
        XCTAssertEqual(titles(r), ["Apple", "Docs"])
        XCTAssertEqual(r.windows.map(\.isMinimized), [false, true])
        XCTAssertEqual(r.caches.titles, [40: "Apple", 41: "Docs"])
        XCTAssertEqual(r.caches.minimized, [40: false, 41: true])
        XCTAssertNotNil(r.caches.elements[40])
    }

    func testEmptyAXTitleFallsBackToCache() {
        var caches = WindowCaches()
        caches.titles[50] = "Old title"
        let r = assemble(facts: [fact(50, pid: 5)], metas: [meta(5, "Zen")],
                         scans: [5: answered([ax(50, "")])], caches: caches)
        XCTAssertEqual(titles(r), ["Old title"])
        XCTAssertEqual(r.caches.titles[50], "Old title", "an empty AX title must not erase the cache")
    }

    func testFullScreenShimIsSkipped() {
        // On screen at a non-zero layer: macOS's full-screen helper window.
        let r = assemble(facts: [fact(60, pid: 6, layer: 3), fact(61, pid: 6)],
                         metas: [meta(6, "Notes")],
                         scans: [6: answered([ax(60, "shim"), ax(61, "Real")])])
        XCTAssertEqual(titles(r), ["Real"])
    }

    func testDuplicateWindowIDsAreEmittedOnce() {
        let r = assemble(facts: [fact(70, pid: 7)], metas: [meta(7, "App")],
                         scans: [7: answered([ax(70, "A"), ax(70, "A again")])])
        XCTAssertEqual(titles(r), ["A"])
    }

    func testWindowWithoutIDIsKeptAndCountsAsCurrentSpace() {
        // No `_AXUIElementGetWindow`: no ids at all. Must degrade gracefully.
        let r = assemble(facts: [], metas: [meta(8, "App")], scans: [8: answered([ax(nil, "Untracked")])])
        XCTAssertEqual(titles(r), ["Untracked"])
        XCTAssertEqual(r.windows.first?.onCurrentSpace, true)
    }

    // MARK: - Fallback guards

    func testFallbackNotUsedForAppsAXAnsweredFor() {
        // Off-screen plausible CG windows of an app AX *did* answer for are
        // scratch windows, not missing ones — no phantom rows.
        let r = assemble(facts: [fact(80, pid: 9), fact(81, pid: 9, onscreen: false, size: screen)],
                         metas: [meta(9, "Chrome")],
                         scans: [9: answered([ax(80, "Tab")])])
        XCTAssertEqual(r.windows.map(\.cgWindowID), [80])
    }

    func testFallbackIgnoresImplausibleWindows() {
        let r = assemble(facts: [fact(90, pid: 10, size: CGSize(width: 1728, height: 33)),
                                 fact(91, pid: 10, size: CGSize(width: 64, height: 64))],
                         metas: [meta(10, "Slack")],
                         scans: [10: timedOut])
        XCTAssertEqual(titles(r), [])
        XCTAssertEqual(appNames(r), ["Slack"])
    }

    func testAgentAppGetsConfidentRowsButNoGuessedStandIn() {
        let onscreen = assemble(facts: [fact(100, pid: 11)],
                                metas: [meta(11, "Agent", regular: false)], scans: [11: timedOut])
        XCTAssertEqual(onscreen.windows.map(\.cgWindowID), [100])

        let offscreen = assemble(facts: [fact(101, pid: 11, onscreen: false, size: screen)],
                                 metas: [meta(11, "Agent", regular: false)], scans: [11: timedOut])
        XCTAssertEqual(offscreen.windows.count, 0)
        XCTAssertEqual(appNames(offscreen), [], "agent apps never land under Apps")
    }

    func testRepresentativeWindowPrefersDisplaySizedThenLargest() {
        let small = fact(1, pid: 1, size: CGSize(width: 400, height: 300))
        let large = fact(2, pid: 1, size: CGSize(width: 1200, height: 900))
        let full = fact(3, pid: 1, size: CGSize(width: 1728, height: 1080))   // menu bar tolerance
        XCTAssertEqual(WindowAssembly.representativeWindow(among: [small, large], screenSizes: [screen])?.id, 2)
        XCTAssertEqual(WindowAssembly.representativeWindow(among: [small, large, full], screenSizes: [screen])?.id, 3)
        XCTAssertNil(WindowAssembly.representativeWindow(among: [], screenSizes: [screen]))
    }

    func testFallbackUsesCachedMinimizedState() {
        var caches = WindowCaches()
        caches.titles[110] = "Report"
        caches.minimized[110] = true
        let r = assemble(facts: [fact(110, pid: 12, onscreen: false)], metas: [meta(12, "Pages")],
                         scans: [12: timedOut], caches: caches)
        XCTAssertEqual(r.windows.first?.isMinimized, true)
        XCTAssertEqual(r.windows.first?.onCurrentSpace, true)
    }

    // MARK: - Spaces

    func testSpaceMembership() {
        let current: Set<CGWindowID> = [1]
        XCTAssertTrue(WindowAssembly.spaceMembership(wid: 1, minimized: false, hidden: false, currentSpace: current))
        XCTAssertFalse(WindowAssembly.spaceMembership(wid: 2, minimized: false, hidden: false, currentSpace: current))
        XCTAssertTrue(WindowAssembly.spaceMembership(wid: 2, minimized: true, hidden: false, currentSpace: current))
        XCTAssertTrue(WindowAssembly.spaceMembership(wid: 2, minimized: false, hidden: true, currentSpace: current))
        XCTAssertTrue(WindowAssembly.spaceMembership(wid: nil, minimized: false, hidden: false, currentSpace: current))
    }

    func testOffSpaceWindowIsMarkedNotCurrent() {
        let r = assemble(facts: [fact(120, pid: 13), fact(121, pid: 13, onscreen: false)],
                         metas: [meta(13, "Xcode")],
                         scans: [13: answered([ax(120, "Here"), ax(121, "There")])])
        XCTAssertEqual(r.windows.map(\.onCurrentSpace), [true, false])
        XCTAssertEqual(r.currentSpaceWindowIDs, [120])
    }

    // MARK: - Self, unknowns, caches

    func testOwnWindowsComeFromOwnRowsNotAX() {
        let own = WindowInfo(pid: selfPID, bundleID: nil, appName: "Wicher", appIcon: nil, title: "Preferences",
                             axWindow: nil, isMinimized: false, isAppHidden: false, cgWindowID: 130)
        let r = assemble(facts: [fact(130, pid: selfPID)],
                         metas: [meta(selfPID, "Wicher", regular: false)],
                         scans: [selfPID: answered([ax(130, "via AX")])],
                         ownRows: [own])
        XCTAssertEqual(titles(r), ["Preferences"])
        XCTAssertEqual(appNames(r), [])
    }

    func testUnknownAppWithoutTitleIsDropped() {
        let r = assemble(facts: [fact(140, pid: 14)], metas: [meta(14, "Unknown")],
                         scans: [14: answered([ax(140, "")])])
        XCTAssertEqual(r.windows.count, 0)
    }

    func testCachesArePrunedToLiveWindows() {
        var caches = WindowCaches()
        caches.titles = [1: "gone", 150: "alive"]
        caches.minimized = [1: true]
        caches.elements = [1: AXUIElementCreateApplication(1)]
        let r = assemble(facts: [fact(150, pid: 15, onscreen: false)], metas: [meta(15, "App")],
                         scans: [15: timedOut], caches: caches)
        XCTAssertEqual(r.caches.titles, [150: "alive"])
        XCTAssertTrue(r.caches.minimized.isEmpty)
        XCTAssertTrue(r.caches.elements.isEmpty)
    }

    func testMissingScanIsTreatedAsTimeout() {
        let r = assemble(facts: [fact(160, pid: 16)], metas: [meta(16, "App")], scans: [:])
        XCTAssertEqual(r.windows.map(\.cgWindowID), [160])
    }
}
