import Foundation

/// One rendered row in the list (or icon in the Icons layout).
enum DisplayRow {
    /// Between the main group and the bottom one, when both have entries.
    case separator
    /// `ranges`: what a search matched in the title. `note`: why the window
    /// is in the bottom group ("Minimized", …; see `WindowGroups`).
    case item(WindowInfo, [NSRange], note: String? = nil)
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
    /// Where the switcher opened, for the "other displays" placement.
    let display: DisplayLayout?
    /// Settings → Exceptions, as of when the session began.
    let exceptions: ExceptionRules
    private var enumeration: Enumeration

    private(set) var query = ""
    private(set) var rows: [DisplayRow] = []
    private var selectableIndexes: [Int] = []   // indexes into rows that are .item
    private var selectionPos = 0                // index into selectableIndexes

    /// Preselects index 1 going forward (the previous window), so a quick
    /// tap+release switches back without the panel ever being drawn; going
    /// backward preselects the last row.
    init(profile: SwitcherProfile, enumeration: Enumeration, activeAppPID: pid_t?,
         display: DisplayLayout? = nil, exceptions: ExceptionRules = .none, forward: Bool) {
        self.profile = profile
        self.enumeration = enumeration
        self.activeAppPID = activeAppPID
        self.display = display
        self.exceptions = exceptions
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
        guard let index = selectedRowIndex, case let .item(info, _, _) = rows[index] else { return nil }
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

    /// Selects the item at `rowIndex`. Returns false for a separator or an
    /// out-of-range index, leaving the selection unchanged.
    @discardableResult
    mutating func select(rowIndex: Int) -> Bool {
        guard let pos = selectableIndexes.firstIndex(of: rowIndex) else { return false }
        selectionPos = pos
        return true
    }

    // MARK: - Live updates

    /// Swaps in a newer enumeration (a background scan finished while the
    /// panel was open), keeping the same window selected if it still exists.
    /// Returns false — and changes nothing — when the visible rows would be
    /// identical, so the caller can skip a redraw.
    @discardableResult
    mutating func update(enumeration: Enumeration) -> Bool {
        let before = signature
        let selectedKey = selectedWindow?.key
        let previous = (self.enumeration, rows, selectableIndexes, selectionPos)

        self.enumeration = enumeration
        rebuildRows()
        guard signature != before else {
            (self.enumeration, rows, selectableIndexes, selectionPos) = previous
            return false
        }
        if let selectedKey, let pos = selectableIndexes.firstIndex(where: { key(atRow: $0) == selectedKey }) {
            selectionPos = pos
        } else {
            selectionPos = min(selectionPos, max(selectableIndexes.count - 1, 0))
        }
        return true
    }

    /// What the user can see: the separator, and each item's identity and labels.
    private var signature: [String] {
        rows.map { row in
            switch row {
            case .separator: return "-"
            case let .item(info, _, note):
                return "i:\(info.key):\(info.displayTitle):\(info.appName):\(note ?? "")"
            }
        }
    }

    private func key(atRow index: Int) -> WindowKey? {
        if case let .item(info, _, _) = rows[index] { return info.key }
        return nil
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

    /// Returns false when the query was already empty (nothing changed).
    mutating func clearQuery() -> Bool {
        guard !query.isEmpty else { return false }
        query = ""
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
            let groups = WindowGrouping.groups(for: profile,
                                               enumeration: enumeration,
                                               activeAppPID: activeAppPID,
                                               display: display,
                                               exceptions: exceptions)
            for info in groups.main { rows.append(.item(info, [])) }
            if !groups.main.isEmpty && !groups.bottom.isEmpty { rows.append(.separator) }
            for (info, note) in groups.bottom { rows.append(.item(info, [], note: note)) }
        } else {
            // Search mode: a single flat, scored list (no separator); bottom
            // windows keep their notes.
            let pool = WindowGrouping.searchPool(for: profile, enumeration: enumeration,
                                                 activeAppPID: activeAppPID, display: display,
                                                 exceptions: exceptions)
            var scored: [(info: WindowInfo, ranges: [NSRange], score: Int)] = []
            for w in pool {
                if let r = FuzzyMatcher.match(query: query, candidate: w.displayTitle) {
                    scored.append((w, r.ranges, r.score))
                } else if let r = FuzzyMatcher.match(query: query, candidate: w.appName) {
                    scored.append((w, [], r.score - 5))
                }
            }
            scored.sort { $0.score > $1.score }
            for s in scored {
                let note = WindowGrouping.note(for: s.info, profile: profile, enumeration: enumeration,
                                               display: display, exceptions: exceptions)
                rows.append(.item(s.info, s.ranges, note: note))
            }
        }

        selectableIndexes = rows.indices.filter {
            if case .item = rows[$0] { return true }
            return false
        }
    }
}
