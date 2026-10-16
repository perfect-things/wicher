import AppKit

/// A flipped vertical stack so arranged rows lay out top-to-bottom in a scroll view.
private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// The HUD's whole content: blurred rounded backdrop, the search bar, and the
/// scrolling list of rows. Turns `[DisplayRow]` into views, shows the
/// selection, and reports the height it wants. Knows nothing about sessions,
/// screens or the panel it sits in.
final class SwitcherListView: NSVisualEffectView {
    /// Receives hover/click from every row this view creates.
    weak var rowDelegate: SwitcherRowViewDelegate?

    private let searchContainer = NSView()
    private let searchField = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let stack = FlippedStack()
    private var searchHeight: NSLayoutConstraint!
    private var query = ""
    /// Shown in the search bar's place while there is no query — e.g. a
    /// warning that Accessibility access is off.
    private var notice: String?

    private var rows: [DisplayRow] = []
    private var metrics = HUDMetrics.make(iconSize: 32, textSize: 16, rowPadding: 7)
    private var rowViews: [Int: SwitcherRowView] = [:] // row index -> view

    /// Corner radius of the HUD. Used for both the backdrop mask and the
    /// layer clip so the two never disagree.
    private static let cornerRadius: CGFloat = 16
    private static let searchBarHeight: CGFloat = 52

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

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    // MARK: - Content

    /// Shows the search bar for a non-empty query; hides it otherwise.
    func setQuery(_ query: String) {
        self.query = query
        updateSearchBar()
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

    /// Replaces every row view with ones built from `rows`.
    func render(_ rows: [DisplayRow], metrics: HUDMetrics) {
        self.rows = rows
        self.metrics = metrics
        rowViews.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (rowIndex, row) in rows.enumerated() {
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
                let view = SwitcherRowView(displayIndex: rowIndex, metrics: metrics)
                view.delegate = rowDelegate
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
                rowViews[rowIndex] = view
            }
        }
    }

    /// Drops every row view (between sessions).
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
        var contentHeight: CGFloat = stack.edgeInsets.top + stack.edgeInsets.bottom
        for (i, row) in rows.enumerated() {
            switch row {
            case .header: contentHeight += metrics.headerHeight
            case .item: contentHeight += metrics.rowHeight
            }
            if i < rows.count - 1 { contentHeight += stack.spacing }
        }
        if rows.isEmpty { contentHeight += metrics.rowHeight }
        return searchHeight.constant + min(contentHeight, maxListHeight)
    }
}
