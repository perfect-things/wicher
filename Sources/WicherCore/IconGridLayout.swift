import AppKit

/// Geometry of the Icons layout: a row of icons, like the system ⌘Tab
/// switcher, with the hovered or selected window's title underneath. The
/// bottom group (see `WindowGroups`) gets a second row of its own, below a
/// thin separator; both rows share one scale, and each is centered.
///
/// Everything is derived here from the user's sliders and the item count, so
/// `SwitcherIconGridView` only places views. Coordinates are flipped (y down)
/// and relative to the visible panel below the search bar.
///
/// As in the system switcher, the panel's padding is the same on every side
/// and the title sits inside the bottom padding, so the icons are centered.
/// When the wider row would be wider than `maxScreenFraction` of the screen, icons,
/// their padding and spacing all shrink by the same factor; the title's text
/// size does not.
///
/// An app icon's image has a transparent margin around the visible shape
/// (Apple's grid: an 824-point rounded rect on a 1024 canvas). The highlight
/// hugs that shape, not the image, so padding 0 puts it exactly behind the
/// icon, and corners are concentric: the highlight's radius is the shape's
/// plus the padding, and the panel's is the highlight's plus `inset`.
struct IconGridLayout: Equatable {
    /// The icon image's side after fitting, margin included.
    let iconSize: CGFloat
    /// Space between the icon's visible shape and the edge of its selection
    /// highlight.
    let padding: CGFloat
    /// The selection highlight's side: the icon's shape plus padding around
    /// it. The image overhangs it by its margin when padding is smaller.
    let cellSize: CGFloat
    let spacing: CGFloat
    /// Shrink factor applied to fit the screen; 1 when it fits as is.
    let scale: CGFloat
    let titleSize: CGFloat
    let titleHeight: CGFloat
    /// Top of the title line.
    let titleY: CGFloat
    /// Space between the panel's edge and the icons, on every side; the
    /// title sits in the bottom one.
    let inset: CGFloat
    let highlightCornerRadius: CGFloat
    let panelCornerRadius: CGFloat
    /// The visible panel, without the search bar or `windowMargin`.
    let panelSize: CGSize
    /// One per item, left to right, top row first.
    let cellFrames: [CGRect]
    /// The `cellFrames` indexes of each row, top to bottom.
    let rows: [Range<Int>]
    /// The line between the rows; nil with fewer than two.
    let separatorFrame: CGRect?

    static let iconRange: ClosedRange<Int> = 32...160
    static let paddingRange: ClosedRange<Int> = 0...32
    static let textRange: ClosedRange<Int> = 10...24
    static let spacingRange: ClosedRange<Int> = 0...40
    /// The panel's widest, as a share of the screen's width.
    static let maxScreenFraction: CGFloat = 0.95
    /// The least padding around the icons; the title usually needs more.
    static let minInset: CGFloat = 16
    /// Between the highlight and the title.
    static let titleGap: CGFloat = 4
    /// Between the title and the panel's bottom edge.
    static let titleBottomGap: CGFloat = 8
    /// With no icons at all, room for "No windows" / "No matching windows".
    /// Otherwise the panel fits its icons, like ⌘Tab: a lone icon's long
    /// title is truncated rather than widening the panel.
    static let emptyPanelWidth: CGFloat = 320
    /// Shrinking stops here; past it, the row is wider than the screen.
    static let minIconSize: CGFloat = 8
    /// Between a row's highlights and the separator, above and below it.
    static let separatorGap: CGFloat = 8
    static let separatorThickness: CGFloat = 1
    /// The visible shape of a macOS app icon, as a share of the image's side.
    static let iconShapeFraction: CGFloat = 824.0 / 1024
    /// That shape's corner radius, as a share of the image's side.
    static let iconCornerFraction: CGFloat = 185.4 / 1024

    /// A single row of `count` icons.
    static func make(iconSize: Int, padding: Int, textSize: Int, spacing: Int, itemCount count: Int,
                     maxPanelWidth: CGFloat) -> IconGridLayout {
        make(iconSize: iconSize, padding: padding, textSize: textSize, spacing: spacing,
             rowCounts: [count], maxPanelWidth: maxPanelWidth)
    }

