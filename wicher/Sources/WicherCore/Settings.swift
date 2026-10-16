import AppKit

/// Persistent, UserDefaults-backed settings. Deliberately tiny — no database.
/// Per-switcher filter options live on each `SwitcherProfile`; this holds the
/// global, cross-switcher preferences.
///
/// Every setter posts `Settings.didChange` (on the main thread, with the
/// changed `Settings.Change` under `changeKey`), so consumers react to edits
/// instead of each one having to be told. Profiles are decoded once and kept.
final class Settings {
    static let shared = Settings()

    static let didChange = Notification.Name("WicherSettingsDidChange")
    static let changeKey = "change"

    enum Change: String {
        case appearance, metrics, selection, showDelay, profiles, menuBarIcon
    }

    private let defaults: UserDefaults
    private var cachedProfiles: [SwitcherProfile]?

    private enum Key {
        static let appearance = "appearanceMode"
        static let iconSize = "iconSize"
        static let textSize = "textSize"
        static let rowPadding = "rowPadding"
        static let hoverSelects = "selectOnHover"
        static let scrollSelects = "selectOnScroll"
        static let showDelayMs = "showDelayMs"
        static let profiles = "profiles"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let highlightStyle = "highlightStyle"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.appearance: AppearanceMode.system.rawValue,
            Key.iconSize: 32,
            Key.textSize: 16,
            Key.rowPadding: 7,
            Key.hoverSelects: true,
            Key.scrollSelects: true,
            Key.showDelayMs: 180,
            Key.showMenuBarIcon: true,
            Key.highlightStyle: HighlightStyle.glass.rawValue,
        ])
    }

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.integer(forKey: Key.appearance)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance); post(.appearance) }
    }

    /// How the switcher draws the selected row. Read by each row when its
    /// selection changes, so a change shows the next time the panel opens.
    var highlightStyle: HighlightStyle {
        get { HighlightStyle(rawValue: defaults.integer(forKey: Key.highlightStyle)) ?? .glass }
        set { defaults.set(newValue.rawValue, forKey: Key.highlightStyle); post(.appearance) }
    }

    /// Icon size in points; panel width scales from it.
    var iconSize: Int {
        get { defaults.integer(forKey: Key.iconSize).clamped(to: HUDMetrics.iconRange) }
        set { defaults.set(newValue.clamped(to: HUDMetrics.iconRange), forKey: Key.iconSize); post(.metrics) }
    }

    /// Window-title text size in points.
    var textSize: Int {
        get { defaults.integer(forKey: Key.textSize).clamped(to: HUDMetrics.textRange) }
        set { defaults.set(newValue.clamped(to: HUDMetrics.textRange), forKey: Key.textSize); post(.metrics) }
    }

    /// Vertical padding above/below each row's content, in points.
    var rowPadding: Int {
        get { defaults.integer(forKey: Key.rowPadding).clamped(to: HUDMetrics.paddingRange) }
        set { defaults.set(newValue.clamped(to: HUDMetrics.paddingRange), forKey: Key.rowPadding); post(.metrics) }
    }

    var selectOnHover: Bool {
        get { defaults.bool(forKey: Key.hoverSelects) }
        set { defaults.set(newValue, forKey: Key.hoverSelects); post(.selection) }
    }

    var selectOnScroll: Bool {
        get { defaults.bool(forKey: Key.scrollSelects) }
        set { defaults.set(newValue, forKey: Key.scrollSelects); post(.selection) }
    }

    /// Delay before the panel is drawn. A quick tap+release within this window
    /// switches to the previous window without the panel ever appearing.
    var showDelayMs: Int {
        get { defaults.integer(forKey: Key.showDelayMs) }
        set { defaults.set(max(0, newValue), forKey: Key.showDelayMs); post(.showDelay) }
    }

    /// Hidden, wicher keeps running; opening the app again shows Settings.
    var showMenuBarIcon: Bool {
        get { defaults.bool(forKey: Key.showMenuBarIcon) }
        set { defaults.set(newValue, forKey: Key.showMenuBarIcon); post(.menuBarIcon) }
    }

    var profiles: [SwitcherProfile] {
        get {
            if let cachedProfiles { return cachedProfiles }
            let decoded = defaults.data(forKey: Key.profiles)
                .flatMap { try? JSONDecoder().decode([SwitcherProfile].self, from: $0) }
            let profiles = (decoded?.isEmpty == false) ? decoded! : SwitcherProfile.defaults()
            cachedProfiles = profiles
            return profiles
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.profiles)
            }
            cachedProfiles = newValue.isEmpty ? nil : newValue
            post(.profiles)
        }
    }

    private func post(_ change: Change) {
        let post = { NotificationCenter.default.post(name: Self.didChange, object: self,
                                                      userInfo: [Self.changeKey: change]) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}
