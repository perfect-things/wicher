import AppKit
import XCTest
@testable import WicherCore

/// Layout of the pooled, frame-placed list. Rendered offscreen — no panel.
@MainActor
final class SwitcherListViewTests: XCTestCase {
    private let metrics = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7)

    private func makeView(height: CGFloat = 400) -> SwitcherListView {
        let view = SwitcherListView()
        view.frame = NSRect(origin: .zero, size: metrics.windowSize(panelHeight: height))
        return view
    }

    /// `count` main-group rows, then — behind a separator — `bottom` rows noted "Minimized".
    private func rows(_ count: Int, bottom: Int = 0) -> [DisplayRow] {
        var rows: [DisplayRow] = (0..<count).map { .item(window("Window \($0)", app: "App \($0)"), []) }
        if count > 0 && bottom > 0 { rows.append(.separator) }
        rows += (0..<bottom).map { .item(window("Old \($0)", app: "App", minimized: true), [], note: "Minimized") }
        return rows
    }

    private func separator(_ view: SwitcherListView) -> HUDSeparatorView? {
        documentSubviews(view).compactMap { $0 as? HUDSeparatorView }.first
    }

    private func labels(_ row: NSView) -> [NSTextField] {
        row.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    private func rowFrames(_ view: SwitcherListView) -> [NSRect] {
        rowSubviews(view).filter { !$0.isHidden }.map(\.frame)
    }

    private func rowSubviews(_ view: SwitcherListView) -> [NSView] {
        let scroll = scrollView(in: view)!
        return scroll.documentView!.subviews
            .filter { $0 is SwitcherRowView }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    private func documentSubviews(_ view: SwitcherListView) -> [NSView] {
        scrollView(in: view)!.documentView!.subviews
    }

    func testRowsAreStackedTopToBottomAtFixedHeights() {
        let view = makeView()
        view.render(rows(1, bottom: 2), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        let frames = rowFrames(view)
        let top = metrics.listInset
        XCTAssertEqual(frames.map(\.minY), [top,
                                            top + metrics.rowHeight + metrics.separatorHeight,
                                            top + 2 * metrics.rowHeight + metrics.separatorHeight])
        XCTAssertEqual(frames.map(\.height), Array(repeating: metrics.rowHeight, count: 3))
        XCTAssertTrue(frames.allSatisfy { $0.minX == metrics.listInset && $0.width == metrics.panelWidth - 2 * metrics.listInset })

        let line = try! XCTUnwrap(separator(view))
        XCTAssertFalse(line.isHidden)
        XCTAssertEqual(line.frame.height, 1)
        XCTAssertGreaterThan(line.frame.minY, frames[0].maxY)
        XCTAssertLessThan(line.frame.maxY, frames[1].minY)
        XCTAssertEqual(view.preferredHeight(maxListHeight: 1000),
                       2 * metrics.listInset + 3 * metrics.rowHeight + metrics.separatorHeight)
    }

    func testNoSeparatorWithoutOne() {
        let view = makeView()
        view.render(rows(1, bottom: 2), metrics: metrics)
        view.render(rows(3), metrics: metrics)
        XCTAssertEqual(separator(view)?.isHidden, true)
    }

    /// Bottom rows end in a faint note; a pooled row reused for the main group loses it.
    func testBottomRowsShowTheirNote() throws {
        let view = makeView()
        view.render(rows(1, bottom: 1), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        let rows2 = rowSubviews(view)
        rows2.forEach { $0.layoutSubtreeIfNeeded() }
        XCTAssertFalse(labels(rows2[0]).contains { $0.stringValue == "Minimized" })
        let bottomRow = rows2[1]
        let note = try XCTUnwrap(labels(bottomRow).first { $0.stringValue == "Minimized" })
        let title = try XCTUnwrap(labels(bottomRow).first { $0.stringValue == "Old 0" })
        XCTAssertEqual(note.frame.maxX, bottomRow.bounds.width - HUDMetrics.rowTrailingInset)
        XCTAssertLessThanOrEqual(title.frame.maxX, note.frame.minX - HUDMetrics.titleToNote)

        view.render(rows(2), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(rowSubviews(view).flatMap(labels).contains { $0.stringValue == "Minimized" })
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
        XCTAssertEqual(view.preferredHeight(maxListHeight: 1000), 2 * metrics.listInset + metrics.rowHeight)
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
            view.appearance = NSAppearance(named: .aqua)   // dark text on the (unrendered) glass
            view.render(rows(3, bottom: 2), metrics: metrics)
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("list.png"))
            }
        }
    }

    private func emptyLabel(_ view: SwitcherListView) -> NSTextField? {
        documentSubviews(view).compactMap { $0 as? NSTextField }.first
    }

    func testEmptyStateMessage() {
        let view = makeView()
        view.setQuery("zzz")
        view.render([], metrics: metrics)
        view.layoutSubtreeIfNeeded()
        let label = emptyLabel(view)
        XCTAssertEqual(label?.isHidden, false)
        XCTAssertEqual(label?.stringValue, "No matching windows")
        XCTAssertEqual(label?.frame.midY ?? 0, metrics.listInset + metrics.rowHeight / 2, accuracy: 1)

        view.setQuery("")
        view.render([], metrics: metrics)
        XCTAssertEqual(emptyLabel(view)?.stringValue, "No windows")

        view.render(rows(1), metrics: metrics)
        XCTAssertEqual(emptyLabel(view)?.isHidden, true)

        if let dir = ProcessInfo.processInfo.environment["WICHER_SNAPSHOT_DIR"] {
            let small = makeView(height: 52 + view.preferredHeight(maxListHeight: 1000))  // resized below
            small.setQuery("zzz")
            small.render([], metrics: metrics)
            small.frame.size = metrics.windowSize(panelHeight: small.preferredHeight(maxListHeight: 1000))
            small.layoutSubtreeIfNeeded()
            if let rep = small.bitmapImageRepForCachingDisplay(in: small.bounds) {
                small.cacheDisplay(in: small.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("empty.png"))
            }
        }
    }

    /// First open after launch: rows are rendered while the view still has its
    /// initial width, then the panel is resized. Rows must follow.
    func testRowsFollowAWidthChangeAfterRender() {
        let view = SwitcherListView()
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 320)   // the panel's initial size
        view.layoutSubtreeIfNeeded()
        view.render(rows(2), metrics: metrics)
        view.frame = NSRect(origin: .zero, size: metrics.windowSize(panelHeight: 200))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(rowFrames(view).map(\.width),
                       Array(repeating: metrics.panelWidth - 2 * metrics.listInset, count: 2))
    }

    func testRowsWithoutAppNamesStartWithTheIcon() {
        let plain = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7, showAppNames: false)
        let view = makeView()
        view.render(rows(1), metrics: plain)
        view.layoutSubtreeIfNeeded()
        let row = rowSubviews(view).compactMap { $0 as? SwitcherRowView }.first!
        row.layoutSubtreeIfNeeded()
        let visible = row.subviews.filter { !$0.isHidden }
        XCTAssertFalse(visible.contains { ($0 as? NSTextField)?.stringValue == "App 0" })
        let icon = visible.first { $0 is NSImageView }!
        XCTAssertEqual(icon.frame.minX, 14)
        let title = visible.first { $0 is NSTextField }!
        XCTAssertGreaterThan(title.frame.minX, icon.frame.maxX)
    }
}
