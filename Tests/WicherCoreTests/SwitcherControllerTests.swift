import AppKit
import Carbon.HIToolbox
import XCTest
@testable import WicherCore

/// Session lifecycle with a fake window source, injected modifier state and
/// a recording activator. The show delay is long, so the panel stays hidden
/// unless typing brings it up.
@MainActor
final class SwitcherControllerTests: XCTestCase {
    private final class FakeWindows: WindowSource {
        var current: Enumeration
        init(_ current: Enumeration) { self.current = current }
        func enumerate() -> Enumeration { current }
        func latestSnapshot() -> Enumeration? { current }
        func noteFrontmost(pid: pid_t) {}
    }

    private let suite = "wicher.tests.controller"
    private var fake = FakeWindows(enumeration([window("A", pid: 1, wid: 10),
                                                window("B", pid: 2, wid: 20),
                                                window("C", pid: 3, wid: 30)]))
    private var held: NSEvent.ModifierFlags = .option
    private var activated: [String] = []
    private var settings: Settings!
    private var controller: SwitcherController!
    /// ⌥Tab.
    private let optionTab = profile(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(optionKey))

    override func setUp() {
        UserDefaults().removePersistentDomain(forName: suite)
        settings = Settings(defaults: UserDefaults(suiteName: suite)!)
        settings.showDelayMs = 60_000
        controller = SwitcherController(windows: fake, settings: settings,
                                        activate: { [unowned self] in activated.append($0.displayTitle) },
                                        heldModifiers: { [unowned self] in held })
    }

    override func tearDown() {
        // Ends any session, so its event monitors go.
        while controller.session != nil { controller.perform(.cancelOrClear) }
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testReleasingTheTriggerCommitsThePreselection() {
        controller.hotKey(profile: optionTab, forward: true, pressed: true)
        XCTAssertNotNil(controller.session)
        controller.modifiersChanged([.shift])
        XCTAssertEqual(activated, ["B"], "the previous window is preselected")
        XCTAssertNil(controller.session)
    }

    func testHeldPressesAdvanceBeforeRelease() {
        controller.hotKey(profile: optionTab, forward: true, pressed: true)
        controller.hotKey(profile: optionTab, forward: true, pressed: false)
        controller.hotKey(profile: optionTab, forward: true, pressed: true)
        controller.modifiersChanged([])
        XCTAssertEqual(activated, ["C"])
    }

    func testReleasedBeforeTheSessionWasBuiltCommitsAtOnce() {
        held = []
        controller.hotKey(profile: optionTab, forward: true, pressed: true)
        XCTAssertEqual(activated, ["B"])
        XCTAssertNil(controller.session)
    }

    func testEscClearsTheSearchBeforeClosing() {
        controller.hotKey(profile: optionTab, forward: true, pressed: true)
        controller.perform(.type("c"))
        XCTAssertEqual(controller.session?.query, "c")
        controller.perform(.cancelOrClear)
        XCTAssertNotNil(controller.session)
        XCTAssertEqual(controller.session?.query, "")
        controller.perform(.cancelOrClear)
        XCTAssertNil(controller.session)
        XCTAssertEqual(activated, [], "Esc never switches")
    }

    func testRefreshBeforeThePanelIsShownKeepsThePreselection() {
        controller.hotKey(profile: optionTab, forward: true, pressed: true)
        fake.current = enumeration([window("C", pid: 3, wid: 30), window("A", pid: 1, wid: 10)])
        NotificationCenter.default.post(name: WindowEnumerator.didRefresh, object: fake)
        controller.modifiersChanged([])
        XCTAssertEqual(activated, ["B"], "a quick tap commits what was preselected")
    }

    func testRefreshReachesAShownPanel() {
        settings.showDelayMs = 0
        controller.hotKey(profile: optionTab, forward: true, pressed: true)
        fake.current = enumeration([window("C", pid: 3, wid: 30), window("A", pid: 1, wid: 10)])
        NotificationCenter.default.post(name: WindowEnumerator.didRefresh, object: fake)
        let titles = controller.session?.rows.compactMap { row -> String? in
            if case let .item(window, _, _) = row { return window.displayTitle }
            return nil
        }
        XCTAssertEqual(titles, ["C", "A"])
    }
}
