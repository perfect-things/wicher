import AppKit

protocol SwitcherRowViewDelegate: AnyObject {
    func rowHovered(displayIndex: Int)
    func rowClicked(displayIndex: Int)
}

/// A single list row laid out like a classic window switcher:
/// `[ app name — right aligned ] [ icon ] [ window title … ]`.
/// All colors are semantic, so the row adapts to Light/Dark automatically.
final class SwitcherRowView: NSView {
    weak var delegate: SwitcherRowViewDelegate?
    let displayIndex: Int

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let appField = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    var isSelected: Bool = false {
        didSet { needsLayout = true }
    }

    init(displayIndex: Int, metrics: HUDMetrics) {
        self.displayIndex = displayIndex
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

        for v in [appField, iconView, titleField] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            appField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            appField.widthAnchor.constraint(equalToConstant: metrics.appColumnWidth),
            appField.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconView.leadingAnchor.constraint(equalTo: appField.trailingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: metrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: metrics.iconSize),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(icon: NSImage?, title: NSAttributedString, appName: String) {
        iconView.image = icon
        titleField.attributedStringValue = title
        appField.stringValue = appName
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        titleField.textColor = isSelected ? .white : .labelColor
        appField.textColor = isSelected ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { delegate?.rowHovered(displayIndex: displayIndex) }
    override func mouseUp(with event: NSEvent) { delegate?.rowClicked(displayIndex: displayIndex) }
}

/// A dim, centered section header ("Minimized", "Apps", …). Not selectable.
final class SwitcherHeaderView: NSView {
    init(title: String, metrics: HUDMetrics) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: metrics.appSize, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}
