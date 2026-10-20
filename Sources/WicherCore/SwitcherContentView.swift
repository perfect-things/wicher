import AppKit

/// What `SwitcherController` needs from the panel's content, whatever the
/// switcher's layout: `SwitcherListView` (rows) or `SwitcherIconGridView`
/// (one row of icons). Neither knows about sessions, screens or the panel.
@MainActor
protocol SwitcherContentView: NSView {
    /// Receives hover/click from every item the view creates.
    var rowDelegate: SwitcherRowViewDelegate? { get set }
    /// Reads the appearance settings — sizes, background — for a new
    /// session on a screen of `screenSize`.
    func beginSession(screenSize: CGSize)
    /// Shows the search bar for a non-empty query; hides it otherwise.
    func setQuery(_ query: String)
    /// Shown in the search bar's place whenever there is no query.
    func setNotice(_ notice: String?)
    func render(_ rows: [DisplayRow])
    /// Highlights the item at `rowIndex` (nil highlights nothing).
    func highlight(rowIndex: Int?)
    /// The item under the pointer, or nil when it left the items.
    func setHovered(rowIndex: Int?)
    /// Clears the hover only if it is still `ifHovering`: entering the next
    /// item can arrive before leaving the last.
    func setHovered(rowIndex: Int?, ifHovering: Int)
    /// Hides every item (between sessions).
    func clear()
    /// The panel window's size for what is rendered.
    var preferredWindowSize: CGSize { get }
}

/// The search query (or a notice) across the top of the panel, after a
/// symbol: a magnifying glass, or a warning sign. Zero height when there is
/// neither. Placed by frame inside; only its height is a constraint.
final class HUDSearchBar: NSView {
    /// Where and how big the text is.
    struct Metrics: Equatable {
        var height: CGFloat
        var fontSize: CGFloat
        /// The text's vertical center, from the bar's top.
        var centerY: CGFloat
        /// Space kept from either side.
        var inset: CGFloat
        /// Centered across the bar, else leading.
        var centered: Bool

        /// The List's: a bar of its own above the rows.
        static let list = Metrics(height: 52, fontSize: 18, centerY: 26, inset: 22, centered: false)
    }

    var metrics = Metrics.list {
        didSet { if metrics != oldValue { update() } }
    }

    private let symbol = NSImageView()
    private let field = NSTextField(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint!
    private var query = ""
    private var notice: String?

    /// Between the symbol and the text, as a share of the font size.
    private static let symbolGap: CGFloat = 0.45

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        field.lineBreakMode = .byTruncatingTail
        symbol.imageScaling = .scaleNone
        symbol.contentTintColor = .secondaryLabelColor
        addSubview(symbol)
        addSubview(field)

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
        update()
    }

    required init?(coder: NSCoder) { preconditionFailure("not used") }

    /// The bar's height for the current query and notice.
    var barHeight: CGFloat { heightConstraint.constant }

    func setQuery(_ query: String) {
        self.query = query
        update()
    }

    func setNotice(_ notice: String?) {
        self.notice = notice
        update()
    }

    /// See `SurfaceView.textAppearance`.
    func setTextAppearance(_ appearance: NSAppearance?) {
        field.appearance = appearance
        symbol.appearance = appearance
    }

    private func update() {
        let size: CGFloat
        let symbolName: String?
        if !query.isEmpty {
            size = metrics.fontSize
            symbolName = "magnifyingglass"
            field.stringValue = query
            field.font = .systemFont(ofSize: size, weight: .regular)
            field.textColor = .labelColor
        } else if let notice {
            size = min(13, metrics.fontSize)
            symbolName = "exclamationmark.triangle.fill"
            field.stringValue = notice
            field.font = .systemFont(ofSize: size, weight: .medium)
            field.textColor = .secondaryLabelColor
        } else {
            size = metrics.fontSize
            symbolName = nil
            field.stringValue = ""
        }
        symbol.image = symbolName
            .flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        symbol.isHidden = symbol.image == nil
        heightConstraint.constant = (query.isEmpty && notice == nil) ? 0 : metrics.height
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let fontSize = field.font?.pointSize ?? metrics.fontSize
        let symbolSize = symbol.image?.size ?? .zero
        let gap = symbol.isHidden ? 0 : (fontSize * Self.symbolGap).rounded()
        let available = max(0, bounds.width - 2 * metrics.inset - symbolSize.width - gap)
        // The whole text's size: a truncating field's intrinsic width
        // follows its current frame, so it never grew past the last one.
        let textSize = field.cell?.cellSize ?? field.intrinsicContentSize
        let textWidth = min(ceil(textSize.width), available)
        let groupWidth = symbolSize.width + gap + textWidth
        var x = metrics.centered ? ((bounds.width - groupWidth) / 2).rounded() : metrics.inset
        // Not flipped: y runs up from the bottom.
        let midY = bounds.height - metrics.centerY
        symbol.frame = NSRect(x: x, y: (midY - symbolSize.height / 2).rounded(),
                              width: symbolSize.width, height: symbolSize.height)
        x += symbolSize.width + gap
        field.frame = NSRect(x: x, y: (midY - ceil(textSize.height) / 2).rounded(),
                             width: textWidth, height: ceil(textSize.height))
    }
}

extension NSColor {
    /// Matched search text in titles: pastel amber on dark, a deeper amber
    /// that still reads on light.
    static let searchMatch = NSColor(name: "searchMatch") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 1.0, green: 0.80, blue: 0.42, alpha: 1)
            : NSColor(srgbRed: 0.80, green: 0.42, blue: 0.0, alpha: 1)
    }
}

extension NSMutableAttributedString {
    /// Colors the ranges a search matched (see `FuzzyMatcher`).
    func highlightSearchMatches(_ ranges: [NSRange]) {
        for range in ranges where range.location + range.length <= length {
            addAttribute(.foregroundColor, value: NSColor.searchMatch, range: range)
        }
    }
}
