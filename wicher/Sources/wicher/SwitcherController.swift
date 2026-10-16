import AppKit
import Carbon.HIToolbox

/// A flipped vertical stack so arranged rows lay out top-to-bottom in a scroll view.
private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// One rendered row in the list.
private enum DisplayRow {
    case header(String)
    case item(WindowInfo, [NSRange])
}

/// Orchestrates a switcher session: summon/advance (with an optional pre-show
/// delay), grouped sections, type-to-search, selection, and
/// commit-on-modifier-release — all without an event tap.
final class SwitcherController: NSObject, SwitcherRowViewDelegate {
    private let panel = SwitcherPanel()
    private let visualEffect = NSVisualEffectView()
    private let searchContainer = NSView()
    private let searchField = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let stack = FlippedStack()
    private var searchHeight: NSLayoutConstraint!

    // Session state
    private var sessionActive = false
    private var panelShown = false
    private var pendingShow: DispatchWorkItem?
    private var activeProfile = SwitcherProfile.defaults()[0]
    private var activeAppPID: pid_t?
    private var metrics = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7)

    // Model
    private var enumeration = Enumeration(windows: [], appsWithoutWindows: [], currentSpaceWindowIDs: [])
    private var displayRows: [DisplayRow] = []
    private var selectableIndexes: [Int] = []   // indexes into displayRows that are .item
    private var selectionPos = 0                // index into selectableIndexes
    private var query = ""

    // Views
    private var rowViews: [Int: SwitcherRowView] = [:] // displayIndex -> row

    private var localMonitor: Any?
    private var globalMonitor: Any?

    // Auto-repeat while the trigger is held down.
    private var holdDirection: Int?
    private var holdTimer: Timer?
    private var holdStart = Date()
    private let holdInitialDelay: TimeInterval = 0.30
    private let holdRepeatInterval: TimeInterval = 0.05

    override init() {
        super.init()
        buildChrome()
    }

    // MARK: - Entry points

    /// Menu entry point: open the switcher (no hold behavior).
    func summon(profile: SwitcherProfile, forward: Bool) {
        if sessionActive {
            advance(by: forward ? 1 : -1)
        } else {
            beginSession(profile: profile, forward: forward)
        }
    }

    /// Hot-key entry point. `pressed` is true on key-down, false on key-up, so
    /// we can auto-repeat while the key is held and stop when it is released.
    func hotKey(profile: SwitcherProfile, forward: Bool, pressed: Bool) {
        let dir = forward ? 1 : -1
        if pressed {
            // Guard against any OS-generated repeat presses: clamp, keep timer.
            if sessionActive, holdDirection == dir {
                advance(by: dir, wrap: false)
                return
            }
            holdDirection = dir
            if sessionActive {
                advance(by: dir, wrap: true) // a fresh discrete press wraps
                startHoldTimer()
            } else {
                beginSession(profile: profile, forward: forward)
            }
        } else {
            if holdDirection == dir {
                holdDirection = nil
                stopHoldTimer()
            }
        }
    }

    // MARK: - Chrome (built once)

    private func buildChrome() {
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 16
        visualEffect.layer?.masksToBounds = true
        visualEffect.translatesAutoresizingMaskIntoConstraints = false

        searchContainer.wantsLayer = true
        searchContainer.layer?.masksToBounds = true
        searchContainer.translatesAutoresizingMaskIntoConstraints = false

        searchField.font = .systemFont(ofSize: 18, weight: .regular)
        searchField.textColor = .labelColor
        searchField.lineBreakMode = .byTruncatingTail
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(searchField)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack

        visualEffect.addSubview(searchContainer)
        visualEffect.addSubview(scrollView)

        searchHeight = searchContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            searchContainer.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            searchContainer.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            searchHeight,

            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 22),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -22),

            scrollView.topAnchor.constraint(equalTo: searchContainer.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        panel.contentView = visualEffect
    }

    // MARK: - Session lifecycle

    private func beginSession(profile: SwitcherProfile, forward: Bool) {
        activeProfile = profile
        metrics = HUDMetrics.make(iconSize: Settings.shared.iconSize,
                                  textSize: Settings.shared.textSize,
                                  rowPadding: Settings.shared.rowPadding)
        activeAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Make sure the window currently in front is the most-recent one, so a
        // quick tap selects the genuine previous window (index 1 below).
        if let pid = activeAppPID { WindowEnumerator.shared.noteFrontmost(pid: pid) }
        enumeration = WindowEnumerator.shared.enumerate()
        query = ""
        searchHeight.constant = 0
        searchField.stringValue = ""

        rebuildModel()
        let count = selectableIndexes.count
        selectionPos = forward ? min(1, max(count - 1, 0)) : max(count - 1, 0)

        sessionActive = true
        panelShown = false
        startMonitors()

        let delay = Settings.shared.showDelayMs
        if delay <= 0 {
            showPanelNow()
        } else {
            let work = DispatchWorkItem { [weak self] in self?.showPanelNow() }
            pendingShow = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
        }
    }

    private func showPanelNow() {
        guard sessionActive, !panelShown else { return }
        rebuildRows()
        sizeAndCenterPanel()
        panel.makeKeyAndOrderFront(nil)
        panelShown = true
        updateSelectionHighlight()
        if holdDirection != nil { startHoldTimer() }
    }

    private func endSession() {
        pendingShow?.cancel()
        pendingShow = nil
        stopHoldTimer()
        holdDirection = nil
        stopMonitors()
        if panelShown { panel.orderOut(nil) }
        rowViews.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        displayRows.removeAll()
        selectableIndexes.removeAll()
        enumeration = Enumeration(windows: [], appsWithoutWindows: [], currentSpaceWindowIDs: [])
        query = ""
        selectionPos = 0
        sessionActive = false
        panelShown = false
    }

    private func commit() {
        guard sessionActive else { return }
        let target = selectedWindow()
        endSession()
        if let target { WindowActivator.activate(target) }
    }

    private func cancel() { endSession() }

    private func selectedWindow() -> WindowInfo? {
        guard selectableIndexes.indices.contains(selectionPos) else { return nil }
        if case let .item(info, _) = displayRows[selectableIndexes[selectionPos]] { return info }
        return nil
    }

    // MARK: - Monitors

    private func startMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .scrollWheel]) { [weak self] event in
            self?.handleLocal(event) ?? event
        }
        // Global monitor: observes events routed to *other* apps. Needed while
        // the panel is not yet key (during the show-delay) to catch the trigger
        // modifier being released, and to dismiss on an outside click.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .flagsChanged]) { [weak self] event in
            guard let self else { return }
            if event.type == .flagsChanged {
                let trigger = self.activeProfile.combo.eventModifierFlags
                if !trigger.isEmpty, !event.modifierFlags.contains(trigger) { self.commit() }
            } else {
                self.cancel()
            }
        }
    }

    private func stopMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            let trigger = activeProfile.combo.eventModifierFlags
            if !trigger.isEmpty, !event.modifierFlags.contains(trigger) { commit() }
            return event
        case .scrollWheel:
            if panelShown, Settings.shared.selectOnScroll, event.deltaY != 0 {
                advance(by: event.deltaY < 0 ? 1 : -1)
                return nil
            }
            return event
        case .keyDown:
            handleKeyDown(event)
            return nil // swallow every key while a session is active (no beeps)
        default:
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        let mods = event.modifierFlags
        switch Int(event.keyCode) {
        case kVK_Escape:
            cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            commit()
        case kVK_Tab:
            advance(by: mods.contains(.shift) ? -1 : 1)
        case kVK_DownArrow:
            advance(by: 1)
        case kVK_UpArrow:
            advance(by: -1)
        case kVK_Delete:
            if !query.isEmpty { query.removeLast(); applyQueryChange() }
        default:
            guard !mods.contains(.command), !mods.contains(.control),
                  let chars = event.charactersIgnoringModifiers, chars.count == 1,
                  let scalar = chars.unicodeScalars.first,
                  scalar.value >= 0x20, scalar.value != 0x7F
            else { return }
            query.append(Character(scalar))
            applyQueryChange()
        }
    }

    // MARK: - Model + selection

    private func applyQueryChange() {
        rebuildModel()
        selectionPos = 0
        searchHeight.constant = query.isEmpty ? 0 : 52
        searchField.stringValue = query.isEmpty ? "" : "🔍  \(query)"
        if panelShown {
            rebuildRows()
            sizeAndCenterPanel()
            updateSelectionHighlight()
        } else {
            showPanelNow()
        }
    }

    /// Builds `displayRows` + `selectableIndexes` from the current query.
    private func rebuildModel() {
        displayRows.removeAll()

        if query.isEmpty {
            let sections = WindowGrouping.sections(for: activeProfile,
                                                   enumeration: enumeration,
                                                   activeAppPID: activeAppPID)
            for section in sections {
                if let title = section.title { displayRows.append(.header(title)) }
                for info in section.items { displayRows.append(.item(info, [])) }
            }
        } else {
            // Search mode: a single flat, scored list (no section headers).
            var pool = enumeration.windows
            if activeProfile.scope == .activeApp, let pid = activeAppPID {
                pool = pool.filter { $0.pid == pid }
            }
            if activeProfile.spaces == .visibleSpaces {
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
            for s in scored { displayRows.append(.item(s.info, s.ranges)) }
        }

        selectableIndexes = displayRows.indices.filter {
            if case .item = displayRows[$0] { return true }
            return false
        }
    }

    private func advance(by step: Int, wrap: Bool = true) {
        guard !selectableIndexes.isEmpty else { return }
        let n = selectableIndexes.count
        if wrap {
            selectionPos = ((selectionPos + step) % n + n) % n
        } else {
            selectionPos = (selectionPos + step).clamped(to: 0...(n - 1))
        }
        if panelShown { updateSelectionHighlight() }
    }

    // MARK: - Auto-repeat while held

    private func startHoldTimer() {
        guard panelShown, holdDirection != nil else { return }
        stopHoldTimer()
        holdStart = Date()
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdRepeatInterval, repeats: true) { [weak self] _ in
            guard let self, self.panelShown, let dir = self.holdDirection else { return }
            // Honor an initial delay before the auto-repeat kicks in.
            if Date().timeIntervalSince(self.holdStart) < self.holdInitialDelay { return }
            // Auto-repeat clamps at the ends; explicit presses wrap.
            self.advance(by: dir, wrap: false)
        }
    }

    private func stopHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func updateSelectionHighlight() {
        let selectedDisplayIndex = selectableIndexes.indices.contains(selectionPos)
            ? selectableIndexes[selectionPos] : -1
        for (displayIndex, row) in rowViews {
            row.isSelected = (displayIndex == selectedDisplayIndex)
        }
        if let row = rowViews[selectedDisplayIndex] {
            row.scrollToVisible(row.bounds)
        }
    }

    // MARK: - Rendering

    private func rebuildRows() {
        rowViews.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (displayIndex, row) in displayRows.enumerated() {
            switch row {
            case let .header(title):
                let header = SwitcherHeaderView(title: title, metrics: metrics)
                header.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(header)
                NSLayoutConstraint.activate([
                    header.heightAnchor.constraint(equalToConstant: metrics.headerHeight),
                    header.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: stack.edgeInsets.left),
                    header.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -stack.edgeInsets.right),
                ])
            case let .item(info, ranges):
                let view = SwitcherRowView(displayIndex: displayIndex, metrics: metrics)
                view.delegate = self
                view.translatesAutoresizingMaskIntoConstraints = false
                view.configure(icon: info.appIcon,
                               title: attributedTitle(info.displayTitle, ranges: ranges),
                               appName: info.appName)
                stack.addArrangedSubview(view)
                NSLayoutConstraint.activate([
                    view.heightAnchor.constraint(equalToConstant: metrics.rowHeight),
                    view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: stack.edgeInsets.left),
                    view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -stack.edgeInsets.right),
                ])
                rowViews[displayIndex] = view
            }
        }
    }

    private func attributedTitle(_ title: String, ranges: [NSRange]) -> NSAttributedString {
        let attr = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: metrics.titleSize, weight: .regular)]
        )
        let bold = NSFont.systemFont(ofSize: metrics.titleSize, weight: .bold)
        for range in ranges where range.location + range.length <= attr.length {
            attr.addAttribute(.font, value: bold, range: range)
        }
        return attr
    }

    private func sizeAndCenterPanel() {
        var contentHeight: CGFloat = stack.edgeInsets.top + stack.edgeInsets.bottom
        for (i, row) in displayRows.enumerated() {
            switch row {
            case .header: contentHeight += metrics.headerHeight
            case .item: contentHeight += metrics.rowHeight
            }
            if i < displayRows.count - 1 { contentHeight += stack.spacing }
        }
        if displayRows.isEmpty { contentHeight += metrics.rowHeight }

        let screen = screenWithMouse() ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let searchBar = query.isEmpty ? 0 : searchHeight.constant
        let maxList = frame.height * 0.7
        let listHeight = min(contentHeight, maxList)
        let height = searchBar + listHeight
        let origin = NSPoint(x: frame.midX - metrics.panelWidth / 2,
                             y: frame.midY - height / 2)
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: metrics.panelWidth, height: height), display: true)
    }

    private func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    // MARK: - SwitcherRowViewDelegate

    func rowHovered(displayIndex: Int) {
        guard Settings.shared.selectOnHover,
              let pos = selectableIndexes.firstIndex(of: displayIndex) else { return }
        selectionPos = pos
        updateSelectionHighlight()
    }

    func rowClicked(displayIndex: Int) {
        guard let pos = selectableIndexes.firstIndex(of: displayIndex) else { return }
        selectionPos = pos
        commit()
    }
}
