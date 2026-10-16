import XCTest
@testable import WicherCore

final class WindowGroupingTests: XCTestCase {
    // pid 1 is the active app.
    let a1 = window("a1", pid: 1)
    let a2 = window("a2", pid: 1, onCurrentSpace: false)
    let a3 = window("a3", pid: 1, minimized: true)
    let b1 = window("b1", pid: 2)
    let b2 = window("b2", pid: 2, hidden: true, onCurrentSpace: false)
    let b3 = window("b3", pid: 2, minimized: true, hidden: true)   // minimized wins
    let b4 = window("b4", pid: 2, hidden: true)
    let appA = appOnly("A", pid: 1)
    let appC = appOnly("C", pid: 3)

    var fixture: Enumeration {
        enumeration([a1, b1, a2, b2, a3, b3, b4], apps: [appA, appC])
    }

    private func shape(_ sections: [WindowSection]) -> [String] {
        sections.map { s in "\(s.title ?? "-"): " + s.items.map(\.displayTitle).joined(separator: ",") }
    }

    /// Every scope × spaces × minimized × hidden × apps combination, checked
    /// against an expectation spelled out independently of the implementation.
    func testAllCombinations() {
        for scope in WindowScope.allCases {
            for spaces in SpaceScope.allCases {
                for minP in Placement.allCases {
                    for hidP in Placement.allCases {
                        for appP in Placement.allCases {
                            let p = profile(scope: scope, spaces: spaces,
                                            minimized: minP, hidden: hidP, apps: appP)
                            let got = WindowGrouping.sections(for: p, enumeration: fixture, activeAppPID: 1)
                            XCTAssertEqual(shape(got), expected(scope, spaces, minP, hidP, appP),
                                           "scope=\(scope) spaces=\(spaces) min=\(minP) hid=\(hidP) apps=\(appP)")
                        }
                    }
                }
            }
        }
    }

    private func expected(_ scope: WindowScope, _ spaces: SpaceScope,
                          _ minP: Placement, _ hidP: Placement, _ appP: Placement) -> [String] {
        let activeOnly = scope == .activeApp
        let visibleOnly = spaces == .visibleSpaces

        var normal = ["a1", "b1", "a2"]
        var minimized = ["a3", "b3"]
        var hidden = ["b2", "b4"]
        var apps = ["A", "C"]
        if activeOnly {
            normal = ["a1", "a2"]; minimized = ["a3"]; hidden = []; apps = ["A"]
        }
        if visibleOnly {
            // a2 and b2 are off-Space; app-only entries are never Space-filtered.
            normal.removeAll { $0 == "a2" }
            hidden.removeAll { $0 == "b2" }
        }

        var main = normal
        var bottom: [String] = []
        for (items, placement, title) in [(minimized, minP, "Minimized"),
                                          (hidden, hidP, "Hidden"),
                                          (apps, appP, "Apps")] where !items.isEmpty {
            switch placement {
            case .hide: break
            case .show: main += items
            case .showAtBottom: bottom.append("\(title): " + items.joined(separator: ","))
            }
        }
        return (main.isEmpty ? [] : ["-: " + main.joined(separator: ",")]) + bottom
    }

    func testActiveAppScopeWithoutActivePIDKeepsEverything() {
        let p = profile(scope: .activeApp, minimized: .show, hidden: .show, apps: .show)
        let got = WindowGrouping.sections(for: p, enumeration: fixture, activeAppPID: nil)
        XCTAssertEqual(shape(got), ["-: a1,b1,a2,a3,b3,b2,b4,A,C"])
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
