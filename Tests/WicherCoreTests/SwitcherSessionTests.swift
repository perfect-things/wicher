import XCTest
@testable import WicherCore

final class SwitcherSessionTests: XCTestCase {
    private func session(_ windows: [WindowInfo],
                         apps: [WindowInfo] = [],
                         profile p: SwitcherProfile = profile(),
                         activeAppPID: pid_t? = 1,
                         forward: Bool = true) -> SwitcherSession {
        SwitcherSession(profile: p, enumeration: enumeration(windows, apps: apps),
                        activeAppPID: activeAppPID, forward: forward)
    }

    /// "—" for the separator, the display title for items, with any note in brackets.
    private func labels(_ s: SwitcherSession) -> [String] {
        s.rows.map {
            switch $0 {
            case .separator: return "—"
            case let .item(info, _, note): return info.displayTitle + (note.map { " [\($0)]" } ?? "")
            }
        }
    }

    private let three = [window("w0"), window("w1"), window("w2")]

    // MARK: - Initial selection

    func testForwardPreselectsSecondItem() {
        let s = session(three)
        XCTAssertEqual(s.selectedRowIndex, 1)
        XCTAssertEqual(s.selectedWindow?.title, "w1")
    }

    func testForwardWithSingleItemSelectsIt() {
        XCTAssertEqual(session([window("only")]).selectedRowIndex, 0)
    }

    func testBackwardPreselectsLastRow() {
        let s = session(three + [window("m", minimized: true)], forward: false)
        XCTAssertEqual(labels(s), ["w0", "w1", "w2", "—", "m [Minimized]"])
        XCTAssertEqual(s.selectedRowIndex, 4)
    }

    func testForwardSkipsTheSeparatorWhenSecondItemFollowsIt() {
        let s = session([window("w0"), window("m", minimized: true)])
        XCTAssertEqual(labels(s), ["w0", "—", "m [Minimized]"])
        XCTAssertEqual(s.selectedRowIndex, 2)
    }

    func testBottomGroupsMergeBehindOneSeparator() {
        let s = session([window("w0"), window("m", minimized: true), window("h", hidden: true)],
                        apps: [appOnly("Idle", pid: 9)])
        XCTAssertEqual(labels(s), ["w0", "—", "m [Minimized]", "h [Hidden]", "Idle [No Windows]"])
    }

    func testNoSeparatorWithoutABottomGroup() {
        XCTAssertEqual(labels(session(three)), ["w0", "w1", "w2"])
    }

    func testNoSeparatorWhenOnlyTheBottomGroupHasWindows() {
        let s = session([window("m", minimized: true), window("h", hidden: true)])
        XCTAssertEqual(labels(s), ["m [Minimized]", "h [Hidden]"])
        XCTAssertEqual(s.selectedRowIndex, 1)
    }

    func testSearchNotesOnlyWindowsPlacedAtTheBottom() {
        let p = profile(minimized: .show)
        var s = session([window("mail", minimized: true), window("mac", hidden: true)], profile: p)
        s.appendToQuery("m")
        XCTAssertEqual(Set(labels(s)), ["mail", "mac [Hidden]"])
    }

    func testEmptySessionHasNoSelection() {
        var s = session([])
        XCTAssertNil(s.selectedRowIndex)
        XCTAssertNil(s.selectedWindow)
        s.advance(by: 1)
        XCTAssertNil(s.selectedRowIndex)
    }

    // MARK: - Advance

    func testAdvanceWraps() {
        var s = session(three)
        s.advance(by: 1)
        XCTAssertEqual(s.selectedRowIndex, 2)
        s.advance(by: 1)
        XCTAssertEqual(s.selectedRowIndex, 0)
        s.advance(by: -1)
        XCTAssertEqual(s.selectedRowIndex, 2)
    }

    func testAdvanceClampsWithoutWrap() {
        var s = session(three)
        s.advance(by: 1, wrap: false)
        s.advance(by: 1, wrap: false)
        XCTAssertEqual(s.selectedRowIndex, 2)
        s.advance(by: -5, wrap: false)
        XCTAssertEqual(s.selectedRowIndex, 0)
    }

    func testAdvanceSkipsHeaders() {
        var s = session([window("w0"), window("m", minimized: true)], forward: false)
        XCTAssertEqual(s.selectedRowIndex, 2)
        s.advance(by: -1)
        XCTAssertEqual(s.selectedRowIndex, 0)
    }

    // MARK: - select(rowIndex:)

    func testSelectRejectsSeparatorAndOutOfRange() {
        var s = session([window("w0"), window("m", minimized: true)])
        s.advance(by: -1)                        // select w0
        XCTAssertFalse(s.select(rowIndex: 1))    // the separator
        XCTAssertFalse(s.select(rowIndex: 3))
        XCTAssertFalse(s.select(rowIndex: -1))
        XCTAssertEqual(s.selectedRowIndex, 0)
        XCTAssertTrue(s.select(rowIndex: 2))
        XCTAssertEqual(s.selectedWindow?.title, "m")
    }

