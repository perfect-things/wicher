import XCTest
@testable import WicherCore

final class ExceptionRulesTests: XCTestCase {
    let finder = AppRef(bundleID: "com.apple.finder", name: "Finder")

    func rule(_ target: ExceptionRule.Target, _ action: ExceptionRule.Action) -> ExceptionRule {
        ExceptionRule(target: target, action: action)
    }

    // MARK: - Matching

    func testAppMatchesByBundleIDNotName() {
        let r = rule(.app(finder), .hide)
        XCTAssertTrue(r.matches(window("Home", app: "Finder", bundle: "com.apple.finder")))
        XCTAssertTrue(r.matches(window("Home", app: "Renamed", bundle: "com.apple.finder")))
        XCTAssertFalse(r.matches(window("Home", app: "Finder", bundle: "com.example.finder")))
        XCTAssertTrue(r.matches(appOnly("Finder", pid: 3, bundle: "com.apple.finder")))
    }

    func testAppWithoutBundleIDMatchesByNameIgnoringCase() {
        let r = rule(.app(AppRef(bundleID: nil, name: "loginwindow")), .hide)
        XCTAssertTrue(r.matches(window("", app: "LoginWindow")))
        XCTAssertFalse(r.matches(window("", app: "loginwindow2")))
    }

    func testHideIfNoWindowsMatchesOnlyTheAppOnlyEntry() {
        let r = rule(.app(finder), .hideIfNoWindows)
        XCTAssertTrue(r.matches(appOnly("Finder", pid: 3, bundle: "com.apple.finder")))
        XCTAssertFalse(r.matches(window("Home", app: "Finder", bundle: "com.apple.finder")))
    }

    func testTitleContainsIgnoresCaseAndSurroundingSpaces() {
        let r = rule(.titleContains(" noname "), .hide)
        XCTAssertTrue(r.matches(window("Draft — NoName 3")))
        XCTAssertFalse(r.matches(window("Draft")))
        XCTAssertFalse(r.matches(appOnly("Noname", pid: 3)), "title rules never match app-only entries")
    }

    func testTitleIsComparesTheWholeTrimmedTitle() {
        let r = rule(.titleIs("Finder"), .hide)
        XCTAssertTrue(r.matches(window(" finder ")))
        XCTAssertFalse(r.matches(window("Finder 2")))
    }

    func testHidingRuleWinsOverDemotingOne() {
        let rules = ExceptionRules([rule(.titleContains("a"), .bottom), rule(.titleContains("ab"), .hide)])
        XCTAssertEqual(rules.outcome(for: window("abc")), .hide)
        XCTAssertEqual(rules.outcome(for: window("ac")), .bottom)
        XCTAssertNil(rules.outcome(for: window("xyz")))
    }

    func testInvalidRulesAreIgnored() {
        let rules = ExceptionRules([rule(.titleContains("  "), .hide), rule(.titleIs("x"), .hideIfNoWindows)])
        XCTAssertTrue(rules.rules.isEmpty)
        XCTAssertNil(rules.outcome(for: window("x")))
    }

    // MARK: - Grouping

    private func shape(_ groups: WindowGroups) -> [String] {
        var out: [String] = []
        if !groups.main.isEmpty { out.append("main: " + groups.main.map(\.displayTitle).joined(separator: ",")) }
        if !groups.bottom.isEmpty {
            out.append("bottom: " + groups.bottom.map { "\($0.window.displayTitle) (\($0.note))" }
                .joined(separator: ","))
        }
        return out
    }

    let w1 = window("Inbox", pid: 1)
    let w2 = window("Noname 1", pid: 1)
    let w3 = window("Noname 2", pid: 2, minimized: true)
    let w4 = window("Secret", pid: 2)
    let appF = appOnly("Finder", pid: 3, bundle: "com.apple.finder")
    let appG = appOnly("Mail", pid: 4)

    var fixture: Enumeration { enumeration([w1, w2, w3, w4], apps: [appF, appG]) }

    func testRulesHideAndDemote() {
        let rules = ExceptionRules([rule(.titleContains("noname"), .bottom), rule(.titleIs("secret"), .hide),
                                    rule(.app(finder), .hideIfNoWindows)])
        let got = WindowGrouping.groups(for: profile(), enumeration: fixture, activeAppPID: 1, exceptions: rules)
        XCTAssertEqual(shape(got), ["main: Inbox", "bottom: Noname 1 (Exception),Noname 2 (Exception),Mail (No Windows)"])
    }

