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

    func testWindowAddsTheGlassMargin() {
        let l = make(3)
        XCTAssertEqual(l.windowSize,
                       CGSize(width: l.panelSize.width + 2 * HUDMetrics.glassWindowMargin,
                              height: l.panelSize.height + 2 * HUDMetrics.glassWindowMargin))
    }
}
