import AppKit

/// The scroll view's document: rows are placed by frame, top to bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The List layout's whole content: the rounded background, the search bar,
/// and the scrolling list of rows. Turns `[DisplayRow]` into views, shows the
/// selection, and reports the height it wants. Knows nothing about sessions,
/// screens or the panel it sits in.
///
/// Row views are pooled and reconfigured rather than rebuilt: typing a query
/// re-renders on every keystroke, and with dozens of windows rebuilding meant
/// dozens of view allocations and hundreds of constraints per character. Rows
/// have fixed heights from `HUDMetrics`, so they are placed by frame.
final class SwitcherListView: NSView, SwitcherContentView {
    weak var rowDelegate: SwitcherRowViewDelegate?

    /// The panel's background; the search bar and list are in its `content`.
    private let backdrop = SurfaceView.panel()
    private let searchBar = HUDSearchBar()
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    /// Shown in place of the rows when there are none.
    private let emptyLabel = NSTextField(labelWithString: "")
    private var query = ""
    /// Screen height, for capping the list (it scrolls beyond).
    private var screenHeight: CGFloat = 900

    private var rows: [DisplayRow] = []
    private var metrics = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7)
    /// From the settings at `beginSession`; applied by the next `render`.
    private var sessionMetrics = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7)
    /// Reusable views. Index i is the i-th item of the current render.
    private var itemPool: [SwitcherRowView] = []
    /// Between the main group and the bottom one; there is at most one.
    private let separator = HUDSeparatorView()
    private var rowViews: [Int: SwitcherRowView] = [:] // row index -> view, current render only

    /// Padding around the list inside the scroll view — equal on all sides,
    /// which is what makes the highlight's corners concentric with the panel's.
    private var listInsets: NSEdgeInsets {
        NSEdgeInsets(top: metrics.listInset, left: metrics.listInset,
                     bottom: metrics.listInset, right: metrics.listInset)
    }

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { preconditionFailure("not used") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        let content = backdrop.content

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewFrameChanged(_:)),
                                               name: NSView.frameDidChangeNotification,
                                               object: scrollView.contentView)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        document.addSubview(emptyLabel)
        separator.isHidden = true
        document.addSubview(separator)

        content.addSubview(searchBar)
        content.addSubview(scrollView)

        // The visible panel sits `windowMargin` inside this view (the panel
        // window's content view); see `HUDMetrics.windowMargin`.
        let margin = HUDMetrics.glassWindowMargin
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin),

            searchBar.topAnchor.constraint(equalTo: content.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    // MARK: - Content

    func beginSession(screenSize: CGSize) {
        let settings = Settings.shared
        sessionMetrics = HUDMetrics.make(iconSize: settings.iconSize,
                                         textSize: settings.textSize,
                                         rowPadding: settings.rowPadding,
                                         widthScale: settings.panelWidthScale,
                                         showAppNames: settings.showAppNames)
        screenHeight = screenSize.height
        backdrop.surface = settings.backgroundSurface
        applyTextAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTextAppearance()
    }

    /// Rows do their own (see `SwitcherRowView`).
    private func applyTextAppearance() {
        let text = SurfaceView.textAppearance(selected: false)
        searchBar.setTextAppearance(text)
        emptyLabel.appearance = text
        separator.appearance = text
    }

    func setQuery(_ query: String) {
        self.query = query
        searchBar.setQuery(query)
        updateEmptyLabel()
    }

    func setNotice(_ notice: String?) {
        searchBar.setNotice(notice)
    }

    func render(_ rows: [DisplayRow]) {
        render(rows, metrics: sessionMetrics)
    }

    /// The list is capped at 70% of the screen's height; it scrolls beyond.
    var preferredWindowSize: CGSize {
        metrics.windowSize(panelHeight: preferredHeight(maxListHeight: screenHeight * 0.7))
    }

    func setHovered(rowIndex: Int?) {}
    func setHovered(rowIndex: Int?, ifHovering: Int) {}
    /// One column: Up/Down move like Left/Right.
    func rowIndex(from rowIndex: Int, movingRows step: Int) -> Int? { nil }

    /// Shows `rows`, reusing row views from the previous render.
    func render(_ rows: [DisplayRow], metrics: HUDMetrics) {
        if metrics != self.metrics {
            // Fonts and column widths are baked into the views; start over.
            itemPool.forEach { $0.removeFromSuperview() }
            itemPool.removeAll()
        }
        self.rows = rows
        self.metrics = metrics
        rowViews.removeAll()

        var items = 0
        separator.isHidden = true
        for (rowIndex, row) in rows.enumerated() {
            switch row {
            case .separator:
                separator.isHidden = false
            case let .item(info, ranges, note):
                if items == itemPool.count {
                    let view = SwitcherRowView(metrics: metrics)
                    view.delegate = rowDelegate
                    itemPool.append(view)
                    document.addSubview(view)
                }
                let view = itemPool[items]
                view.displayIndex = rowIndex
                view.isSelected = false
                view.configure(icon: info.appIcon,
                               title: attributedTitle(info.displayTitle, ranges: ranges),
                               appName: info.appName,
                               note: note)
                view.isHidden = false
                rowViews[rowIndex] = view
                items += 1
            }
        }
        itemPool[items...].forEach { $0.isHidden = true }
        updateEmptyLabel()
        layoutRows()
    }

    /// "No matching windows" while searching, "No windows" otherwise.
    private func updateEmptyLabel() {
        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.stringValue = query.isEmpty ? "No windows" : "No matching windows"
        emptyLabel.font = .systemFont(ofSize: metrics.titleSize, weight: .regular)
    }

    /// Places the visible rows top to bottom and sizes the document to fit.
    private func layoutRows() {
        let insets = listInsets
        let width = scrollView.contentSize.width
        let rowWidth = max(0, width - insets.left - insets.right)
        if rows.isEmpty {
            // `preferredHeight` reserves one row's height for exactly this.
            let height = ceil(emptyLabel.intrinsicContentSize.height)
            emptyLabel.frame = NSRect(x: insets.left,
                                      y: insets.top + ((metrics.rowHeight - height) / 2).rounded(),
                                      width: rowWidth, height: height)
        }
        var y = insets.top
        var items = 0
        for row in rows {
            switch row {
            case .separator:
                // A hairline in the middle of the gap, as wide as the rows' content.
                let x = insets.left + HUDMetrics.rowLeadingInset
                separator.frame = NSRect(x: x, y: y + ((metrics.separatorHeight - 1) / 2).rounded(),
                                         width: max(0, rowWidth - HUDMetrics.rowLeadingInset - HUDMetrics.rowTrailingInset),
                                         height: 1)
                y += metrics.separatorHeight
            case .item:
                itemPool[items].frame = NSRect(x: insets.left, y: y, width: rowWidth, height: metrics.rowHeight)
                items += 1
                y += metrics.rowHeight
            }
        }
        if rows.isEmpty { y += metrics.rowHeight }
        document.frame = NSRect(x: 0, y: 0, width: width, height: y + insets.bottom)
    }

    /// Rows are sized from the scroll view's visible width, which is only
    /// final after the panel is resized — and, inside the glass, after a layout
    /// pass of its own that runs later than ours. So follow the clip view's
    /// actual frame rather than guessing when layout has settled: on the first
    /// open after launch, a check in `layout()` ran too early and the rows kept
    /// the panel's initial width.
    @objc private func clipViewFrameChanged(_ note: Notification) {
        if document.frame.width != scrollView.contentSize.width { layoutRows() }
    }

    /// Hides every row (between sessions). Views stay pooled for the next one.
    func clear() {
        render([], metrics: metrics)
    }

    /// Highlights the row at `rowIndex` (nil highlights nothing) and scrolls it into view.
    func highlight(rowIndex: Int?) {
        for (index, row) in rowViews {
            row.isSelected = (index == rowIndex)
        }
        if let rowIndex, let row = rowViews[rowIndex] {
            row.scrollToVisible(row.bounds)
        }
    }

    private func attributedTitle(_ title: String, ranges: [NSRange]) -> NSAttributedString {
        let attr = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: metrics.titleSize, weight: .regular)]
        )
        attr.highlightSearchMatches(ranges)
        return attr
    }

    // MARK: - Sizing

    /// The height this view wants for the rendered rows: the search bar plus
    /// the list, with the list capped at `maxListHeight` (it scrolls beyond).
    /// An empty list still reserves one row's height.
    /// The visible panel's height (excluding `windowMargin`).
    func preferredHeight(maxListHeight: CGFloat) -> CGFloat {
        var contentHeight: CGFloat = listInsets.top + listInsets.bottom
        for row in rows {
            switch row {
            case .separator: contentHeight += metrics.separatorHeight
            case .item: contentHeight += metrics.rowHeight
            }
        }
        if rows.isEmpty { contentHeight += metrics.rowHeight }
        return searchBar.barHeight + min(contentHeight, maxListHeight)
    }
}
