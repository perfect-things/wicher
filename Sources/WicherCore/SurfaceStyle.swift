import AppKit

/// What a surface — the panel's background, or the selected item's
/// highlight — is drawn with.
enum SurfaceStyle: Int, Codable, CaseIterable, Sendable {
    /// Liquid Glass (`NSGlassEffectView`), regular: frosted, it blurs what
    /// is behind it.
    case glass = 0
    /// Liquid Glass, clear: far more see-through, like the system ⌘Tab
    /// switcher's.
    case clearGlass = 3
    /// The pre-Liquid Glass blur (`NSVisualEffectView`).
    case blurred = 1
    /// A flat fill in the tint color.
    case solid = 2

    var title: String {
        switch self {
        case .glass: return "Glass"
        case .clearGlass: return "Clear glass"
        case .blurred: return "Blurred"
        case .solid: return "Solid"
        }
    }

    var isGlass: Bool { self == .glass || self == .clearGlass }
}

/// An sRGB color without alpha (opacity is a `Tint`'s own field), in a form
/// UserDefaults and `Settings.observe` can carry.
struct RGBColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = RGBColor(red: 0, green: 0, blue: 0)
    static let white = RGBColor(red: 1, green: 1, blue: 1)

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Any color the color panel hands over; alpha is dropped.
    init(_ color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { self = .black; return }
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    /// `other` laid over this color at `alpha` (0…1).
    func blended(with other: RGBColor, alpha: Double) -> RGBColor {
        RGBColor(red: red + (other.red - red) * alpha,
                 green: green + (other.green - green) * alpha,
                 blue: blue + (other.blue - blue) * alpha)
    }

    /// Equal but for rounding (a color's round trip through the color panel).
    func isClose(to other: RGBColor) -> Bool {
        max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue)) < 0.01
    }

    /// Perceived brightness, 0…1 (the YIQ luma of the gamma-encoded values).
    var brightness: Double { 0.299 * red + 0.587 * green + 0.114 * blue }
}

/// A color laid over a surface at an opacity. Glass and Blurred are tinted
/// with it; Solid is filled with it.
struct Tint: Codable, Equatable, Sendable {
    var color: RGBColor
    /// Percent, 0…100.
    var opacity: Int

    static let opacityRange: ClosedRange<Int> = 0...100

    var alpha: Double { Double(opacity.clamped(to: Self.opacityRange)) / 100 }

    /// Nil at 0%: an untinted glass, not one tinted with a clear color.
    var nsColor: NSColor? {
        alpha == 0 ? nil : color.nsColor.withAlphaComponent(alpha)
    }
}

/// A surface's style plus its tint for each of Light and Dark mode.
struct SurfaceAppearance: Codable, Equatable, Sendable {
    var style: SurfaceStyle
    var light: Tint
    var dark: Tint

    func tint(dark isDark: Bool) -> Tint { isDark ? dark : light }

    /// The look before styles were configurable: untinted glass in Dark mode,
    /// and gray-tinted glass in Light mode, where untinted glass over a white
    /// window is nearly white — like the system ⌘Tab switcher.
    static let defaultBackground = SurfaceAppearance(style: .clearGlass,
                                                     light: Tint(color: .black, opacity: 12),
                                                     dark: Tint(color: .black, opacity: 0))
    /// A pane of glass inside the panel's; darker than the panel in Light mode.
    static let defaultHighlight = SurfaceAppearance(style: .glass,
                                                    light: Tint(color: .black, opacity: 16),
                                                    dark: Tint(color: .black, opacity: 0))
}

/// Picks text that stays readable on whatever the user tinted things with.
enum TextContrast {
    /// Roughly what an untinted panel looks like in each mode.
    static let lightBase = RGBColor(red: 0.93, green: 0.93, blue: 0.93)
    static let darkBase = RGBColor(red: 0.17, green: 0.17, blue: 0.17)

    /// True when `tints`, laid over the mode's base in order, come out dark.
    static func isDark(_ tints: [Tint], darkMode: Bool) -> Bool {
        tints.reduce(darkMode ? darkBase : lightBase) { $0.blended(with: $1.color, alpha: $1.alpha) }
            .brightness < 0.5
    }

    /// The appearance text over `tints` should be drawn in: nil when the
    /// mode's own label colors already fit, otherwise the opposite one.
    @MainActor
    static func textAppearance(over tints: [Tint], darkMode: Bool) -> NSAppearance? {
        let dark = isDark(tints, darkMode: darkMode)
        if dark == darkMode { return nil }
        return NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

@MainActor
extension NSApplication {
    /// Light or Dark, as the user chose it (`AppearanceManager`). Read from
    /// the app, not a view: views may carry a text-contrast override.
    var isDarkMode: Bool { effectiveAppearance.isDark }
}