    func testSwitcherHidingWinsOverAnExceptionThatDemotes() {
        let rules = ExceptionRules([rule(.titleContains("noname"), .bottom), rule(.app(finder), .bottom)])
        let p = profile(minimized: .hide, apps: .hide)
        let got = WindowGrouping.groups(for: p, enumeration: fixture, activeAppPID: 1, exceptions: rules)
        XCTAssertEqual(shape(got), ["main: Inbox,Secret", "bottom: Noname 1 (Exception)"])
    }

    func testDemotedAppOnlyEntryMovesToBottomWhenAppsAreShown() {
        let rules = ExceptionRules([rule(.app(finder), .bottom)])
        let got = WindowGrouping.groups(for: profile(apps: .show), enumeration: fixture, activeAppPID: 1,
                                        exceptions: rules)
        XCTAssertEqual(shape(got), ["main: Inbox,Noname 1,Secret,Mail", "bottom: Noname 2 (Minimized),Finder (No Windows)"])
    }

    func testSearchSkipsHiddenAndNotesDemoted() {
        let rules = ExceptionRules([rule(.titleIs("secret"), .hide), rule(.titleContains("noname"), .bottom)])
        let pool = WindowGrouping.searchPool(for: profile(), enumeration: fixture, activeAppPID: 1, exceptions: rules)
        XCTAssertEqual(pool.map(\.title), ["Inbox", "Noname 1", "Noname 2"])
        XCTAssertEqual(WindowGrouping.note(for: w2, profile: profile(), enumeration: fixture, exceptions: rules),
                       "Exception")
        XCTAssertNil(WindowGrouping.note(for: w1, profile: profile(), enumeration: fixture, exceptions: rules))
    }

    func testSessionNeverPreselectsAHiddenWindow() {
        let rules = ExceptionRules([rule(.titleContains("noname"), .hide)])
        let s = SwitcherSession(profile: profile(), enumeration: fixture, activeAppPID: 1,
                                exceptions: rules, forward: true)
        XCTAssertEqual(s.selectedWindow?.title, "Secret")
    }

    // MARK: - Storage

    func testRoundTripsAndDropsBadRules() throws {
        let json = """
        { "version": 1, "rules": [
          { "id": "6F1C0000-0000-0000-0000-000000000001",
            "app": { "bundleID": "com.apple.finder", "name": "Finder" }, "action": "hideIfNoWindows" },
          { "titleContains": "Noname", "action": "bottom" },
          { "titleIs": "Finder", "action": "hideIfNoWindows" },
          { "titleIs": "", "action": "hide" },
          { "titleIs": "x", "action": "explode" },
          { "windowClass": "x", "action": "hide" },
          42
        ] }
        """
        let file = try JSONDecoder().decode(ExceptionRuleFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.rules.map(\.target), [.app(finder), .titleContains("Noname")])
        XCTAssertEqual(file.dropped, 5)

        let again = try JSONDecoder().decode(ExceptionRuleFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(again.rules, file.rules)
        XCTAssertEqual(again.dropped, 0)
    }
}

@MainActor
final class ExceptionSettingsTests: XCTestCase {
    private let suite = "wicher.tests.exceptions"
    nonisolated(unsafe) private let defaults = UserDefaults(suiteName: "wicher.tests.exceptions")!

    override func setUp() { defaults.removePersistentDomain(forName: suite) }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testRulesPersist() {
        let settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.exceptionRules.isEmpty)
        let r = ExceptionRule(target: .titleIs("Finder"), action: .hide)
        settings.exceptionRules = [r]
        settings[exceptionID: r.id].action = .bottom
        XCTAssertEqual(Settings(defaults: defaults).exceptionRules.map(\.action), [.bottom])
    }

    func testSeenAppsAddsOnlyNewAppsNewestFirst() {
        let settings = Settings(defaults: defaults)
        settings.noteSeenApps(in: [.item(window("a", app: "Mail", bundle: "com.apple.mail"), [])])
        settings.noteSeenApps(in: [.item(window("b", app: "Notes", bundle: "com.apple.notes"), []),
                                   .item(window("c", app: "Mail", bundle: "com.apple.mail"), []),
                                   .separator,
                                   .item(window("", app: "loginwindow"), [])])
        XCTAssertEqual(settings.seenApps.map(\.name), ["Notes", "loginwindow", "Mail"])
        XCTAssertEqual(Settings(defaults: defaults).seenApps, settings.seenApps)
    }
}
