import AppKit

/// The stage the icons are placed on, top to bottom like `IconGridLayout`.
private final class FlippedStage: NSView {
    override var isFlipped: Bool { true }
}

/// The Icons layout's whole content: the rounded background, the search bar,
/// a row of window icons — plus a second one for the bottom group, below a
/// separator — and the title of the hovered — else the selected — window
/// underneath. Geometry comes from `IconGridLayout`; cells are pooled and
/// placed by frame, like the List's rows.
///
/// One icon per window: an app with three windows shows its icon three
/// times, and the title tells them apart. The bottom group's notes are not
/// shown here.
final class SwitcherIconGridView: NSView, SwitcherContentView {
    weak var rowDelegate: SwitcherRowViewDelegate?

    private let backdrop = SurfaceView.panel()
    private let searchBar = HUDSearchBar()
    private let stage = FlippedStage()
    private let titleField = NSTextField(labelWithString: "")
    private let separator = HUDSeparatorView()
    /// Shown in place of the icons when there are none.
    private let emptyLabel = NSTextField(labelWithString: "")

    private var query = ""
    private var rows: [DisplayRow] = []
    /// `rows` index of each cell, left to right.
    private var itemRows: [Int] = []
    private var selectedRow: Int?
    private var hoveredRow: Int?
    private var cellPool: [SwitcherIconCellView] = []

    private var iconSize = 96
    private var padding = 8
    private var textSize = 13
    private var spacing = 12
    private var maxPanelWidth: CGFloat = 1368
    private(set) var layoutInfo = IconGridLayout.make(iconSize: 96, padding: 8, textSize: 13, spacing: 12,
                                                      itemCount: 0, maxPanelWidth: 1368)

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

        stage.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stage)
        content.addSubview(searchBar)   // over the stage's top padding

        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.alignment = .center
        titleField.cell?.usesSingleLineMode = true
        stage.addSubview(titleField)
        separator.isHidden = true
        stage.addSubview(separator)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        stage.addSubview(emptyLabel)

        // The visible panel sits `windowMargin` inside this view; see `HUDMetrics.windowMargin`.
        let margin = HUDMetrics.glassWindowMargin
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin),

            searchBar.topAnchor.constraint(equalTo: content.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            stage.topAnchor.constraint(equalTo: content.topAnchor),
            stage.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    // MARK: - SwitcherContentView

    func beginSession(screenSize: CGSize) {
        let settings = Settings.shared
        iconSize = settings.gridIconSize
        padding = settings.gridIconPadding
        textSize = settings.gridTextSize
        spacing = settings.gridIconSpacing
        maxPanelWidth = (screenSize.width * IconGridLayout.maxScreenFraction).rounded(.down)
        backdrop.surface = settings.backgroundSurface
        applyTextAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTextAppearance()
    }

    private func applyTextAppearance() {
        let text = SurfaceView.textAppearance(selected: false)
        searchBar.setTextAppearance(text)
        titleField.appearance = text
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

    /// Lays the icons out with the settings from `beginSession` — or, in
    /// tests, `configure`.
    func render(_ rows: [DisplayRow]) {
        self.rows = rows
        selectedRow = nil
        hoveredRow = nil

        itemRows = rows.indices.filter {
            if case .item = rows[$0] { return true }
            return false
        }
        // One row of icons per group: a separator starts the next.
        var rowCounts = [0]
        for row in rows {
            if case .separator = row { rowCounts.append(0) } else { rowCounts[rowCounts.count - 1] += 1 }
        }
        layoutInfo = IconGridLayout.make(iconSize: iconSize, padding: padding, textSize: textSize, spacing: spacing,
                                         rowCounts: rowCounts, maxPanelWidth: maxPanelWidth)
        backdrop.cornerRadius = layoutInfo.panelCornerRadius
        // The search text sits in the top padding the way the title sits in
        // the bottom one: same size, mirrored, so the panel doesn't grow.
        searchBar.metrics = HUDSearchBar.Metrics(
            height: layoutInfo.inset, fontSize: layoutInfo.titleSize,
            centerY: IconGridLayout.titleBottomGap + layoutInfo.titleHeight / 2, inset: layoutInfo.inset,
            centered: true)

        while cellPool.count < itemRows.count {
            let cell = SwitcherIconCellView()
            cell.delegate = rowDelegate
            cellPool.append(cell)
            stage.addSubview(cell, positioned: .below, relativeTo: titleField)
        }
        for (i, rowIndex) in itemRows.enumerated() {
            guard case let .item(info, _, _) = rows[rowIndex] else { continue }
            let cell = cellPool[i]
            cell.displayIndex = rowIndex
            cell.isSelected = false
            cell.configure(icon: info.appIcon, iconSize: layoutInfo.iconSize,
                           cornerRadius: layoutInfo.highlightCornerRadius,
                           showsHighlight: layoutInfo.padding > 0)
            cell.frame = layoutInfo.cellFrames[i]
            cell.isHidden = false
        }
        cellPool[itemRows.count...].forEach { $0.isHidden = true }
        separator.frame = layoutInfo.separatorFrame ?? .zero
        separator.isHidden = layoutInfo.separatorFrame == nil

        titleField.font = .systemFont(ofSize: layoutInfo.titleSize, weight: .regular)
        updateEmptyLabel()
        updateTitle()
    }

    /// For tests: the sizes `beginSession` would read from the settings.
    func configure(iconSize: Int, padding: Int, textSize: Int, spacing: Int, maxPanelWidth: CGFloat) {
        self.iconSize = iconSize
        self.padding = padding
        self.textSize = textSize
        self.spacing = spacing
        self.maxPanelWidth = maxPanelWidth
    }

    func highlight(rowIndex: Int?) {
        selectedRow = rowIndex
        for cell in cellPool where !cell.isHidden {
            cell.isSelected = cell.displayIndex == rowIndex
        }
        updateTitle()
    }

    func setHovered(rowIndex: Int?) {
        hoveredRow = rowIndex
        updateTitle()
    }

    func setHovered(rowIndex: Int?, ifHovering previous: Int) {
        if hoveredRow == previous { setHovered(rowIndex: rowIndex) }
    }

    func clear() {
        render([])
    }

    var preferredWindowSize: CGSize {
        layoutInfo.windowSize
    }

    func rowIndex(from rowIndex: Int, movingRows step: Int) -> Int? {
        guard let item = itemRows.firstIndex(of: rowIndex),
              let target = layoutInfo.item(item, movedRows: step) else { return nil }
        return itemRows[target]
    }

    // MARK: - Title

    /// The title of the hovered icon, else the selected one's; placed under
    /// its icon, inside the panel's edges, truncated in the middle.
    private func updateTitle() {
        guard let rowIndex = hoveredRow ?? selectedRow, rows.indices.contains(rowIndex),
              case let .item(info, ranges, _) = rows[rowIndex],
              let item = itemRows.firstIndex(of: rowIndex) else {
            titleField.isHidden = true
            return
        }
        titleField.attributedStringValue = attributedTitle(info.displayTitle, ranges: ranges)
        titleField.isHidden = false
        // The whole title's size: a middle-truncating field's intrinsic
        // width is already truncated.
        let size = titleField.cell?.cellSize ?? titleField.intrinsicContentSize
        var frame = layoutInfo.titleFrame(forItem: item, textWidth: size.width)
        frame.size.height = ceil(size.height)
        frame.origin.y += ((layoutInfo.titleHeight - frame.height) / 2).rounded()
        titleField.frame = frame
    }

    private func attributedTitle(_ title: String, ranges: [NSRange]) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attr = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: layoutInfo.titleSize, weight: .medium),
            .paragraphStyle: paragraph,
        ])
        attr.highlightSearchMatches(ranges)
        return attr
    }

    /// "No matching windows" while searching, "No windows" otherwise.
    private func updateEmptyLabel() {
        emptyLabel.isHidden = !itemRows.isEmpty
        emptyLabel.stringValue = query.isEmpty ? "No windows" : "No matching windows"
        emptyLabel.font = .systemFont(ofSize: layoutInfo.titleSize, weight: .regular)
        let height = ceil(emptyLabel.intrinsicContentSize.height)
        let inset = layoutInfo.inset
        let rowHeight = layoutInfo.panelSize.height - 2 * inset
        emptyLabel.frame = NSRect(x: inset, y: inset + ((rowHeight - height) / 2).rounded(),
                                  width: layoutInfo.panelSize.width - 2 * inset, height: height)
    }
}

