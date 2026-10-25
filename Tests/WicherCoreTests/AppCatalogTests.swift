import XCTest
@testable import WicherCore

final class AppCatalogTests: XCTestCase {
    func choice(_ name: String, _ bundleID: String? = nil) -> AppChoice {
        AppChoice(app: AppRef(bundleID: bundleID, name: name))
    }

    lazy var finder = choice("Finder", "com.apple.finder")
    lazy var safari = choice("Safari", "com.apple.Safari")
    lazy var loginwindow = choice("loginwindow")
    lazy var notes = choice("Notes", "com.apple.Notes")

    func titles(_ sections: [AppSection]) -> [String] { sections.map(\.title) }

    func testEachAppOnceInTheFirstSectionThatHasIt() {
        let sections = AppCatalog.sections(running: [finder, safari], seen: [loginwindow, finder],
                                           installed: [safari, notes], query: "")
        XCTAssertEqual(sections, [
            AppSection(title: "Running Now", apps: [finder, safari]),
            AppSection(title: "Seen by Wicher", apps: [loginwindow]),
            AppSection(title: "Installed", apps: [notes]),
        ])
    }

    func testEmptySectionsAreDropped() {
        let sections = AppCatalog.sections(running: [finder], seen: [finder], installed: [], query: "")
        XCTAssertEqual(titles(sections), ["Running Now"])
    }

    func testQueryMatchesNameOrBundleIDIgnoringCaseAndSpaces() {
        let sections = AppCatalog.sections(running: [finder, safari], seen: [loginwindow],
                                           installed: [notes], query: "  FIND ")
        XCTAssertEqual(sections, [AppSection(title: "Running Now", apps: [finder])])
        let byBundle = AppCatalog.sections(running: [finder, safari], seen: [loginwindow],
                                           installed: [notes], query: "apple.notes")
        XCTAssertEqual(byBundle, [AppSection(title: "Installed", apps: [notes])])
    }

    /// An app belongs to the first section that has it, whatever the query:
    /// filtered out there, it doesn't turn up further down instead.
    func testDedupingIgnoresTheQuery() {
        let renamed = choice("Finder Renamed", "com.apple.finder")
        let sections = AppCatalog.sections(running: [finder], seen: [], installed: [renamed], query: "renamed")
        XCTAssertEqual(sections, [])
    }

    func testNoMatchesNoSections() {
        XCTAssertEqual(AppCatalog.sections(running: [finder], seen: [loginwindow], installed: [notes],
                                           query: "zzz"), [])
    }
}
