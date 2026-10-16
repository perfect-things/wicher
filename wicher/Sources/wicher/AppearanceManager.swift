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

/// Applies the user's Light / Dark / System choice to the whole app.
///
/// This is wicher's headline improvement over Contexts, whose settings window
/// (observed) offers no appearance control. Setting `NSApp.appearance` cascades
/// to every window — the switcher HUD and the Preferences window alike.
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