    // MARK: - Query

    func testQueryChangesResetSelection() {
        var s = session([window("alpha"), window("alps"), window("beta")])
        XCTAssertEqual(s.selectedRowIndex, 1)
        s.appendToQuery("a")
        XCTAssertEqual(s.query, "a")
        XCTAssertEqual(s.selectedRowIndex, 0)
        s.advance(by: 1)
        s.appendToQuery("l")
        XCTAssertEqual(s.selectedRowIndex, 0)
        XCTAssertEqual(Set(labels(s)), ["alpha", "alps"])
        s.advance(by: 1)
        XCTAssertTrue(s.deleteBackward())
        XCTAssertEqual(s.selectedRowIndex, 0)
        XCTAssertTrue(s.deleteBackward())
        XCTAssertEqual(s.query, "")
        XCTAssertEqual(labels(s), ["alpha", "alps", "beta"])
        XCTAssertEqual(s.selectedRowIndex, 0)
        XCTAssertFalse(s.deleteBackward())
    }

    func testClearQueryRestoresTheFullList() {
        var s = session([window("alpha"), window("beta")])
        XCTAssertFalse(s.clearQuery(), "nothing to clear: Esc closes the panel")
        s.appendToQuery("b")
        s.appendToQuery("e")
        XCTAssertEqual(labels(s), ["beta"])
        XCTAssertTrue(s.clearQuery())
        XCTAssertEqual(s.query, "")
        XCTAssertEqual(labels(s), ["alpha", "beta"])
        XCTAssertFalse(s.clearQuery())
    }

    func testSearchIsFlatWithHighlightRanges() {
        var s = session([window("w0"), window("mail", minimized: true)])
        s.appendToQuery("m")
        XCTAssertEqual(labels(s), ["mail [Minimized]"])   // no separator, but the note stays
        guard case let .item(_, ranges, _) = s.rows[0] else { return XCTFail() }
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 1)])
    }

    func testSearchRespectsActiveAppScope() {
        let p = profile(scope: .activeApp)
        var s = session([window("x1", pid: 1), window("x2", pid: 2)], profile: p, activeAppPID: 1)
        s.appendToQuery("x")
        XCTAssertEqual(labels(s), ["x1"])
    }

    func testSearchRespectsHiddenOtherSpaces() {
        let p = profile(otherSpaces: .hide)
        var s = session([window("x1"), window("x2", onCurrentSpace: false)], profile: p)
        s.appendToQuery("x")
        XCTAssertEqual(labels(s), ["x1"])
    }

    func testSearchRespectsHiddenOtherDisplays() {
        let e = enumeration([window("x1", wid: 1), window("x2", wid: 2)],
                            frames: [1: CGRect(x: 10, y: 10, width: 500, height: 400), 2: rightDisplayFrame])
        var s = SwitcherSession(profile: profile(otherDisplays: .hide), enumeration: e,
                                activeAppPID: nil, display: twoDisplays, forward: true)
        s.appendToQuery("x")
        XCTAssertEqual(labels(s), ["x1"])
    }

    func testSearchExcludesAppsWithoutWindows() {
        var s = session([window("x1")], apps: [appOnly("xapp", pid: 9)])
        s.appendToQuery("x")
        XCTAssertEqual(labels(s), ["x1"])
    }

    // MARK: - App-name-only scoring

    /// Query "ab" against the app name "ab" scores 31, so an app-name-only hit
    /// ranks at 26. Each extra trailing character in a title costs one point:
    /// "abcdef" scores 27 and beats it, "abcdefgh" scores 25 and loses.
    func testAppNameOnlyMatchScoresFiveBelowTitleMatch() {
        XCTAssertEqual(FuzzyMatcher.match(query: "ab", candidate: "ab")?.score, 31)
        XCTAssertEqual(FuzzyMatcher.match(query: "ab", candidate: "abcdef")?.score, 27)
        XCTAssertEqual(FuzzyMatcher.match(query: "ab", candidate: "abcdefgh")?.score, 25)

        var s = session([window("abcdefgh", app: "x"),
                         window("zz", app: "ab"),
                         window("abcdef", app: "x")])
        s.appendToQuery("a")
        s.appendToQuery("b")
        XCTAssertEqual(labels(s), ["abcdef", "zz", "abcdefgh"])
        guard case let .item(_, ranges, _) = s.rows[1] else { return XCTFail() }
        XCTAssertEqual(ranges, [], "app-name-only match highlights nothing in the title")
    }
}

final class HoverGateTests: XCTestCase {
    func testStillPointerIsNotAHover() {
        var gate = HoverGate(pointer: NSPoint(x: 10, y: 10))
        XCTAssertFalse(gate.accept(pointer: NSPoint(x: 10, y: 10)), "panel opened under the pointer")
        XCTAssertTrue(gate.accept(pointer: NSPoint(x: 10, y: 30)), "moved onto another row")
        XCTAssertFalse(gate.accept(pointer: NSPoint(x: 10, y: 30)), "rows re-laid out under it")
    }
}
