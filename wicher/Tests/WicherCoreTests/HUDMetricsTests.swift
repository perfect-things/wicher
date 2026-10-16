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
        XCTAssertEqual(m.appColumnWidth, 120)  // floor of 120
    }

    func testClampsAboveRanges() {
        let m = HUDMetrics.make(iconSize: 500, textSize: 500, rowPadding: 500)
        XCTAssertEqual(m.iconSize, 56)
        XCTAssertEqual(m.titleSize, 32)
        XCTAssertEqual(m.rowHeight, 56 + 40 * 2)
        XCTAssertEqual(m.appSize, 26)          // 32 * 0.82, rounded
        XCTAssertEqual(m.headerHeight, 48)     // 32 * 1.5
        XCTAssertEqual(m.panelWidth, 776)      // 440 + 56 * 6
        XCTAssertEqual(m.appColumnWidth, 280)  // 56 * 5
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
}
