import XCTest
@testable import WicherCore

final class IconGridLayoutTests: XCTestCase {
    private func make(_ count: Int, icon: Int = 96, padding: Int = 8, spacing: Int = 12,
                      max: CGFloat = 1400) -> IconGridLayout {
        IconGridLayout.make(iconSize: icon, padding: padding, textSize: 13, spacing: spacing,
                            itemCount: count, maxPanelWidth: max)
    }

    func testFitsAsIsWhenThereIsRoom() {
        let l = make(5)
        XCTAssertEqual(l.scale, 1)
        XCTAssertEqual(l.iconSize, 96)
        XCTAssertEqual(l.cellSize, 77 + 2 * 8)   // the icon's visible shape, 824/1024 of the image
        XCTAssertEqual(l.cellFrames.count, 5)
        let row = 5 * l.cellSize + 4 * 12
        XCTAssertEqual(l.panelSize.width, row + 2 * l.inset)
        // Left to right, evenly spaced, on one line.
        for (a, b) in zip(l.cellFrames, l.cellFrames.dropFirst()) {
            XCTAssertEqual(b.minX - a.maxX, 12)
            XCTAssertEqual(a.minY, b.minY)
        }
        XCTAssertEqual(l.cellFrames.first?.minX, l.inset)
        XCTAssertEqual(l.cellFrames.last?.maxX, l.panelSize.width - l.inset)
    }

    func testPaddingIsTheSameOnEverySide() {
        let l = make(5)
        let cells = l.cellFrames
        XCTAssertEqual(cells[0].minY, l.inset)
        XCTAssertEqual(l.panelSize.height - cells[0].maxY, l.inset, "as much below the icons as above")
        XCTAssertEqual(cells[0].minX, l.inset)
        XCTAssertGreaterThanOrEqual(l.inset, IconGridLayout.minInset)
    }

    func testTitleSitsInsideTheBottomPadding() {
        let l = make(3)
        let title = l.titleFrame(forItem: 1, textWidth: 50)
        XCTAssertEqual(title.minY, l.cellFrames[1].maxY + IconGridLayout.titleGap)
        XCTAssertEqual(l.panelSize.height - title.maxY, IconGridLayout.titleBottomGap)
    }

    func testPaddingWidensTheHighlightAroundTheIcon() {
        let tight = make(3, padding: 0)
        let loose = make(3, padding: 20)
        XCTAssertEqual(tight.cellSize, 77, "padding 0: the highlight is exactly the icon's shape, hidden behind it")
        XCTAssertEqual(tight.highlightCornerRadius, (96 * IconGridLayout.iconCornerFraction).rounded())
        XCTAssertEqual(loose.cellSize, 77 + 40)
        XCTAssertEqual(loose.highlightCornerRadius - tight.highlightCornerRadius, 20, "concentric with the icon")
    }

    func testShrinksProportionallyToTheMaximumWidth() {
        let l = make(40, max: 1000)
        XCTAssertLessThan(l.scale, 1)
        XCTAssertLessThanOrEqual(l.panelSize.width, 1000)
        XCTAssertLessThanOrEqual(l.cellFrames.last!.maxX, 1000 - l.inset)
        XCTAssertEqual(l.iconSize, (96 * l.scale).rounded(.down))
        XCTAssertEqual(l.padding, (8 * l.scale).rounded(.down))
        XCTAssertEqual(l.spacing, (12 * l.scale).rounded(.down))
        XCTAssertEqual(l.titleSize, 13, "text keeps its size")
        // Nearly fills the width: flooring loses at most a few points per icon.
        XCTAssertGreaterThan(l.panelSize.width, 1000 - 40 * 3)
    }

    func testNeverShrinksBelowTheMinimumIcon() {
        XCTAssertEqual(make(500, max: 800).iconSize, IconGridLayout.minIconSize)
    }

    func testOneIconGetsAPanelJustItsSize() {
        let l = make(1)
        XCTAssertEqual(l.panelSize.width, l.cellSize + 2 * l.inset)
        XCTAssertEqual(l.cellFrames[0].minX, l.inset)
        XCTAssertEqual(make(0).panelSize.width, IconGridLayout.emptyPanelWidth, "room for \"No windows\"")
    }

    func testEmptyKeepsTheRowHeight() {
        XCTAssertEqual(make(0).panelSize.height, make(3).panelSize.height)
        XCTAssertTrue(make(0).cellFrames.isEmpty)
    }

