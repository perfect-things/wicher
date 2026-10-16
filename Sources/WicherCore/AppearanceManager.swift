import AppKit

/// Light / Dark / System appearance choice.
enum AppearanceMode: Int, CaseIterable {
    case system = 0
    case light = 1
    case dark = 2

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// How the selected row in the switcher is drawn.
enum HighlightStyle: Int, CaseIterable {
    /// Solid system accent color, white text.
    case accent = 0
    /// A translucent neutral fill, like a sidebar selection.
    case neutral = 1
    /// A pane of Liquid Glass inside the panel's glass (macOS 26+).
    case glass = 2
    /// Clear Liquid Glass — more see-through, stronger edge (macOS 26+).
    case clearGlass = 3
    /// Liquid Glass tinted with the accent color (macOS 26+).
    case tintedGlass = 4

    var title: String {
        switch self {
        case .accent: return "Accent color"
        case .neutral: return "Neutral"
        case .glass: return "Glass"
        case .clearGlass: return "Clear glass"
        case .tintedGlass: return "Tinted glass"
        }
    }

    /// The glass styles need `NSGlassEffectView`; earlier systems get the
    /// neutral fill instead.
    var isGlass: Bool { self == .glass || self == .clearGlass || self == .tintedGlass }
}

/// Applies the user's Light / Dark / System choice to the whole app.
///
/// This is wicher's headline improvement over Contexts, whose settings window
/// (observed) offers no appearance control. Setting `NSApp.appearance` cascades
/// to every window — the switcher HUD and the Settings window alike.
enum AppearanceManager {
    static func apply(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil // follow the system setting
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
