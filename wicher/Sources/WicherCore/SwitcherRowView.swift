import AppKit

protocol SwitcherRowViewDelegate: AnyObject {
    func rowHovered(displayIndex: Int)
    func rowClicked(displayIndex: Int)
}

/// A single list row laid out like a classic window switcher:
/// `[ app name — right aligned ] [ icon ] [ window title … ]`.
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
    /// Set on mouse-down inside this row, so a drag that merely *ends* over
    /// a row does not activate it.
    private var pressed = false

    var isSelected: Bool = false {
        didSet { if isSelected != oldValue { applySelectionAppearance() } }
    }

    private static let leadingInset: CGFloat = 14
    private static let trailingInset: CGFloat = 16
    private static let appToIcon: CGFloat = 10
    private static let iconToTitle: CGFloat = 12

    init(metrics: HUDMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .systemFont(ofSize: metrics.titleSize, weight: .regular)

        appField.lineBreakMode = .byTruncatingTail
        appField.font = .systemFont(ofSize: metrics.appSize, weight: .regular)
        appField.alignment = .right
        appField.textColor = .secondaryLabelColor

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
        let appHeight = ceil(appField.intrinsicContentSize.height)
        appField.frame = centered(Self.leadingInset, metrics.appColumnWidth, appHeight)
        iconView.frame = centered(appField.frame.maxX + Self.appToIcon, metrics.iconSize, metrics.iconSize)
        let titleX = iconView.frame.maxX + Self.iconToTitle
        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        titleField.frame = centered(titleX, bounds.width - Self.trailingInset - titleX, titleHeight)
    }

    private func applySelectionAppearance() {
        // The accent color is resolved to a CGColor here, so re-apply when the
        // effective appearance (light/dark) changes too.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.clear.cgColor
        }
        titleField.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        appField.textColor = isSelected
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.85)
            : .secondaryLabelColor
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
