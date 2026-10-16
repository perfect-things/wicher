import AppKit

/// Persistent, UserDefaults-backed settings. Deliberately tiny — no database.
/// Per-switcher filter options live on each `SwitcherProfile`; this holds the
/// global, cross-switcher preferences.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let appearance = "appearanceMode"
        static let iconSize = "iconSize"
        static let textSize = "textSize"
        static let rowPadding = "rowPadding"
        static let hoverSelects = "selectOnHover"
        static let scrollSelects = "selectOnScroll"
        static let showDelayMs = "showDelayMs"
        static let profiles = "profiles"
    }

    private init() {
        defaults.register(defaults: [
            Key.appearance: AppearanceMode.system.rawValue,
            Key.iconSize: 32,
            Key.textSize: 16,
            Key.rowPadding: 7,
            Key.hoverSelects: true,
            Key.scrollSelects: true,
            Key.showDelayMs: 180,
        ])
    }

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.integer(forKey: Key.appearance)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

    /// Icon size in points; panel width scales from it.
    var iconSize: Int {
        get { defaults.integer(forKey: Key.iconSize).clamped(to: HUDMetrics.iconRange) }
        set { defaults.set(newValue.clamped(to: HUDMetrics.iconRange), forKey: Key.iconSize) }
    }

    /// Window-title text size in points.
    var textSize: Int {
        get { defaults.integer(forKey: Key.textSize).clamped(to: HUDMetrics.textRange) }
        set { defaults.set(newValue.clamped(to: HUDMetrics.textRange), forKey: Key.textSize) }
    }

    /// Vertical padding above/below each row's content, in points.
    var rowPadding: Int {
        get { defaults.integer(forKey: Key.rowPadding).clamped(to: HUDMetrics.paddingRange) }
        set { defaults.set(newValue.clamped(to: HUDMetrics.paddingRange), forKey: Key.rowPadding) }
    }

    var selectOnHover: Bool {
        get { defaults.bool(forKey: Key.hoverSelects) }
        set { defaults.set(newValue, forKey: Key.hoverSelects) }
    }

    var selectOnScroll: Bool {
        get { defaults.bool(forKey: Key.scrollSelects) }
        set { defaults.set(newValue, forKey: Key.scrollSelects) }
    }

    /// Delay before the panel is drawn. A quick tap+release within this window
    /// switches to the previous window without the panel ever appearing.
    var showDelayMs: Int {
        get { defaults.integer(forKey: Key.showDelayMs) }
        set { defaults.set(max(0, newValue), forKey: Key.showDelayMs) }
    }

    var profiles: [SwitcherProfile] {
        get {
            guard let data = defaults.data(forKey: Key.profiles),
                  let decoded = try? JSONDecoder().decode([SwitcherProfile].self, from: data),
                  !decoded.isEmpty
            else { return SwitcherProfile.defaults() }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.profiles)
            }
        }
    }
}