    /// `rowCounts`: the icons in each row, top to bottom; empty rows are
    /// dropped. `maxPanelWidth` is the widest the visible panel may be (see
    /// `maxScreenFraction`).
    static func make(iconSize: Int, padding: Int, textSize: Int, spacing: Int, rowCounts: [Int],
                     maxPanelWidth: CGFloat) -> IconGridLayout {
        let counts = rowCounts.filter { $0 > 0 }
        let count = counts.max() ?? 0   // the wider row decides the scale
        let icon = CGFloat(iconSize.clamped(to: iconRange))
        let pad = CGFloat(padding.clamped(to: paddingRange))
        let space = CGFloat(spacing.clamped(to: spacingRange))
        let t = CGFloat(textSize.clamped(to: textRange))
        let titleHeight = (t * 1.3).rounded(.up)
        let inset = max(minInset, titleGap + titleHeight + titleBottomGap)

        func cellSide(icon: CGFloat, pad: CGFloat) -> CGFloat { (icon * iconShapeFraction).rounded() + 2 * pad }
        func rowWidth(_ count: Int, icon: CGFloat, pad: CGFloat, space: CGFloat) -> CGFloat {
            count > 0 ? CGFloat(count) * cellSide(icon: icon, pad: pad) + CGFloat(count - 1) * space : 0
        }

        let available = maxPanelWidth - 2 * inset
        let natural = rowWidth(count, icon: icon, pad: pad, space: space)
        let scale = natural > available && natural > 0 ? available / natural : 1
        // Floored, so the scaled parts never add up to more than `available`.
        let fittedIcon = max(minIconSize, (icon * scale).rounded(.down))
        let fittedPad = (pad * scale).rounded(.down)
        let fittedSpace = (space * scale).rounded(.down)
        let cell = cellSide(icon: fittedIcon, pad: fittedPad)
        let row = rowWidth(count, icon: fittedIcon, pad: fittedPad, space: fittedSpace)

        let panelWidth = count > 0 ? min(row + 2 * inset, maxPanelWidth) : emptyPanelWidth

        var frames: [CGRect] = []
        var rows: [Range<Int>] = []
        var separator: CGRect?
        var y = inset
        for (r, n) in counts.enumerated() {
            if r > 0 {
                separator = CGRect(x: inset, y: y + separatorGap,
                                   width: panelWidth - 2 * inset, height: separatorThickness)
                y += 2 * separatorGap + separatorThickness
            }
            var x = ((panelWidth - rowWidth(n, icon: fittedIcon, pad: fittedPad, space: fittedSpace)) / 2)
                .rounded(.down)
            rows.append(frames.count..<(frames.count + n))
            for _ in 0..<n {
                frames.append(CGRect(x: x, y: y, width: cell, height: cell))
                x += cell + fittedSpace
            }
            y += cell
        }
        // An empty list keeps the height of a full-size row (it shows "No windows").
        let rowsBottom = count > 0 ? y : inset + cellSide(icon: icon, pad: pad)

        let highlightRadius = (fittedIcon * iconCornerFraction).rounded() + fittedPad
        return IconGridLayout(
            iconSize: fittedIcon,
            padding: fittedPad,
            cellSize: cell,
            spacing: fittedSpace,
            scale: scale,
            titleSize: t,
            titleHeight: titleHeight,
            titleY: rowsBottom + titleGap,
            inset: inset,
            highlightCornerRadius: highlightRadius,
            panelCornerRadius: highlightRadius + inset,
            panelSize: CGSize(width: panelWidth, height: rowsBottom + inset),
            cellFrames: frames,
            rows: rows,
            separatorFrame: separator
        )
    }

    /// For Up/Down: the item in the row `step` rows away from item `index`'s
    /// whose center is nearest its center (the left one on a tie). `index`
    /// itself when there is no such row; nil with a single row, where Up/Down
    /// move through the items like Left/Right.
    func item(_ index: Int, movedRows step: Int) -> Int? {
        guard rows.count > 1, let r = rows.firstIndex(where: { $0.contains(index) }) else { return nil }
        guard rows.indices.contains(r + step) else { return index }
        let midX = cellFrames[index].midX
        return rows[r + step].min { abs(cellFrames[$0].midX - midX) < abs(cellFrames[$1].midX - midX) }
    }

    /// The title line for the item at `index`: centered under its icon, but
    /// slid back inside the panel near an edge, and never wider than the
    /// panel's content (the text is truncated in the middle to fit). With two
    /// rows it is centered in the panel: under the bottom row, an offset
    /// would point at the wrong icon.
    func titleFrame(forItem index: Int, textWidth: CGFloat) -> CGRect {
        let width = min(textWidth.rounded(.up), panelSize.width - 2 * inset)
        let midX = rows.count < 2 && cellFrames.indices.contains(index) ? cellFrames[index].midX : panelSize.width / 2
        let x = (midX - width / 2).rounded().clamped(to: inset...(panelSize.width - inset - width))
        return CGRect(x: x, y: titleY, width: width, height: titleHeight)
    }

    /// The panel window's size. The search bar adds nothing: it sits in the
    /// top padding, mirroring the title in the bottom one.
    var windowSize: CGSize {
        let margin = HUDMetrics.glassWindowMargin
        return CGSize(width: panelSize.width + 2 * margin, height: panelSize.height + 2 * margin)
    }
}
