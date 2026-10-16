import AppKit
import ServiceManagement
import SwiftUI

/// The Settings window's sidebar entries.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, switchers, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .switchers: return "Switchers"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .switchers: return "rectangle.stack"
        case .about: return "info.circle"
        }
    }
}

/// Bridges `Settings` to the SwiftUI panes. Holds no copies: bindings read and
/// write `Settings.shared` directly, and every `Settings.didChange` re-renders,
/// so the window never drifts from what the rest of the app sees.
final class SettingsModel: ObservableObject {
    @Published var pane: SettingsPane = .general

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: Settings.didChange, object: Settings.shared,
                                                          queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func binding<T>(_ keyPath: ReferenceWritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { Settings.shared[keyPath: keyPath] },
                set: { Settings.shared[keyPath: keyPath] = $0 })
    }

    /// Login-item state lives in ServiceManagement, not UserDefaults; a failed
    /// (un)registration snaps the switch back to the real state.
    var launchAtLogin: Binding<Bool> {
        Binding(get: { SMAppService.mainApp.status == .enabled },
                set: { [weak self] on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSSound.beep()
                    }
                    self?.objectWillChange.send()
                })
    }

    // MARK: - Switchers

    var profiles: [SwitcherProfile] { Settings.shared.profiles }

    /// `fallback` is what the row was built from; it is served if the profile
    /// is removed while SwiftUI still holds the binding.
    func profile(_ fallback: SwitcherProfile) -> Binding<SwitcherProfile> {
        Binding(get: { Settings.shared.profiles.first { $0.id == fallback.id } ?? fallback },
                set: { new in
                    var all = Settings.shared.profiles
                    guard let i = all.firstIndex(where: { $0.id == new.id }), all[i] != new else { return }
                    all[i] = new
                    Settings.shared.profiles = all   // AppController re-registers hot keys
                })
    }

    func addProfile() {
        let all = Settings.shared.profiles
        Settings.shared.profiles = all + [
            SwitcherProfile(id: UUID(), name: "Switcher \(all.count + 1)",
                            keyCode: HotKeyCombo.defaultCombo.keyCode,
                            carbonModifiers: HotKeyCombo.defaultCombo.carbonModifiers,
                            scope: .activeApp, spaces: .allSpaces,
                            minimized: .showAtBottom, hidden: .hide, appsWithoutWindows: .hide),
        ]
    }

    func removeProfile(_ id: UUID) {
        let all = Settings.shared.profiles
        guard all.count > 1 else { NSSound.beep(); return }
        Settings.shared.profiles = all.filter { $0.id != id }
    }

    /// Why `combo` cannot be profile `id`'s shortcut, or nil to accept it.
    func problem(with combo: HotKeyCombo, for id: UUID) -> String? {
        combo.problem(amongOthers: Settings.shared.profiles.filter { $0.id != id }.map(\.combo))
    }

    /// What a shortcut stands in for, its reverse, and how it commits.
    func shortcutNote(for combo: HotKeyCombo) -> String {
        var notes: [String] = []
        if !AXIsProcessTrusted() {
            notes.append("⚠︎ Accessibility access is off, so macOS shortcuts such as ⌘Tab cannot be replaced. Turn Wicher on in System Settings → Privacy & Security → Accessibility.")
        }
        if let name = SystemHotKeyOverride.shared.overriddenShortcut(for: combo) {
            notes.append("Replaces \(name) while Wicher is running.")
        }
        if let reverse = combo.reverse {
            notes.append("\(reverse.displayString) cycles backwards.")
        } else {
            notes.append("Includes ⇧, so there is no reverse shortcut — use ↑ in the panel.")
        }
        if combo.eventModifierFlags.isEmpty {
            notes.append("No modifier to release: press ↩ or click to switch.")
        }
        return notes.joined(separator: " ")
    }

    // MARK: - About

    var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }
}
