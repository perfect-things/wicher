import AppKit

/// Persistent, UserDefaults-backed settings. Deliberately tiny — no database.
/// Per-switcher filter options live on each `SwitcherProfile`; this holds the
/// global, cross-switcher preferences.
///
/// `@Observable`, so SwiftUI binds straight to it and redraws only what reads
/// a changed property. Every value is loaded from `defaults` once, in `init`,
/// and each `didSet` clamps, persists and posts `Settings.didChange` (on the
/// main thread, with the changed `Settings.Change` under `changeKey`) — but
/// only when the value really changed. A `defaults write` while wicher runs
/// is therefore not picked up.
@Observable
final class Settings {
    static let shared = Settings()

    static let didChange = Notification.Name("WicherSettingsDidChange")
    static let changeKey = "change"

    enum Change: String {
        case appearance, metrics, selection, showDelay, profiles, menuBarIcon
    }

    @ObservationIgnored private let defaults: UserDefaults

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
        static let showAppNames = "showAppNames"
        static let panelWidthScale = "panelWidthScale"
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
            Key.showAppNames: true,
            Key.panelWidthScale: 100,
        ])
        appearanceMode = AppearanceMode(rawValue: defaults.integer(forKey: Key.appearance)) ?? .system
        highlightStyle = HighlightStyle(rawValue: defaults.integer(forKey: Key.highlightStyle)) ?? .glass
        iconSize = defaults.integer(forKey: Key.iconSize).clamped(to: HUDMetrics.iconRange)
        textSize = defaults.integer(forKey: Key.textSize).clamped(to: HUDMetrics.textRange)
        panelWidthScale = defaults.integer(forKey: Key.panelWidthScale).clamped(to: HUDMetrics.widthScaleRange)
        showAppNames = defaults.bool(forKey: Key.showAppNames)
        rowPadding = defaults.integer(forKey: Key.rowPadding).clamped(to: HUDMetrics.paddingRange)
        selectOnHover = defaults.bool(forKey: Key.hoverSelects)
        selectOnScroll = defaults.bool(forKey: Key.scrollSelects)
        showDelayMs = max(0, defaults.integer(forKey: Key.showDelayMs))
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)

        let decoded = defaults.data(forKey: Key.profiles)
            .flatMap { try? JSONDecoder().decode([SwitcherProfile].self, from: $0) }
        if let decoded, !decoded.isEmpty {
            profiles = decoded
        } else {
            // Persisted (`didSet` doesn't run in `init`), so the generated
            // defaults keep their UUIDs across launches.
            profiles = SwitcherProfile.defaults()
            persist(profiles: profiles)
        }
    }

    var appearanceMode: AppearanceMode {
        didSet { store(appearanceMode.rawValue, oldValue.rawValue, Key.appearance, .appearance) }
    }

    /// How the switcher draws the selected row. Read by each row when its
    /// selection changes, so a change shows the next time the panel opens.
    var highlightStyle: HighlightStyle {
        didSet { store(highlightStyle.rawValue, oldValue.rawValue, Key.highlightStyle, .appearance) }
    }

    /// Icon size in points; panel width scales from it.
    var iconSize: Int {
        didSet {
            let clamped = iconSize.clamped(to: HUDMetrics.iconRange)
            if clamped != iconSize { iconSize = clamped; return }
            store(iconSize, oldValue, Key.iconSize, .metrics)
        }
    }

    /// Window-title text size in points.
    var textSize: Int {
        didSet {
            let clamped = textSize.clamped(to: HUDMetrics.textRange)
            if clamped != textSize { textSize = clamped; return }
            store(textSize, oldValue, Key.textSize, .metrics)
        }
    }

    /// Percent of the icon-derived panel width (see `HUDMetrics.make`).
    var panelWidthScale: Int {
        didSet {
            let clamped = panelWidthScale.clamped(to: HUDMetrics.widthScaleRange)
            if clamped != panelWidthScale { panelWidthScale = clamped; return }
            store(panelWidthScale, oldValue, Key.panelWidthScale, .metrics)
        }
    }

    /// The app-name column left of each row's icon. Off, rows are just
    /// icon + title. Part of `HUDMetrics`, so it applies on the next open.
    var showAppNames: Bool {
        didSet { store(showAppNames, oldValue, Key.showAppNames, .metrics) }
    }

    /// Vertical padding above/below each row's content, in points.
    var rowPadding: Int {
        didSet {
            let clamped = rowPadding.clamped(to: HUDMetrics.paddingRange)
            if clamped != rowPadding { rowPadding = clamped; return }
            store(rowPadding, oldValue, Key.rowPadding, .metrics)
        }
    }

    var selectOnHover: Bool {
        didSet { store(selectOnHover, oldValue, Key.hoverSelects, .selection) }
    }

    var selectOnScroll: Bool {
        didSet { store(selectOnScroll, oldValue, Key.scrollSelects, .selection) }
    }

    /// Delay before the panel is drawn. A quick tap+release within this window
    /// switches to the previous window without the panel ever appearing.
    var showDelayMs: Int {
        didSet {
            if showDelayMs < 0 { showDelayMs = 0; return }
            store(showDelayMs, oldValue, Key.showDelayMs, .showDelay)
        }
    }

    /// Hidden, wicher keeps running; opening the app again shows Settings.
    var showMenuBarIcon: Bool {
        didSet { store(showMenuBarIcon, oldValue, Key.showMenuBarIcon, .menuBarIcon) }
    }

    /// Never empty: setting `[]` puts the default switchers back.
    var profiles: [SwitcherProfile] {
        didSet {
            if profiles.isEmpty { profiles = SwitcherProfile.defaults(); return }
            guard profiles != oldValue else { return }
            persist(profiles: profiles)
            post(.profiles)
        }
    }

    /// One profile by id, for a binding that survives the profile's removal:
    /// a removed id reads as a default profile and ignores writes. Equal
    /// writes are skipped by `profiles`' `didSet`.
    subscript(profileID id: UUID) -> SwitcherProfile {
        get { profiles.first { $0.id == id } ?? SwitcherProfile.defaults()[0] }
        set {
            guard let i = profiles.firstIndex(where: { $0.id == id }), profiles[i] != newValue else { return }
            profiles[i] = newValue
        }
    }

    private func store<T: Equatable>(_ value: T, _ oldValue: T, _ key: String, _ change: Change) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
        post(change)
    }

    private func persist(profiles: [SwitcherProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Key.profiles)
        }
    }

    private func post(_ change: Change) {
        let post = { NotificationCenter.default.post(name: Self.didChange, object: self,
                                                      userInfo: [Self.changeKey: change]) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}
