import AppKit
import XCTest
@testable import WicherCore

@MainActor
final class SurfaceViewTests: XCTestCase {
    /// Solid → Glass left the content twice the glass's size, so the panel
    /// showed empty glass.
    func testContentFillsTheSurfaceAcrossStyleChanges() {
        let view = SurfaceView(surface: .defaultBackground, cornerRadius: 10, blending: .behindWindow, castsShadow: true)
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        view.layoutSubtreeIfNeeded()
        for style in [SurfaceStyle.solid, .glass, .blurred, .glass, .clearGlass, .solid, .clearGlass, .blurred, .solid, .glass] {
            view.surface.style = style
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.content.frame.size, view.bounds.size, "\(style)")
            XCTAssertEqual(view.content.convert(view.content.bounds, to: view), view.bounds, "\(style)")
        }
    }
}
