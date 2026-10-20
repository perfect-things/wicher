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

@MainActor
final class SettingsTests: XCTestCase {
    // Read by the nonisolated setUp/tearDown too; XCTest runs those and the
    // tests one after another on the main thread.
    private let suite = "wicher.tests.settings"
    nonisolated(unsafe) private let defaults = UserDefaults(suiteName: "wicher.tests.settings")!

    override func setUp() {
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

    func testProfilesRoundTripAndAreObserved() {
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.profiles.count, SwitcherProfile.defaults().count)

        let one = [profile()]
        XCTAssertTrue(changes(of: { _ = settings.profiles }) { settings.profiles = one })
        XCTAssertTrue(changes(of: { _ = settings.appearanceMode }) { settings.appearanceMode = .dark })
        XCTAssertFalse(changes(of: { _ = settings.appearanceMode }) { settings.iconSize = 40 },
                       "only the properties read are tracked")
        XCTAssertEqual(settings.profiles.map(\.id), one.map(\.id))
        // Persisted, not just cached.
        XCTAssertEqual(Settings(defaults: defaults).profiles.map(\.id), one.map(\.id))
    }

    func testEmptyProfilesFallBackToDefaults() {
        let settings = Settings(defaults: defaults)
        settings.profiles = []
        XCTAssertEqual(settings.profiles.count, SwitcherProfile.defaults().count)
        XCTAssertEqual(Settings(defaults: defaults).profiles.map(\.id), settings.profiles.map(\.id),
                       "restored defaults are persisted")
    }

    func testGeneratedDefaultProfilesKeepTheirIDs() {
        let first = Settings(defaults: defaults).profiles.map(\.id)
        XCTAssertEqual(Settings(defaults: defaults).profiles.map(\.id), first)
    }

    func testSetClampsAndPersists() {
        let settings = Settings(defaults: defaults)
        XCTAssertTrue(changes(of: { _ = settings.textSize }) { settings.textSize = 1 })
        XCTAssertEqual(settings.textSize, HUDMetrics.textRange.lowerBound)
        XCTAssertEqual(Settings(defaults: defaults).textSize, HUDMetrics.textRange.lowerBound)
        settings.showMenuBarIcon = false
        XCTAssertFalse(Settings(defaults: defaults).showMenuBarIcon)
    }

    func testSurfacesAndGridSizesRoundTrip() {
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.backgroundSurface, .defaultBackground)
        XCTAssertEqual(settings.highlightSurface, .defaultHighlight)
        XCTAssertEqual(settings.gridIconSize, 96)

        let red = SurfaceAppearance(style: .blurred, light: Tint(color: RGBColor(red: 1, green: 0, blue: 0), opacity: 50),
                                    dark: Tint(color: .white, opacity: 5))
        XCTAssertTrue(changes(of: { _ = settings.backgroundSurface }) { settings.backgroundSurface = red })
        settings.highlightSurface.style = .solid
        settings.gridIconSize = 1000
        settings.gridIconSpacing = 3
        settings.gridIconPadding = 20
        XCTAssertEqual(settings.gridIconSize, IconGridLayout.iconRange.upperBound)

        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.backgroundSurface, red)
        XCTAssertEqual(reloaded.highlightSurface.style, .solid)
        XCTAssertEqual(reloaded.gridIconSize, IconGridLayout.iconRange.upperBound)
        XCTAssertEqual(reloaded.gridIconSpacing, 3)
        XCTAssertEqual(reloaded.gridIconPadding, 20)
        XCTAssertEqual(reloaded.iconSize, 32, "List sizes are separate")
    }

    func testProfileLayoutRoundTrips() {
        let settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.profiles.allSatisfy { $0.layout == .list })
        settings[profileID: settings.profiles[0].id].layout = .icons
        XCTAssertEqual(Settings(defaults: defaults).profiles[0].layout, .icons)
    }

    func testSameValueIsNotObserved() {
        let settings = Settings(defaults: defaults)
        XCTAssertFalse(changes(of: { _ = settings.iconSize; _ = settings.selectOnHover; _ = settings.profiles }) {
            settings.iconSize = settings.iconSize
            settings.selectOnHover = settings.selectOnHover
            settings.profiles = settings.profiles
            settings[profileID: settings.profiles[0].id] = settings.profiles[0]
        })
    }

    func testProfileSubscriptSurvivesRemoval() {
        let settings = Settings(defaults: defaults)
        var renamed = settings.profiles[0]
        renamed.name = "Renamed"
        settings[profileID: renamed.id] = renamed
        XCTAssertEqual(settings.profiles[0].name, "Renamed")

        let removed = settings.profiles[1].id
        settings.profiles.remove(at: 1)
        _ = settings[profileID: removed]                    // reads without trapping
        settings[profileID: removed] = profile()            // and ignores the write
        XCTAssertEqual(settings.profiles.map(\.id), [renamed.id])
    }

    private final class Flag: @unchecked Sendable { var value = false }   // set synchronously, in `write`

    /// Whether `write` changes anything `read` reads, as Observation sees it.
    private func changes(of read: () -> Void, after write: () -> Void) -> Bool {
        let fired = Flag()
        withObservationTracking(read) { fired.value = true }
        write()
        return fired.value
    }
}
