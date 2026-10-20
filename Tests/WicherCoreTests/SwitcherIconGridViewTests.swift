import AppKit
import XCTest
@testable import WicherCore

/// The Icons layout rendered offscreen — no panel.
@MainActor
final class SwitcherIconGridViewTests: XCTestCase {
    private func makeView() -> SwitcherIconGridView {
        let view = SwitcherIconGridView()
        view.configure(iconSize: 96, padding: 8, textSize: 13, spacing: 12, maxPanelWidth: 1400)
        return view
    }

    private func render(_ view: SwitcherIconGridView, _ rows: [DisplayRow]) {
        view.render(rows)
        view.frame = NSRect(origin: .zero, size: view.preferredWindowSize)
        view.layoutSubtreeIfNeeded()
    }

    private func cells(_ view: NSView) -> [SwitcherIconCellView] {
        if let cell = view as? SwitcherIconCellView { return cell.isHidden ? [] : [cell] }
        return view.subviews.flatMap(cells).sorted { $0.frame.minX < $1.frame.minX }
    }

    private func titleField(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.lineBreakMode == .byTruncatingMiddle { return field }
        return view.subviews.lazy.compactMap(titleField).first
    }

    private let sample: [DisplayRow] = [
        .item(window("Inbox", app: "Mail"), []),
        .item(window("Notes", app: "Notes"), []),
        .header("Minimized"),
        .item(window("Old", app: "Mail", minimized: true), []),
    ]

    func testOneCellPerItemAtTheLayoutsFrames() {
        let view = makeView()
        render(view, sample)
        let frames = cells(view).map(\.frame)
        XCTAssertEqual(frames, view.layoutInfo.cellFrames)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(cells(view).map(\.displayIndex), [0, 1, 3])
        XCTAssertEqual(frames[2].minX - frames[1].maxX, frames[1].minX - frames[0].maxX,
                       "no extra gap where the Minimized section starts")
    }

    func testCellsAreReusedAcrossRenders() {
        let view = makeView()
        render(view, sample)
        let before = Set(cells(view).map(ObjectIdentifier.init))
        render(view, Array(sample.prefix(2)))
        XCTAssertEqual(cells(view).count, 2)
        render(view, sample)
        XCTAssertEqual(Set(cells(view).map(ObjectIdentifier.init)), before)
    }

    func testTitleFollowsHoverThenSelection() throws {
        let view = makeView()
        render(view, sample)
        let title = try XCTUnwrap(titleField(view))
        XCTAssertTrue(title.isHidden, "nothing selected yet")

        view.highlight(rowIndex: 1)
        XCTAssertFalse(title.isHidden)
        XCTAssertEqual(title.stringValue, "Notes")
        XCTAssertGreaterThanOrEqual(title.frame.width, title.attributedStringValue.size().width,
                                    "a short title is not truncated")
        XCTAssertEqual(title.frame.midX, cells(view)[1].frame.midX, accuracy: 1)

        view.setHovered(rowIndex: 3)
        XCTAssertEqual(title.stringValue, "Old")
        view.setHovered(rowIndex: nil)
        XCTAssertEqual(title.stringValue, "Notes")

        view.appearance = NSAppearance(named: .aqua)   // dark text on the (unrendered) glass
        if let dir = ProcessInfo.processInfo.environment["WICHER_SNAPSHOT_DIR"],
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("icons.png"))
        }
    }

    func testLongTitleIsTruncatedInsideThePanel() throws {
        let view = makeView()
        let long = String(repeating: "A very long window title ", count: 20)
        render(view, [.item(window(long), []), .item(window("Short"), [])])
        view.highlight(rowIndex: 0)
        let title = try XCTUnwrap(titleField(view))
        XCTAssertGreaterThanOrEqual(title.frame.minX, view.layoutInfo.inset)
        XCTAssertLessThanOrEqual(title.frame.maxX, view.layoutInfo.panelSize.width - view.layoutInfo.inset)
    }

    func testEmptyState() {
        let view = makeView()
        view.setQuery("zzz")
        render(view, [])
        func labels(_ view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(labels)
        }
        XCTAssertTrue(labels(view).contains { $0.stringValue == "No matching windows" && !$0.isHidden })
        XCTAssertEqual(view.preferredWindowSize.width,
                       IconGridLayout.emptyPanelWidth + 2 * HUDMetrics.glassWindowMargin)
    }

    /// The search text sits in the top padding, mirroring the title in the
    /// bottom one, so searching doesn't grow the panel.
    func testSearchingKeepsThePanelSize() throws {
        let view = makeView()
        render(view, sample)
        let before = view.preferredWindowSize
        view.setQuery("in")
        render(view, Array(sample.prefix(2)))
        XCTAssertEqual(view.preferredWindowSize.height, before.height)
        view.highlight(rowIndex: 0)
        view.layoutSubtreeIfNeeded()
        let search = try XCTUnwrap(labels(view).first { $0.stringValue.hasSuffix("in") })
        let title = try XCTUnwrap(titleField(view))
        let panel = view.layoutInfo.panelSize.height
        let searchTop = search.convert(search.bounds, to: view).midY   // unflipped: from the bottom
        let titleBottom = title.convert(title.bounds, to: view).midY
        let margin = HUDMetrics.glassWindowMargin
        XCTAssertEqual(margin + panel - searchTop, titleBottom - margin, accuracy: 1.5,
                       "the search text is as far from the top as the title is from the bottom")
        XCTAssertEqual(search.font?.pointSize, title.font?.pointSize)

        // Centered: the symbol + text group sits mid-panel.
        let symbol = try XCTUnwrap(images(view).first { $0.image?.isTemplate == true && !$0.isHidden })
        let group = symbol.convert(symbol.bounds, to: view).union(search.convert(search.bounds, to: view))
        XCTAssertEqual(group.midX, view.bounds.midX, accuracy: 1.5)
    }

    /// Typing grows the text a letter at a time; each width must follow the
    /// whole text, not the last frame (it showed "wic…").
    func testSearchTextIsNotTruncatedWhileTyping() throws {
        let view = makeView()
        render(view, sample)
        for query in ["w", "wi", "wic", "wich", "wicher"] {
            view.setQuery(query)
            view.layoutSubtreeIfNeeded()
            let field = try XCTUnwrap(labels(view).first { $0.stringValue == query })
            XCTAssertGreaterThanOrEqual(field.frame.width, field.attributedStringValue.size().width, query)
        }
    }

    func testSearchMatchesAreColored() throws {
        let view = makeView()
        view.setQuery("box")
        render(view, [.item(window("Inbox", app: "Mail"), [NSRange(location: 2, length: 3)])])
        view.highlight(rowIndex: 0)
        let title = try XCTUnwrap(titleField(view)).attributedStringValue
        XCTAssertEqual(title.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor, .searchMatch)
        XCTAssertNil(title.attribute(.foregroundColor, at: 0, effectiveRange: nil))

        view.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        if let dir = ProcessInfo.processInfo.environment["WICHER_SNAPSHOT_DIR"],
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("icons-search.png"))
        }
    }

    private func images(_ view: NSView) -> [NSImageView] {
        ((view as? NSImageView).map { [$0] } ?? []) + view.subviews.flatMap(images)
    }

    private func labels(_ view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(labels)
    }
}
