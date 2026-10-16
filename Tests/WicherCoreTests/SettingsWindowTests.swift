import AppKit
import XCTest
@testable import WicherCore

/// The Settings window builds, keeps its minimum size, and titles itself after
/// the selected pane. With `WICHER_SNAPSHOT_DIR` set, writes a PNG per pane.
final class SettingsWindowTests: XCTestCase {
    func testPanesRenderAndRetitleWindow() throws {
        _ = NSApplication.shared
        let settings = SettingsWindow()
        settings.build()
        let window = try XCTUnwrap(settings.window)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 600)

        for pane in SettingsPane.allCases {
            settings.model.pane = pane
            XCTAssertEqual(window.title, pane.title)
            guard let dir = ProcessInfo.processInfo.environment["WICHER_SNAPSHOT_DIR"],
                  let view = window.contentView else { continue }
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-\(pane.rawValue).png"))
            }
        }
        window.orderOut(nil)
    }
}
