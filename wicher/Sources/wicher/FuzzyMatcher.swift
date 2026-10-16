import Foundation

/// Result of a fuzzy match: a score (higher is better) and the matched
/// character ranges within the candidate, for highlighting.
struct FuzzyResult {
    let score: Int
    let ranges: [NSRange]
}

/// Simple, allocation-light subsequence fuzzy matcher with scoring bonuses for
/// contiguous runs and word-boundary hits. Enough for a window-title filter;
/// wicher does not try to clone any particular scoring algorithm.
enum FuzzyMatcher {
    /// Returns nil when `query` is not a subsequence of `candidate`.
    static func match(query: String, candidate: String) -> FuzzyResult? {
        if query.isEmpty { return FuzzyResult(score: 0, ranges: []) }

        let qChars = Array(query.lowercased())
        let cChars = Array(candidate)
        var qi = 0
        var matchedCharIndexes: [Int] = []
        var score = 0
        var lastMatch = -2

        for (ci, ch) in cChars.enumerated() {
            guard qi < qChars.count else { break }
            if Character(ch.lowercased()) == qChars[qi] {
                matchedCharIndexes.append(ci)
                if ci == lastMatch + 1 { score += 5 } else { score += 1 }
                let prevIsSeparator = ci == 0 || !cChars[ci - 1].isLetter && !cChars[ci - 1].isNumber
                if prevIsSeparator { score += 3 }
                lastMatch = ci
                qi += 1
            }
        }

        guard qi == qChars.count else { return nil }

        // Prefer shorter candidates slightly.
        score += max(0, 24 - candidate.count)

        return FuzzyResult(score: score, ranges: contiguousRanges(matchedCharIndexes, in: candidate))
    }

    /// Collapses adjacent matched character offsets into NSRanges valid for the
    /// candidate string (UTF-16 based, so highlighting lines up correctly).
    private static func contiguousRanges(_ charIndexes: [Int], in candidate: String) -> [NSRange] {
        guard !charIndexes.isEmpty else { return [] }
        var ranges: [NSRange] = []
        var runStart = charIndexes[0]
        var runEnd = charIndexes[0]
        for idx in charIndexes.dropFirst() {
            if idx == runEnd + 1 {
                runEnd = idx
            } else {
                ranges.append(nsRange(fromCharIndex: runStart, through: runEnd, in: candidate))
                runStart = idx
                runEnd = idx
            }
        }
        ranges.append(nsRange(fromCharIndex: runStart, through: runEnd, in: candidate))
        return ranges
    }

    private static func nsRange(fromCharIndex start: Int, through end: Int, in candidate: String) -> NSRange {
        let startIndex = candidate.index(candidate.startIndex, offsetBy: start)
        let endIndex = candidate.index(candidate.startIndex, offsetBy: end + 1)
        return NSRange(startIndex..<endIndex, in: candidate)
    }
}
