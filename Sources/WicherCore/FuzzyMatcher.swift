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

        // Lowercase per character and compare as strings: a character's
        // lowercase form is not always a single `Character` (e.g. "İ"), so
        // `Character(ch.lowercased())` can trap on an unusual window title.
        let qChars = query.map { $0.lowercased() }
        let cChars = Array(candidate)
        var qi = 0
        var score = 0
        var lastMatch = -2

        // Highlight ranges are built in the same pass, in UTF-16 offsets, so
        // they line up with NSAttributedString without re-walking the string.
        var ranges: [NSRange] = []
        var utf16Offset = 0

        for (ci, ch) in cChars.enumerated() {
            guard qi < qChars.count else { break }
            let width = ch.utf16.count
            defer { utf16Offset += width }
            guard ch.lowercased() == qChars[qi] else { continue }

            if ci == lastMatch + 1, let last = ranges.indices.last {
                score += 5
                ranges[last].length += width
            } else {
                score += 1
                ranges.append(NSRange(location: utf16Offset, length: width))
            }
            let prevIsSeparator = ci == 0 || !cChars[ci - 1].isLetter && !cChars[ci - 1].isNumber
            if prevIsSeparator { score += 3 }
            lastMatch = ci
            qi += 1
        }

        guard qi == qChars.count else { return nil }

        // Prefer shorter candidates slightly.
        score += max(0, 24 - cChars.count)

        return FuzzyResult(score: score, ranges: ranges)
    }
}
