import XCTest
@testable import WicherCore

final class WindowGroupingTests: XCTestCase {
    // pid 1 is the active app.
    let a1 = window("a1", pid: 1)
    let a2 = window("a2", pid: 1, onCurrentSpace: false)
    let a3 = window("a3", pid: 1, minimized: true)
    let a4 = window("a4", pid: 1, wid: 4)                          // other display
    let b1 = window("b1", pid: 2, wid: 1)                          // this display
    let b2 = window("b2", pid: 2, hidden: true, onCurrentSpace: false)   // hidden wins
    let b3 = window("b3", pid: 2, minimized: true, hidden: true)   // minimized wins
    let b4 = window("b4", pid: 2, hidden: true)
    let b5 = window("b5", pid: 2, wid: 5)                          // other display
    let appA = appOnly("A", pid: 1)
    let appC = appOnly("C", pid: 3)

    var fixture: Enumeration {
        enumeration([a1, b1, a2, a4, b2, a3, b3, b4, b5], apps: [appA, appC],
                    frames: [1: CGRect(x: 100, y: 100, width: 500, height: 400),
                             4: rightDisplayFrame, 5: rightDisplayFrame])
    }

    private func shape(_ sections: [WindowSection]) -> [String] {
        sections.map { s in "\(s.title ?? "-"): " + s.items.map(\.displayTitle).joined(separator: ",") }
    }

    /// Every scope × placement combination, checked against an expectation
    /// spelled out independently of the implementation.
    func testAllCombinations() {
        let all = Placement.allCases
        for scope in WindowScope.allCases {
            for dispP in all { for spaceP in all { for minP in all { for hidP in all { for appP in all {
                let p = profile(scope: scope, otherDisplays: dispP, otherSpaces: spaceP,
                                minimized: minP, hidden: hidP, apps: appP)
                let got = WindowGrouping.sections(for: p, enumeration: fixture, activeAppPID: 1,
                                                  display: twoDisplays)
                XCTAssertEqual(shape(got), expected(scope, [dispP, spaceP, minP, hidP, appP]),
                               "scope=\(scope) disp=\(dispP) space=\(spaceP) min=\(minP) hid=\(hidP) apps=\(appP)")
            } } } } }
        }
    }

    /// `placements`: other displays, other Spaces, minimized, hidden, apps.
    private func expected(_ scope: WindowScope, _ placements: [Placement]) -> [String] {
        var normal = ["a1", "b1"]
        var categories = [["a4", "b5"], ["a2"], ["a3", "b3"], ["b2", "b4"], ["A", "C"]]
        if scope == .activeApp {
            normal = ["a1"]
            categories = [["a4"], ["a2"], ["a3"], [], ["A"]]
        }
        let titles = ["Other Displays", "Other Spaces", "Minimized", "Hidden", "Apps"]

        var main = normal
        var bottom: [String] = []
        for (i, items) in categories.enumerated() where !items.isEmpty {
            switch placements[i] {
            case .hide: break
            case .show: main += items
            case .showAtBottom: bottom.append("\(titles[i]): " + items.joined(separator: ","))
            }
        }
        return (main.isEmpty ? [] : ["-: " + main.joined(separator: ",")]) + bottom
    }

    func testWithoutDisplayLayoutNothingIsOnAnotherDisplay() {
        let p = profile(otherDisplays: .hide, otherSpaces: .hide, minimized: .hide, hidden: .hide, apps: .hide)
        let got = WindowGrouping.sections(for: p, enumeration: fixture, activeAppPID: nil)
        XCTAssertEqual(shape(got), ["-: a1,b1,a4,b5"])
    }

    func testDisplayLayoutPicksTheDisplayWithMostOfTheWindow() {
        XCTAssertTrue(twoDisplays.isOnOtherDisplay(rightDisplayFrame))
        XCTAssertFalse(twoDisplays.isOnOtherDisplay(CGRect(x: 600, y: 0, width: 600, height: 400)))
        // Entirely off every display: treated as here, not elsewhere.
        XCTAssertFalse(twoDisplays.isOnOtherDisplay(CGRect(x: 5000, y: 0, width: 300, height: 300)))
        let single = DisplayLayout(displays: [twoDisplays.current], current: twoDisplays.current)
        XCTAssertFalse(single.isOnOtherDisplay(rightDisplayFrame))
    }

    func testActiveAppScopeWithoutActivePIDKeepsEverything() {
        let p = profile(scope: .activeApp, minimized: .show, hidden: .show, apps: .show)
        let got = WindowGrouping.sections(for: p, enumeration: fixture, activeAppPID: nil)
        XCTAssertEqual(shape(got), ["-: a1,b1,a4,b5,a2,a3,b3,b2,b4,A,C"])
    }

    func testEmptyMainSectionIsDropped() {
        let e = enumeration([window("m", minimized: true)])
        let got = WindowGrouping.sections(for: profile(), enumeration: e, activeAppPID: nil)
        XCTAssertEqual(shape(got), ["Minimized: m"])
    }

    func testEmptyEnumerationYieldsNoSections() {
        XCTAssertTrue(WindowGrouping.sections(for: profile(), enumeration: .empty, activeAppPID: 1).isEmpty)
    }
}