/// One window's icon in the Icons layout, with the selection highlight
/// behind it. Pooled; its frame and sizes change with each render.
final class SwitcherIconCellView: NSView {
    weak var delegate: SwitcherRowViewDelegate?
    var displayIndex = 0

    private let iconView = NSImageView()
    private var iconSize: CGFloat = 0
    private var cornerRadius: CGFloat = 0
    private var showsHighlight = true
    /// Made on first selection.
    private var highlightView: SurfaceView?
    /// Set on mouse-down inside this cell, so a drag that merely *ends*
    /// over it does not activate it.
    private var pressed = false

    var isSelected = false {
        didSet { if isSelected != oldValue { applySelection() } }
    }

    init() {
        super.init(frame: .zero)
        clipsToBounds = false   // the icon image's transparent margin overhangs the highlight
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    required init?(coder: NSCoder) { preconditionFailure("not used") }

    /// Without padding the highlight would be all behind the icon — but for
    /// the glow glass spills past its edge — so there is none.
    func configure(icon: NSImage?, iconSize: CGFloat, cornerRadius: CGFloat, showsHighlight: Bool) {
        iconView.image = icon
        self.showsHighlight = showsHighlight
        self.iconSize = iconSize
        self.cornerRadius = cornerRadius
        highlightView?.cornerRadius = cornerRadius
        needsLayout = true
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: ((bounds.width - iconSize) / 2).rounded(),
                                y: ((bounds.height - iconSize) / 2).rounded(),
                                width: iconSize, height: iconSize)
    }

    /// The highlight style is read here, so a change shows the next time the
    /// panel opens.
    private func applySelection() {
        let visible = isSelected && showsHighlight
        if visible {
            highlightView = highlightView ?? SurfaceView.highlight(in: self, cornerRadius: cornerRadius)
            highlightView?.cornerRadius = cornerRadius
            highlightView?.surface = Settings.shared.highlightSurface
        }
        highlightView?.isHidden = !visible
    }

    override func mouseEntered(with event: NSEvent) { delegate?.rowHovered(displayIndex: displayIndex) }

    override func mouseExited(with event: NSEvent) { delegate?.rowUnhovered(displayIndex: displayIndex) }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        delegate?.rowClicked(displayIndex: displayIndex)
    }
}
