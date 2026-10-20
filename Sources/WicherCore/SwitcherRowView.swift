import AppKit

@MainActor
protocol SwitcherRowViewDelegate: AnyObject {
    func rowHovered(displayIndex: Int)
    func rowClicked(displayIndex: Int)
}

/// A single list row laid out like a classic window switcher:
/// `[ app name — right aligned ] [ icon ] [ window title … ]`, or just
/// `[ icon ] [ window title … ]` when the metrics have no app column.
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
    /// Behind the content for the glass highlight styles; made on first use.
    private var glassView: NSGlassEffectView?
    /// Set on mouse-down inside this row, so a drag that merely *ends* over
    /// a row does not activate it.
    private var pressed = false

    var isSelected: Bool = false {
        didSet { if isSelected != oldValue { applySelectionAppearance() } }
    }

    init(metrics: HUDMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = metrics.rowCornerRadius
        layer?.cornerCurve = .continuous

        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .systemFont(ofSize: metrics.titleSize, weight: .regular)

        appField.lineBreakMode = .byTruncatingTail
        appField.font = .systemFont(ofSize: metrics.appSize, weight: .regular)
        appField.alignment = .right
        appField.textColor = .secondaryLabelColor

        appField.isHidden = metrics.appColumnWidth == 0
        for v in [appField, iconView, titleField] { addSubview(v) }

        // `.inVisibleRect` keeps the hover region matched to what is actually
        // visible as the list scrolls; AppKit maintains the rect for us.
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
        applySelectionAppearance()
    }

    required init?(coder: NSCoder) { preconditionFailure("not used") }

    func configure(icon: NSImage?, title: NSAttributedString, appName: String) {
        iconView.image = icon
        titleField.attributedStringValue = title
        appField.stringValue = appName
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
        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        titleField.frame = centered(titleX, bounds.width - HUDMetrics.rowTrailingInset - titleX, titleHeight)
    }

    private func applySelectionAppearance() {
        let style = Settings.shared.highlightStyle
        if isSelected && style.isGlass { showGlass(style) } else { glassView?.isHidden = true }

        // Colors are resolved to CGColors here, so re-apply when the
        // effective appearance (light/dark) changes too.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor
            switch (isSelected, style) {
            case (false, _), (true, .glass), (true, .clearGlass), (true, .tintedGlass): fill = .clear
            case (true, .accent): fill = .controlAccentColor
            case (true, .neutral): fill = NSColor.labelColor.withAlphaComponent(0.1)
            }
            layer?.backgroundColor = fill.cgColor
        }
        let onAccent = isSelected && style == .accent
        titleField.textColor = onAccent ? .alternateSelectedControlTextColor : .labelColor
        appField.textColor = onAccent
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.85)
            : .secondaryLabelColor
    }

    private func showGlass(_ style: HighlightStyle) {
        let glass = glassView ?? {
            let glass = NSGlassEffectView()
            glass.cornerRadius = metrics.rowCornerRadius
            glass.frame = bounds
            glass.autoresizingMask = [.width, .height]
            addSubview(glass, positioned: .below, relativeTo: nil)
            glassView = glass
            return glass
        }()
        glass.style = style == .clearGlass ? .clear : .regular
        glass.tintColor = style == .tintedGlass ? NSColor.controlAccentColor.withAlphaComponent(0.4)
            : effectiveAppearance.isDark ? nil : HighlightStyle.lightRowTint
        glass.isHidden = false
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

/// A dim, centered section header ("Minimized", "Apps", …). Not selectable.
final class SwitcherHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; needsLayout = true }
    }

    init(metrics: HUDMetrics) {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: metrics.appSize, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { preconditionFailure("not used") }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
    }
}