    func testCornersAreConcentric() {
        let l = make(3)
        XCTAssertEqual(l.panelCornerRadius, l.highlightCornerRadius + l.inset)
    }

    func testTitleIsCenteredUnderItsIcon() {
        let l = make(8)
        XCTAssertEqual(l.titleFrame(forItem: 4, textWidth: 100).midX, l.cellFrames[4].midX, accuracy: 1)
    }

    func testTitleNearAnEdgeIsSlidInside() {
        let l = make(8)
        XCTAssertEqual(l.titleFrame(forItem: 0, textWidth: 400).minX, l.inset)
        XCTAssertEqual(l.titleFrame(forItem: 7, textWidth: 400).maxX, l.panelSize.width - l.inset)
    }

    func testLongTitleIsCappedToThePanel() {
        let l = make(3)
        let title = l.titleFrame(forItem: 1, textWidth: 5000)
        XCTAssertEqual(title.minX, l.inset)
        XCTAssertEqual(title.width, l.panelSize.width - 2 * l.inset)
    }

    private func make(rows: [Int], max: CGFloat = 1400) -> IconGridLayout {
        IconGridLayout.make(iconSize: 96, padding: 8, textSize: 13, spacing: 12, rowCounts: rows, maxPanelWidth: max)
    }

    func testSecondRowSitsBelowASeparator() throws {
        let l = make(rows: [5, 3])
        XCTAssertEqual(l.rows, [0..<5, 5..<8])
        let top = l.cellFrames[0], bottom = l.cellFrames[5]
        let line = try XCTUnwrap(l.separatorFrame)
        XCTAssertEqual(line.minY - top.maxY, IconGridLayout.separatorGap)
        XCTAssertEqual(bottom.minY - line.maxY, IconGridLayout.separatorGap)
        XCTAssertEqual(line.minX, l.inset)
        XCTAssertEqual(line.maxX, l.panelSize.width - l.inset)
        XCTAssertEqual(l.panelSize.width, make(5).panelSize.width, "as wide as the longer row")
        XCTAssertEqual(l.panelSize.height - l.cellFrames[7].maxY, l.inset)
        XCTAssertEqual(l.titleFrame(forItem: 6, textWidth: 50).minY, bottom.maxY + IconGridLayout.titleGap)
        XCTAssertEqual(l.titleFrame(forItem: 0, textWidth: 50).midX, l.panelSize.width / 2, accuracy: 1,
                       "centered with two rows")
    }

    func testShorterRowIsCentered() {
        for rows in [[5, 2], [2, 5]] {
            let l = make(rows: rows)
            let short = rows[0] < rows[1] ? l.rows[0] : l.rows[1]
            let midX = (l.cellFrames[short.first!].minX + l.cellFrames[short.last!].maxX) / 2
            XCTAssertEqual(midX, l.panelSize.width / 2, accuracy: 1, "\(rows)")
        }
    }

    func testBothRowsShareTheScaleOfTheWiderOne() {
        let l = make(rows: [3, 40], max: 1000)
        XCTAssertLessThan(l.scale, 1)
        XCTAssertEqual(l.cellFrames[0].size, l.cellFrames[3].size)
        XCTAssertEqual(l.iconSize, make(40, max: 1000).iconSize)
    }

    func testEmptyRowsAreDropped() {
        let l = make(rows: [0, 3])
        XCTAssertEqual(l.rows, [0..<3])
        XCTAssertNil(l.separatorFrame)
        XCTAssertEqual(l, make(3))
    }

    func testMovingRowsPicksTheNearestIcon() {
        let l = make(rows: [5, 3])
        XCTAssertEqual(l.item(2, movedRows: 1), 6, "middle to middle")
        XCTAssertEqual(l.item(0, movedRows: 1), 5)
        XCTAssertEqual(l.item(4, movedRows: 1), 7)
        XCTAssertEqual(l.item(7, movedRows: -1), 3)
        XCTAssertEqual(l.item(1, movedRows: -1), 1, "no row above")
        XCTAssertNil(make(5).item(1, movedRows: 1), "a single row has none")
    }

    func testWindowAddsTheGlassMargin() {
        let l = make(3)
        XCTAssertEqual(l.windowSize,
                       CGSize(width: l.panelSize.width + 2 * HUDMetrics.glassWindowMargin,
                              height: l.panelSize.height + 2 * HUDMetrics.glassWindowMargin))
    }
}
