import AppKit

/// The scroll view's document: rows are placed by frame, top to bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The HUD's whole content: blurred rounded backdrop, the search bar, and the
/// scrolling list of rows. Turns `[DisplayRow]` into views, shows the
/// selection, and reports the height it wants. Knows nothing about sessions,
/// screens or the panel it sits in.
///
/// Row views are pooled and reconfigured rather than rebuilt: typing a query
/// re-renders on every keystroke, and with dozens of windows rebuilding meant
/// dozens of view allocations and hundreds of constraints per character. Rows
/// have fixed heights from `HUDMetrics`, so they are placed by frame.
final class SwitcherListView: NSVisualEffectView {
    /// Receives hover/click from every row this view creates.
    weak var rowDelegate: SwitcherRowViewDelegate?

    private let searchContainer = NSView()
    private let searchField = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    /// Shown in place of the rows when there are none.
    private let emptyLabel = NSTextField(labelWithString: "")
    private var searchHeight: NSLayoutConstraint!
    private var query = ""
    /// Shown in the search bar's place while there is no query — e.g. a
    /// warning that Accessibility access is off.
    private var notice: String?

    private var rows: [DisplayRow] = []
    private var metrics = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7)
    /// Reusable views. Index i is the i-th item (or header) of the current render.
    private var itemPool: [SwitcherRowView] = []
    private var headerPool: [SwitcherHeaderView] = []
    private var rowViews: [Int: SwitcherRowView] = [:] // row index -> view, current render only

    /// Corner radius of the HUD. Used for both the backdrop mask and the
    /// layer clip so the two never disagree.
    private static let cornerRadius: CGFloat = 16
    private static let searchBarHeight: CGFloat = 52
    /// Padding around the list inside the scroll view.
    private static let listInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { preconditionFailure("not used") }

    /// A resizable rounded-rect mask for the visual-effect view.
    ///
    /// `layer.cornerRadius` only clips what *AppKit* draws; the blurred
    /// backdrop behind an `NSVisualEffectView` is composited by the window
    /// server and ignores the layer entirely, which is why the HUD used to
    /// show a square patch of blurred desktop in each corner. `maskImage` is
    /// the supported way to shape the backdrop itself.
    private static func backdropMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func build() {
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        maskImage = Self.backdropMask(radius: Self.cornerRadius)
        translatesAutoresizingMaskIntoConstraints = false

        searchContainer.wantsLayer = true
        searchContainer.layer?.masksToBounds = true
        searchContainer.translatesAutoresizingMaskIntoConstraints = false

        searchField.font = .systemFont(ofSize: 18, weight: .regular)
        searchField.textColor = .labelColor
        searchField.lineBreakMode = .byTruncatingTail
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(searchField)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        document.addSubview(emptyLabel)

        addSubview(searchContainer)
        addSubview(scrollView)

        searchHeight = searchContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: topAnchor),
            searchContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchHeight,

            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 22),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -22),

            scrollView.topAnchor.constraint(equalTo: searchContainer.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Content

    /// Shows the search bar for a non-empty query; hides it otherwise.
    func setQuery(_ query: String) {
        self.query = query
        updateSearchBar()
        updateEmptyLabel()
    }

    /// Shows `notice` in the search bar's place whenever there is no query.
    func setNotice(_ notice: String?) {
        self.notice = notice
        updateSearchBar()
    }

    private func updateSearchBar() {
        if !query.isEmpty {
            searchField.stringValue = "🔍  \(query)"
            searchField.font = .systemFont(ofSize: 18, weight: .regular)
            searchField.textColor = .labelColor
        } else if let notice {
            searchField.stringValue = "⚠︎  \(notice)"
            searchField.font = .systemFont(ofSize: 13, weight: .medium)
            searchField.textColor = .secondaryLabelColor
        } else {
            searchField.stringValue = ""
        }
        searchHeight.constant = (query.isEmpty && notice == nil) ? 0 : Self.searchBarHeight
    }

    /// Shows `rows`, reusing row views from the previous render.
    func render(_ rows: [DisplayRow], metrics: HUDMetrics) {
        if metrics != self.metrics {
            // Fonts and column widths are baked into the views; start over.
            itemPool.forEach { $0.removeFromSuperview() }
            headerPool.forEach { $0.removeFromSuperview() }
            itemPool.removeAll()
            headerPool.removeAll()
        }
        self.rows = rows
        self.metrics = metrics
        rowViews.removeAll()

        var items = 0
        var headers = 0
        for (rowIndex, row) in rows.enumerated() {
            switch row {
            case let .header(title):
                if headers == headerPool.count {
                    let header = SwitcherHeaderView(metrics: metrics)
                    headerPool.append(header)
                    document.addSubview(header)
                }
                let header = headerPool[headers]
                header.title = title
                header.isHidden = false
                headers += 1
            case let .item(info, ranges):
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
                               appName: info.appName)
                view.isHidden = false
                rowViews[rowIndex] = view
                items += 1
            }
        }
        itemPool[items...].forEach { $0.isHidden = true }
        headerPool[headers...].forEach { $0.isHidden = true }
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
        let insets = Self.listInsets
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
        var headers = 0
        for row in rows {
            switch row {
            case .header:
                headerPool[headers].frame = NSRect(x: insets.left, y: y, width: rowWidth, height: metrics.headerHeight)
                headers += 1
                y += metrics.headerHeight
            case .item:
                itemPool[items].frame = NSRect(x: insets.left, y: y, width: rowWidth, height: metrics.rowHeight)
                items += 1
                y += metrics.rowHeight
            }
        }
        if rows.isEmpty { y += metrics.rowHeight }
        document.frame = NSRect(x: 0, y: 0, width: width, height: y + insets.bottom)
    }

    override func layout() {
        super.layout()
        // The panel is resized after `render`, so the row width is only final now.
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
        let bold = NSFont.systemFont(ofSize: metrics.titleSize, weight: .bold)
        for range in ranges where range.location + range.length <= attr.length {
            attr.addAttribute(.font, value: bold, range: range)
        }
        return attr
    }

    // MARK: - Sizing

    /// The height this view wants for the rendered rows: the search bar plus
    /// the list, with the list capped at `maxListHeight` (it scrolls beyond).
    /// An empty list still reserves one row's height.
    func preferredHeight(maxListHeight: CGFloat) -> CGFloat {
        var contentHeight: CGFloat = Self.listInsets.top + Self.listInsets.bottom
        for row in rows {
            switch row {
            case .header: contentHeight += metrics.headerHeight
            case .item: contentHeight += metrics.rowHeight
            }
        }
        if rows.isEmpty { contentHeight += metrics.rowHeight }
        return searchHeight.constant + min(contentHeight, maxListHeight)
    }
}
