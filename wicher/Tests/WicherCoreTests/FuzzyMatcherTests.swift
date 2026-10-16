import XCTest
@testable import WicherCore

final class FuzzyMatcherTests: XCTestCase {
    func testEmptyQueryMatchesWithNoRanges() {
        let r = FuzzyMatcher.match(query: "", candidate: "Safari")
        XCTAssertEqual(r?.score, 0)
        XCTAssertEqual(r?.ranges, [])
    }

    func testNonMatches() {
        XCTAssertNil(FuzzyMatcher.match(query: "xyz", candidate: "Safari"))
        XCTAssertNil(FuzzyMatcher.match(query: "fs", candidate: "Safari"))   // wrong order
        XCTAssertNil(FuzzyMatcher.match(query: "saff", candidate: "Safari")) // too many f's
        XCTAssertNil(FuzzyMatcher.match(query: "a", candidate: ""))
    }

    func testCaseInsensitiveContiguousRange() {
        let r = FuzzyMatcher.match(query: "SAF", candidate: "Safari")
        XCTAssertEqual(r?.ranges, [NSRange(location: 0, length: 3)])
    }

    func testScatteredMatchProducesSeparateRanges() {
        let r = FuzzyMatcher.match(query: "sfi", candidate: "Safari")
        XCTAssertEqual(r?.ranges, [NSRange(location: 0, length: 1),
                                   NSRange(location: 2, length: 1),
                                   NSRange(location: 5, length: 1)])
    }

    func testRangesAreUTF16() {
        // The emoji is two UTF-16 units, so "Mail" starts at 3, not 2.
        let r = FuzzyMatcher.match(query: "mail", candidate: "😀 Mail")
        XCTAssertEqual(r?.ranges, [NSRange(location: 3, length: 4)])
    }

    func testContiguousBeatsScattered() {
        let contiguous = FuzzyMatcher.match(query: "term", candidate: "Terminal")!
        let scattered = FuzzyMatcher.match(query: "term", candidate: "TxExRxM")!
        XCTAssertGreaterThan(contiguous.score, scattered.score)
    }

    func testWordBoundaryBeatsMidWord() {
        let boundary = FuzzyMatcher.match(query: "gc", candidate: "Google Chrome")!
        let midWord = FuzzyMatcher.match(query: "gc", candidate: "bigxcatxxxxxx") // same length
        XCTAssertGreaterThan(boundary.score, midWord!.score)
    }

    func testShorterCandidatePreferred() {
        let short = FuzzyMatcher.match(query: "mail", candidate: "Mail")!
        let long = FuzzyMatcher.match(query: "mail", candidate: "Mail — Inbox (42 messages)")!
        XCTAssertGreaterThan(short.score, long.score)
    }
}
