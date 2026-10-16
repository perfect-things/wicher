import Foundation

/// One rendered row in the list.
enum DisplayRow {
    case header(String)
    case item(WindowInfo, [NSRange])
}

/// The model of one switcher session: which rows are on offer for the current
/// query, and which of them is selected.
///
/// Deliberately free of views, timers and event monitors — `SwitcherController`
/// owns those and drives this — so selection and search behavior can be
/// reasoned about (and tested) on their own.
struct SwitcherSession {
    let profile: SwitcherProfile
    let activeAppPID: pid_t?
    private let enumeration: Enumeration

    private(set) var query = ""
    private(set) var rows: [DisplayRow] = []
    private var selectableIndexes: [Int] = []   // indexes into rows that are .item
    private var selectionPos = 0                // index into selectableIndexes

    /// Preselects index 1 going forward (the previous window), so a quick
    /// tap+release switches back without the panel ever being drawn; going
    /// backward preselects the last row.
    init(profile: SwitcherProfile, enumeration: Enumeration, activeAppPID: pid_t?, forward: Bool) {
        self.profile = profile
        self.enumeration = enumeration
        self.activeAppPID = activeAppPID
        rebuildRows()
        let count = selectableIndexes.count
        selectionPos = forward ? min(1, max(count - 1, 0)) : max(count - 1, 0)
    }

    // MARK: - Selection

    /// The `rows` index of the selected item, if anything is selectable.
    var selectedRowIndex: Int? {
        selectableIndexes.indices.contains(selectionPos) ? selectableIndexes[selectionPos] : nil
    }

    var selectedWindow: WindowInfo? {
        guard let index = selectedRowIndex, case let .item(info, _) = rows[index] else { return nil }
        return info
    }

    /// Discrete presses wrap around the list; auto-repeat passes `wrap: false`
    /// and clamps at the ends.
    mutating func advance(by step: Int, wrap: Bool = true) {
        guard !selectableIndexes.isEmpty else { return }
        let n = selectableIndexes.count
        if wrap {
            selectionPos = ((selectionPos + step) % n + n) % n
        } else {
            selectionPos = (selectionPos + step).clamped(to: 0...(n - 1))
        }
    }

    /// Selects the item at `rowIndex`. Returns false for a header or an
    /// out-of-range index, leaving the selection unchanged.
    @discardableResult
    mutating func select(rowIndex: Int) -> Bool {
        guard let pos = selectableIndexes.firstIndex(of: rowIndex) else { return false }
        selectionPos = pos
        return true
    }

    // MARK: - Search

    mutating func appendToQuery(_ character: Character) {
        query.append(character)
        queryChanged()
    }

    /// Returns false when the query was already empty (nothing changed).
    mutating func deleteBackward() -> Bool {
        guard !query.isEmpty else { return false }
        query.removeLast()
        queryChanged()
        return true
    }

    private mutating func queryChanged() {
        rebuildRows()
        selectionPos = 0
    }

    /// Builds `rows` + `selectableIndexes` from the current query.
    private mutating func rebuildRows() {
        rows.removeAll()

        if query.isEmpty {
            let sections = WindowGrouping.sections(for: profile,
                                                   enumeration: enumeration,
                                                   activeAppPID: activeAppPID)
            for section in sections {
                if let title = section.title { rows.append(.header(title)) }
                for info in section.items { rows.append(.item(info, [])) }
            }
        } else {
            // Search mode: a single flat, scored list (no section headers).
            var pool = enumeration.windows
            if profile.scope == .activeApp, let pid = activeAppPID {
                pool = pool.filter { $0.pid == pid }
            }
            if profile.spaces == .visibleSpaces {
                pool = pool.filter { $0.onCurrentSpace }
            }
            var scored: [(info: WindowInfo, ranges: [NSRange], score: Int)] = []
            for w in pool {
                if let r = FuzzyMatcher.match(query: query, candidate: w.displayTitle) {
                    scored.append((w, r.ranges, r.score))
                } else if let r = FuzzyMatcher.match(query: query, candidate: w.appName) {
                    scored.append((w, [], r.score - 5))
                }
            }
            scored.sort { $0.score > $1.score }
            for s in scored { rows.append(.item(s.info, s.ranges)) }
        }

        selectableIndexes = rows.indices.filter {
            if case .item = rows[$0] { return true }
            return false
        }
    }
}
