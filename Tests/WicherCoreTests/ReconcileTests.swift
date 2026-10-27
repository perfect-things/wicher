import XCTest
@testable import WicherCore

/// `WindowAssembly.reconcile`: the per-summon patch of a cached snapshot.
final class ReconcileTests: XCTestCase {
    private let selfPID: pid_t = 999

    private func reconcile(_ windows: [WindowInfo],
                           apps: [WindowInfo] = [],
                           facts: [CGWindowFact],
                           hidden: [pid_t: Bool] = [1: false, 2: false],
                           front: (meta: AppMeta, scan: AppScan)? = nil,
                           ownRows: [WindowInfo] = []) -> ReconciledScan {
        WindowAssembly.reconcile(windows: windows, appsWithoutWindows: apps, facts: facts,
                                 hiddenByPID: hidden, front: front, ownRows: ownRows, selfPID: selfPID)
    }

    private func titles(_ r: ReconciledScan) -> [String] { r.windows.map(\.displayTitle) }

    func testClosedWindowIsDropped() {
        let r = reconcile([window("A", pid: 2, wid: 10), window("B", pid: 2, wid: 11)],
                          facts: [fact(10, pid: 2)])
        XCTAssertEqual(titles(r), ["A"])
    }

    func testQuitAppIsDropped() {
        let r = reconcile([window("A", pid: 3, wid: 10)], apps: [appOnly("Gone", pid: 3)],
                          facts: [fact(10, pid: 3)])
        XCTAssertEqual(titles(r), [])
        XCTAssertEqual(r.appsWithoutWindows.count, 0)
    }

    func testHiddenFlagAndSpaceComeFromFreshFacts() {
        let r = reconcile([window("A", pid: 2, wid: 10), window("B", pid: 1, wid: 11)],
                          facts: [fact(10, pid: 2), fact(11, pid: 1, onscreen: false)],
                          hidden: [1: false, 2: true])
        XCTAssertEqual(r.windows.map(\.isAppHidden), [true, false])
        XCTAssertEqual(r.windows.map(\.onCurrentSpace), [true, false])
    }

    func testFrontWindowMinimized() {
        let r = reconcile([window("Doc", pid: 1, wid: 10)],
                          facts: [fact(10, pid: 1, onscreen: false)],
                          front: (meta(1, "Pages"), answered([ax(10, "Doc", minimized: true)])))
        XCTAssertEqual(r.windows.map(\.isMinimized), [true])
        XCTAssertEqual(r.windows.map(\.onCurrentSpace), [true], "minimized counts as current")
    }

    func testWindowBackOnScreenIsNoLongerMinimized() {
        // Not the front app, so no fresh AX answer: on screen alone clears it.
        let r = reconcile([window("Doc", pid: 2, minimized: true, wid: 10),
                           window("Other", pid: 2, minimized: true, wid: 11)],
                          facts: [fact(10, pid: 2), fact(11, pid: 2, onscreen: false)])
        XCTAssertEqual(r.windows.map(\.isMinimized), [false, true])
    }

    func testFrontWindowTitleRefreshed() {
        let r = reconcile([window("Old", pid: 1, wid: 10)], facts: [fact(10, pid: 1)],
                          front: (meta(1, "Pages"), answered([ax(10, "New")])))
        XCTAssertEqual(titles(r), ["New"])
        XCTAssertEqual(r.freshTitles, [10: "New"])
    }

    func testFrontWindowClosedButStillListedByCGIsDropped() {
        let r = reconcile([window("A", pid: 1, wid: 10), window("B", pid: 1, wid: 11)],
                          facts: [fact(10, pid: 1), fact(11, pid: 1)],
                          front: (meta(1, "Pages"), answered([ax(10, "A")])))
        XCTAssertEqual(titles(r), ["A"])
    }

    func testNewFrontWindowIsAdded() {
        let r = reconcile([window("A", pid: 1, app: "Pages", wid: 10)],
                          facts: [fact(10, pid: 1), fact(11, pid: 1)],
                          front: (meta(1, "Pages"), answered([ax(10, "A"), ax(11, "B"), ax(12, "")])))
        XCTAssertEqual(titles(r), ["A", "B"], "untitled new windows are skipped")
        XCTAssertEqual(r.windows.last?.appName, "Pages")
        XCTAssertEqual(r.windows.last?.cgWindowID, 11)
        XCTAssertEqual(r.freshTitles[11], "B")
    }

    func testFullScreenShimIsSkipped() {
        let r = reconcile([], facts: [fact(11, pid: 1, layer: 3)],
                          front: (meta(1, "Pages"), answered([ax(11, "Shim")])))
        XCTAssertEqual(titles(r), [])
    }

    func testAppGainingItsFirstWindowLeavesApps() {
        let r = reconcile([], apps: [appOnly("Pages", pid: 1), appOnly("Notes", pid: 2)],
                          facts: [fact(11, pid: 1)],
                          front: (meta(1, "Pages"), answered([ax(11, "B")])))
        XCTAssertEqual(titles(r), ["B"])
        XCTAssertEqual(r.appsWithoutWindows.map(\.appName), ["Notes"])
    }

    func testFrontAppClosingItsLastWindowJoinsApps() {
        let r = reconcile([window("A", pid: 1, wid: 10)], facts: [fact(10, pid: 1)],
                          front: (meta(1, "Pages"), answered([])))
        XCTAssertEqual(titles(r), [])
        XCTAssertEqual(r.appsWithoutWindows.map(\.appName), ["Pages"])
        XCTAssertEqual(r.appsWithoutWindows.first?.isAppOnly, true)
    }

    func testAgentFrontAppNeverJoinsApps() {
        let r = reconcile([], facts: [], front: (meta(1, "Agent", regular: false), answered([])))
        XCTAssertEqual(r.appsWithoutWindows.count, 0)
    }

    func testFrontAppNotAnsweringLeavesSnapshotAsItWas() {
        let snap = [window("A", pid: 1, wid: 10), window("B", pid: 1, wid: 11)]
        let r = reconcile(snap, facts: [fact(10, pid: 1), fact(11, pid: 1)],
                          front: (meta(1, "Pages"), timedOut))
        XCTAssertEqual(titles(r), ["A", "B"])
        XCTAssertEqual(r.freshTitles, [:])
        XCTAssertEqual(r.appsWithoutWindows.count, 0)
    }

    func testUntrackedFrontWindowsSurvive() {
        // No `_AXUIElementGetWindow`: no ids to match, so keep the rows.
        let r = reconcile([window("A", pid: 1)], facts: [],
                          front: (meta(1, "Pages"), answered([ax(nil, "A")])))
        XCTAssertEqual(titles(r), ["A"])
    }

    func testOwnRowsReplaceTheSnapshots() {
        let r = reconcile([window("Old Settings", pid: selfPID, wid: 50)],
                          facts: [fact(50, pid: selfPID)],
                          hidden: [selfPID: false],
                          ownRows: [window("Settings", pid: selfPID, wid: 50)])
        XCTAssertEqual(titles(r), ["Settings"])
    }
}
