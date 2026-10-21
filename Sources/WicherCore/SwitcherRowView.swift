import AppKit

@MainActor
protocol SwitcherRowViewDelegate: AnyObject {
    func rowHovered(displayIndex: Int)
    func rowClicked(displayIndex: Int)
    /// The pointer left the item at `displayIndex`.
    func rowUnhovered(displayIndex: Int)
}

/// A single list row laid out like a classic window switcher:
/// `[ app name — right aligned ] [ icon ] [ window title … ] [ note ]`, or
/// just `[ icon ] [ window title … ] [ note ]` when the metrics have no app
/// column. The note — faint, why a window is in the bottom group — is there
/// only for those rows.
/// All colors are semantic, so the row adapts to Light/Dark automatically.
///
/// Reused across renders (see `SwitcherListView`), so `displayIndex` and the
/// content change; the metrics a row was built with do not. Subviews are
/// placed by frame — every dimension is already known from `HUDMetrics`.
final class SwitcherRowView: NSView {
    weak var delegate: SwitcherRowViewDelegate?
    var displayIndex = 0
    private let metrics: HUDMetrics

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let appField = NSTextField(labelWithString: "")
    private let noteField = NSTextField(labelWithString: "")
    /// The selection highlight, behind the content; made on first selection.
    private var highlightView: SurfaceView?
    /// Set on mouse-down inside this row, so a drag that merely *ends* over
    /// a row does not activate it.
    private var pressed = false

    var isSelected: Bool = false {
        didSet { if isSelected != oldValue { applySelectionAppearance() } }
    }

    init(metrics: HUDMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .systemFont(ofSize: metrics.titleSize, weight: .regular)

        appField.lineBreakMode = .byTruncatingTail
        appField.font = .systemFont(ofSize: metrics.appSize, weight: .regular)
        appField.alignment = .right
        appField.textColor = .secondaryLabelColor

        noteField.lineBreakMode = .byTruncatingTail
        noteField.font = .systemFont(ofSize: metrics.appSize, weight: .regular)
        noteField.alignment = .right
        noteField.textColor = .tertiaryLabelColor

        appField.isHidden = metrics.appColumnWidth == 0
        for v in [appField, iconView, titleField, noteField] { addSubview(v) }

        // `.inVisibleRect` keeps the hover region matched to what is actually
        // visible as the list scrolls; AppKit maintains the rect for us.
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
        applySelectionAppearance()
    }

    required init?(coder: NSCoder) { preconditionFailure("not used") }

    func configure(icon: NSImage?, title: NSAttributedString, appName: String, note: String? = nil) {
        iconView.image = icon
        titleField.attributedStringValue = title
        appField.stringValue = appName
        noteField.stringValue = note ?? ""   // pooled: a main-group row must lose the last one's
        noteField.isHidden = note == nil
        needsLayout = true
        applySelectionAppearance()   // the background may have changed since the last session
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        func centered(_ x: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(x: x, y: ((h - height) / 2).rounded(), width: max(0, width), height: height)
        }
        var iconX = HUDMetrics.rowLeadingInset
        if metrics.appColumnWidth > 0 {
            let appHeight = ceil(appField.intrinsicContentSize.height)
            appField.frame = centered(HUDMetrics.rowLeadingInset, metrics.appColumnWidth, appHeight)
            iconX = appField.frame.maxX + HUDMetrics.appToIcon
        }
        iconView.frame = centered(iconX, metrics.iconSize, metrics.iconSize)
        let titleX = iconView.frame.maxX + HUDMetrics.iconToTitle
        var titleEnd = bounds.width - HUDMetrics.rowTrailingInset
        if !noteField.isHidden {
            // The whole note's size: a truncating field's intrinsic width
            // follows its current frame.
            let size = noteField.cell?.cellSize ?? noteField.intrinsicContentSize
            let width = min(ceil(size.width), (bounds.width * HUDMetrics.maxNoteFraction).rounded(.down))
            noteField.frame = centered(titleEnd - width, width, ceil(size.height))
            titleEnd = noteField.frame.minX - HUDMetrics.titleToNote
        }
        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        titleField.frame = centered(titleX, titleEnd - titleX, titleHeight)
    }

    /// Settings are read here, when the selection changes, so a change
    /// shows the next time the panel opens.
    private func applySelectionAppearance() {
        let settings = Settings.shared
        if isSelected {
            highlightView = highlightView ?? SurfaceView.highlight(in: self, cornerRadius: metrics.rowCornerRadius)
            highlightView?.surface = settings.highlightSurface
        }
        highlightView?.isHidden = !isSelected
        let text = SurfaceView.textAppearance(selected: isSelected)
        for field in [titleField, appField, noteField] { field.appearance = text }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySelectionAppearance()
    }

    override func mouseEntered(with event: NSEvent) { delegate?.rowHovered(displayIndex: displayIndex) }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        delegate?.rowClicked(displayIndex: displayIndex)
    }
}
