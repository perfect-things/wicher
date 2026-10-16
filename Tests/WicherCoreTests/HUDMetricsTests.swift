import XCTest
@testable import WicherCore

final class HUDMetricsTests: XCTestCase {
    func testClampsBelowRanges() {
        let m = HUDMetrics.make(iconSize: 0, textSize: 0, rowPadding: -5)
        XCTAssertEqual(m.iconSize, 16)
        XCTAssertEqual(m.titleSize, 10)
        XCTAssertEqual(m.rowHeight, 16)        // max(16, 10) + 0 padding
        XCTAssertEqual(m.appSize, 10)          // floor of 10
        XCTAssertEqual(m.headerHeight, 20)     // floor of 20
        XCTAssertEqual(m.panelWidth, 536)      // 440 + 16 * 6
        XCTAssertEqual(m.appColumnWidth, 134)  // 25% of 536
    }

    func testClampsAboveRanges() {
        let m = HUDMetrics.make(iconSize: 500, textSize: 500, rowPadding: 500)
        XCTAssertEqual(m.iconSize, 56)
        XCTAssertEqual(m.titleSize, 32)
        XCTAssertEqual(m.rowHeight, 56 + 40 * 2)
        XCTAssertEqual(m.appSize, 26)          // 32 * 0.82, rounded
        XCTAssertEqual(m.headerHeight, 48)     // 32 * 1.5
        XCTAssertEqual(m.panelWidth, 776)      // 440 + 56 * 6
        XCTAssertEqual(m.appColumnWidth, 194)  // 25% of 776
    }

    func testRangeBoundsPassThrough() {
        let lo = HUDMetrics.make(iconSize: HUDMetrics.iconRange.lowerBound,
                                 textSize: HUDMetrics.textRange.lowerBound,
                                 rowPadding: HUDMetrics.paddingRange.lowerBound)
        XCTAssertEqual(lo.iconSize, 16)
        XCTAssertEqual(lo.titleSize, 10)
        XCTAssertEqual(lo.rowHeight, 16)

        let hi = HUDMetrics.make(iconSize: HUDMetrics.iconRange.upperBound,
                                 textSize: HUDMetrics.textRange.upperBound,
                                 rowPadding: HUDMetrics.paddingRange.upperBound)
        XCTAssertEqual(hi.iconSize, 56)
        XCTAssertEqual(hi.titleSize, 32)
        XCTAssertEqual(hi.rowHeight, 136)
    }

    func testTextTallerThanIconDrivesRowHeight() {
        let m = HUDMetrics.make(iconSize: 16, textSize: 30, rowPadding: 4)
        XCTAssertEqual(m.rowHeight, 30 + 8)
    }

    func testHighlightCornersAreConcentricWithPanel() {
        let m = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7)
        XCTAssertEqual(m.rowCornerRadius + m.listInset, m.panelCornerRadius)
    }

    func testHighlightRadiusNeverExceedsACapsule() {
        let tight = HUDMetrics.make(iconSize: 16, textSize: 10, rowPadding: 0)
        XCTAssertEqual(tight.rowCornerRadius, tight.rowHeight / 2)
    }

    func testWindowAddsMarginOnEverySide() {
        let m = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7)
        XCTAssertEqual(m.windowSize(panelHeight: 100),
                       CGSize(width: m.panelWidth + 2 * m.windowMargin, height: 100 + 2 * m.windowMargin))
    }

    func testHidingAppNamesDropsTheColumnOnly() {
        let on = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7)
        let off = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7, showAppNames: false)
        XCTAssertEqual(off.appColumnWidth, 0)
        XCTAssertEqual(off.panelWidth, on.panelWidth)
        XCTAssertEqual(off.rowHeight, on.rowHeight)
        XCTAssertNotEqual(on, off, "a toggle must rebuild the row pool")
    }

    func testWidthScaleMultipliesTheIconDerivedWidth() {
        let base = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7)
        let narrow = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7, widthScale: 80)
        let wide = HUDMetrics.make(iconSize: 48, textSize: 16, rowPadding: 7, widthScale: 120)
        XCTAssertEqual(base.panelWidth, 632)
        XCTAssertEqual(narrow.panelWidth, (632 * 0.8).rounded())
        XCTAssertEqual(wide.panelWidth, (728 * 1.2).rounded())    // still follows icon size
        XCTAssertEqual(narrow.appColumnWidth, (narrow.panelWidth / 4).rounded(.down))   // keeps its share
    }

    func testNarrowestWidthStillLeavesRoomForATitle() {
        for names in [true, false] {
            let m = HUDMetrics.make(iconSize: 56, textSize: 16, rowPadding: 7, widthScale: 0, showAppNames: names)
            let used = 2 * m.listInset + HUDMetrics.rowLeadingInset
                + (names ? m.appColumnWidth + HUDMetrics.appToIcon : 0)
                + m.iconSize + HUDMetrics.iconToTitle + HUDMetrics.rowTrailingInset
            XCTAssertEqual(m.panelWidth - used, HUDMetrics.minTitleWidth, accuracy: 1)
        }
        let small = HUDMetrics.make(iconSize: 16, textSize: 16, rowPadding: 7, widthScale: 30, showAppNames: false)
        XCTAssertEqual(small.panelWidth, 194)    // 30% would be 161: the floor wins
    }
}
