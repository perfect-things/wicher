import AppKit
import XCTest
@testable import WicherCore

/// Layout of the pooled, frame-placed list. Rendered offscreen — no panel.
final class SwitcherListViewTests: XCTestCase {
    private let metrics = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7)

    private func makeView(height: CGFloat = 400) -> SwitcherListView {
        let view = SwitcherListView()
        view.frame = NSRect(x: 0, y: 0, width: metrics.panelWidth, height: height)
        return view
    }

    private func rows(_ count: Int, header: String? = nil) -> [DisplayRow] {
        var rows: [DisplayRow] = header.map { [.header($0)] } ?? []
        rows += (0..<count).map { .item(window("Window \($0)", app: "App \($0)"), []) }
        return rows
    }

    private func rowFrames(_ view: SwitcherListView) -> [NSRect] {
        rowSubviews(view).filter { !$0.isHidden }.map(\.frame)
    }

    private func rowSubviews(_ view: SwitcherListView) -> [NSView] {
        let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first!
        return scroll.documentView!.subviews.sorted { $0.frame.minY < $1.frame.minY }
    }

    func testRowsAreStackedTopToBottomAtFixedHeights() {
        let view = makeView()
        view.render(rows(3, header: "Minimized"), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        let frames = rowFrames(view)
        XCTAssertEqual(frames.map(\.minY), [6, 6 + metrics.headerHeight,
                                            6 + metrics.headerHeight + metrics.rowHeight,
                                            6 + metrics.headerHeight + 2 * metrics.rowHeight])
        XCTAssertEqual(frames.map(\.height), [metrics.headerHeight] + Array(repeating: metrics.rowHeight, count: 3))
        XCTAssertTrue(frames.allSatisfy { $0.minX == 8 && $0.width == metrics.panelWidth - 16 })
    }

    func testViewsAreReusedAcrossRenders() {
        let view = makeView()
        view.render(rows(5), metrics: metrics)
        let before = Set(rowSubviews(view).map(ObjectIdentifier.init))
        view.render(rows(2), metrics: metrics)
        view.render(rows(4), metrics: metrics)
        let after = Set(rowSubviews(view).map(ObjectIdentifier.init))
        XCTAssertEqual(before, after, "no new views for a render that fits the pool")
        XCTAssertEqual(rowFrames(view).count, 4)
    }

    func testMetricsChangeRebuildsPool() {
        let view = makeView()
        view.render(rows(2), metrics: metrics)
        let before = Set(rowSubviews(view).map(ObjectIdentifier.init))
        let bigger = HUDMetrics.make(iconSize: 48, textSize: 20, rowPadding: 7)
        view.render(rows(2), metrics: bigger)
        let after = Set(rowSubviews(view).map(ObjectIdentifier.init))
        XCTAssertTrue(before.isDisjoint(with: after))
        XCTAssertEqual(rowSubviews(view).count, 2)
    }

    func testPreferredHeightCapsAndReservesOneRow() {
        let view = makeView()
        view.render([], metrics: metrics)
        XCTAssertEqual(view.preferredHeight(maxListHeight: 1000), 12 + metrics.rowHeight)
        view.render(rows(50), metrics: metrics)
        XCTAssertEqual(view.preferredHeight(maxListHeight: 300), 300)
    }

    func testRowContentIsLaidOutInsideTheRow() {
        let view = makeView()
        view.render(rows(1), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        let row = rowSubviews(view)[0]
        row.layoutSubtreeIfNeeded()
        for sub in row.subviews {
            XCTAssertTrue(row.bounds.contains(sub.frame), "\(sub) at \(sub.frame) escapes \(row.bounds)")
            XCTAssertGreaterThan(sub.frame.width, 0)
        }
        // Snapshot for eyeballing, when asked for.
        if let dir = ProcessInfo.processInfo.environment["WICHER_SNAPSHOT_DIR"] {
            view.render(rows(4, header: "Minimized"), metrics: metrics)
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("list.png"))
            }
        }
    }
}
