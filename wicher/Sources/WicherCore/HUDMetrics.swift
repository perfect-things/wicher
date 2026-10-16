import AppKit

/// Resolved pixel metrics for the switcher, derived from three user sliders:
/// icon size, text size, and row padding (vertical space above/below the row
/// content). Rows are packed with zero inter-row spacing; density is controlled
/// entirely by padding.
///
/// Corners are concentric: the selection highlight sits `listInset` in from
/// every edge of the panel, so its radius is the panel's minus that inset —
/// the same curve, offset — rather than an unrelated number.
struct HUDMetrics: Equatable {
    let iconSize: CGFloat
    let titleSize: CGFloat
    let appSize: CGFloat
    let rowHeight: CGFloat
    let headerHeight: CGFloat
    let panelWidth: CGFloat
    let appColumnWidth: CGFloat
    let panelCornerRadius: CGFloat
    /// Gap between the panel edge and the rows, the same on all four sides.
    let listInset: CGFloat
    let rowCornerRadius: CGFloat

    static let defaultPanelCornerRadius: CGFloat = 24
    static let defaultListInset: CGFloat = 8

    static let iconRange: ClosedRange<Int> = 16...56
    static let textRange: ClosedRange<Int> = 10...32
    static let paddingRange: ClosedRange<Int> = 0...40

    static func make(iconSize: Int, textSize: Int, rowPadding: Int) -> HUDMetrics {
        let i = CGFloat(iconSize.clamped(to: iconRange))
        let t = CGFloat(textSize.clamped(to: textRange))
        let pad = CGFloat(rowPadding.clamped(to: paddingRange))
        let content = max(i, t)
        let rowHeight = content + pad * 2
        return HUDMetrics(
            iconSize: i,
            titleSize: t,
            appSize: max(10, (t * 0.82).rounded()),
            rowHeight: rowHeight,
            headerHeight: max(20, (t * 1.5).rounded()),
            panelWidth: max(520, 440 + i * 6),
            appColumnWidth: max(120, (i * 5).rounded()),
            panelCornerRadius: defaultPanelCornerRadius,
            listInset: defaultListInset,
            // Concentric with the panel, but never more than a capsule.
            rowCornerRadius: min(defaultPanelCornerRadius - defaultListInset, rowHeight / 2)
        )
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
