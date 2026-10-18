import AppKit

/// Resolved pixel metrics for the switcher, derived from the user's sliders:
/// icon size, text size, row padding, and a width scale on top of the
/// icon-derived panel width. Row padding is the vertical space above/below
/// the row content. Rows are packed with zero inter-row spacing; density is
/// controlled entirely by padding.
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
    /// Width of the right-aligned app-name column left of the icon:
    /// `appColumnFraction` of the panel, or zero when app names are turned
    /// off (`Settings.showAppNames`).
    let appColumnWidth: CGFloat
    let panelCornerRadius: CGFloat
    /// Gap between the panel edge and the rows, the same on all four sides.
    let listInset: CGFloat
    let rowCornerRadius: CGFloat
    /// Transparent space between the panel window's edge and the visible
    /// panel. Liquid Glass renders a soft edge slightly *outside* its bounds;
    /// with the window cut flush to the glass, the window's square corners
    /// clipped that edge into visible patches.
    let windowMargin: CGFloat
    /// The panel window's size for a given visible panel height.
    func windowSize(panelHeight: CGFloat) -> CGSize {
        CGSize(width: panelWidth + 2 * windowMargin, height: panelHeight + 2 * windowMargin)
    }

    static let defaultPanelCornerRadius: CGFloat = 24
    static let defaultListInset: CGFloat = 8

    static let iconRange: ClosedRange<Int> = 16...56
    static let textRange: ClosedRange<Int> = 10...32
    static let paddingRange: ClosedRange<Int> = 0...40
    /// Percent applied to the icon-derived panel width.
    static let widthScaleRange: ClosedRange<Int> = 30...150

    /// Horizontal layout of a row (see `SwitcherRowView`).
    static let rowLeadingInset: CGFloat = 14
    static let rowTrailingInset: CGFloat = 16
    static let appToIcon: CGFloat = 10
    static let iconToTitle: CGFloat = 12
    /// Share of the panel width given to the app-name column, so it keeps
    /// its proportion however wide or narrow the panel is.
    static let appColumnFraction: CGFloat = 0.25
    /// However narrow the width scale, a title keeps at least this much room.
    static let minTitleWidth: CGFloat = 120

    static func make(iconSize: Int, textSize: Int, rowPadding: Int, widthScale: Int = 100,
                     showAppNames: Bool = true) -> HUDMetrics {
        let i = CGFloat(iconSize.clamped(to: iconRange))
        let t = CGFloat(textSize.clamped(to: textRange))
        let pad = CGFloat(rowPadding.clamped(to: paddingRange))
        let scale = CGFloat(widthScale.clamped(to: widthScaleRange)) / 100
        // Everything in a row but the app column and the title, plus the list
        // inset either side; the narrowest panel still fits a minimum title.
        let fixed = 2 * defaultListInset + rowLeadingInset + (showAppNames ? appToIcon : 0)
            + i + iconToTitle + rowTrailingInset
        let minWidth = showAppNames
            ? ((fixed + minTitleWidth) / (1 - appColumnFraction)).rounded(.up)
            : fixed + minTitleWidth
        let panelWidth = max(minWidth, (max(520, 440 + i * 6) * scale).rounded())
        let content = max(i, t)
        let rowHeight = content + pad * 2
        return HUDMetrics(
            iconSize: i,
            titleSize: t,
            appSize: max(10, (t * 0.82).rounded()),
            rowHeight: rowHeight,
            headerHeight: max(20, (t * 1.5).rounded()),
            panelWidth: panelWidth,
            appColumnWidth: showAppNames ? (panelWidth * appColumnFraction).rounded(.down) : 0,
            panelCornerRadius: defaultPanelCornerRadius,
            listInset: defaultListInset,
            // Concentric with the panel, but never more than a capsule.
            rowCornerRadius: min(defaultPanelCornerRadius - defaultListInset, rowHeight / 2),
            windowMargin: glassWindowMargin
        )
    }

    static let glassWindowMargin: CGFloat = 24
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
