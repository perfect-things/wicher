import XCTest
@testable import WicherCore

final class LiveUpdateTests: XCTestCase {
    private func win(_ title: String, id: CGWindowID, pid: pid_t = 1) -> WindowInfo {
        WindowInfo(pid: pid, bundleID: nil, appName: "App", appIcon: nil, title: title,
                   axWindow: nil, isMinimized: false, isAppHidden: false, cgWindowID: id)
    }

    private func session(_ windows: [WindowInfo]) -> SwitcherSession {
        SwitcherSession(profile: profile(), enumeration: enumeration(windows), activeAppPID: nil, forward: true)
    }

    func testKeys() {
        XCTAssertEqual(win("a", id: 7).key, .window(7))
        XCTAssertEqual(appOnly("Finder", pid: 3).key, .app(3))
        XCTAssertEqual(window("t", pid: 4).key, .untracked(4, "t"))
    }

    func testSelectionFollowsWindowWhenItMoves() {
        let a = win("A", id: 1), b = win("B", id: 2), c = win("C", id: 3)
        var s = session([a, b, c])
        XCTAssertEqual(s.selectedWindow?.key, .window(2))
        // A new window appears at the top; B is now third.
        XCTAssertTrue(s.update(enumeration: enumeration([win("New", id: 9), a, b, c])))
        XCTAssertEqual(s.selectedWindow?.key, .window(2))
    }

    func testRetitledWindowStaysSelectedAndRedraws() {
        var s = session([win("A", id: 1), win("B", id: 2)])
        XCTAssertTrue(s.update(enumeration: enumeration([win("A", id: 1), win("B — edited", id: 2)])))
        XCTAssertEqual(s.selectedWindow?.displayTitle, "B — edited")
    }

    func testSelectedWindowClosedClampsSelection() {
        var s = session([win("A", id: 1), win("B", id: 2)])
        XCTAssertTrue(s.update(enumeration: enumeration([win("A", id: 1)])))
        XCTAssertEqual(s.selectedWindow?.key, .window(1))
    }

    func testIdenticalUpdateReportsNoChange() {
        var s = session([win("A", id: 1), win("B", id: 2)])
        s.advance(by: 1)
        let selected = s.selectedRowIndex
        XCTAssertFalse(s.update(enumeration: enumeration([win("A", id: 1), win("B", id: 2)])))
        XCTAssertEqual(s.selectedRowIndex, selected)
    }

    func testUpdateRespectsActiveQuery() {
        var s = session([win("Mail", id: 1), win("Notes", id: 2)])
        s.appendToQuery("n")
        XCTAssertEqual(s.selectedWindow?.key, .window(2))
        XCTAssertTrue(s.update(enumeration: enumeration([win("Mail", id: 1), win("Notes", id: 2), win("Numbers", id: 3)])))
        XCTAssertEqual(s.selectedWindow?.key, .window(2), "still on Notes, not the new match")
        XCTAssertEqual(s.query, "n")
    }
}

final class SettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "wicher.tests.settings"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsAndClamping() {
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.iconSize, 32)
        settings.iconSize = 1000
        XCTAssertEqual(settings.iconSize, HUDMetrics.iconRange.upperBound)
        settings.showDelayMs = -5
        XCTAssertEqual(settings.showDelayMs, 0)
    }

    func testProfilesRoundTripAndPostChange() {
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.profiles.count, SwitcherProfile.defaults().count)

        var changes: [Settings.Change] = []
        let token = NotificationCenter.default.addObserver(forName: Settings.didChange, object: settings,
                                                           queue: nil) { note in
            if let change = note.userInfo?[Settings.changeKey] as? Settings.Change { changes.append(change) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let one = [profile()]
        settings.profiles = one
        settings.appearanceMode = .dark
        XCTAssertEqual(changes, [.profiles, .appearance])
        XCTAssertEqual(settings.profiles.map(\.id), one.map(\.id))
        // Persisted, not just cached.
        XCTAssertEqual(Settings(defaults: defaults).profiles.map(\.id), one.map(\.id))
    }

    func testEmptyProfilesFallBackToDefaults() {
        let settings = Settings(defaults: defaults)
        settings.profiles = []
        XCTAssertEqual(settings.profiles.count, SwitcherProfile.defaults().count)
    }
}
