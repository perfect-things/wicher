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
    /// `shortcutNote`s by profile id. Worked out here, not in `body`: each one
    /// reads the system shortcut table (≈13 ms).
    @Published private(set) var shortcutNotes: [UUID: String] = [:]
    /// `SMAppService.mainApp.status`, cached: it is an XPC round trip (≈1.4 ms,
    /// 8 ms cold), and the toggle reads it on every render. See `refreshLoginItem()`.
    @Published private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    /// Why the last (un)registration failed, until the next attempt.
    @Published private(set) var loginItemError: String?

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Settings.didChange, object: Settings.shared,
                                            queue: .main) { [weak self] note in
            if note.userInfo?[Settings.changeKey] as? Settings.Change == .profiles {
                self?.refreshShortcutNotes()
            }
            self?.objectWillChange.send()
        })
        // Approval happens in System Settings; pick it up when the user comes back.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            self?.refreshLoginItem()
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func binding<T>(_ keyPath: ReferenceWritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { Settings.shared[keyPath: keyPath] },
                set: { Settings.shared[keyPath: keyPath] = $0 })
    }

    /// Login-item state lives in ServiceManagement, not UserDefaults. Waiting
    /// for approval counts as on — `register()` succeeded — and `loginItemHint`
    /// says what is left to do; a failure snaps the switch back and says why.
    var launchAtLogin: Binding<Bool> {
        Binding(get: { [weak self] in
                    self.map { $0.loginItemStatus == .enabled || $0.loginItemStatus == .requiresApproval } ?? false
                },
                set: { [weak self] on in
                    guard let self else { return }
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginItemError = nil
                    } catch {
                        loginItemError = error.localizedDescription
                    }
                    refreshLoginItem()
                })
    }

    var loginItemNeedsApproval: Bool { loginItemStatus == .requiresApproval }

    var loginItemHint: String? {
        if let loginItemError { return "⚠︎ macOS refused the change: \(loginItemError)" }
        if loginItemNeedsApproval { return "Allow Wicher in System Settings → General → Login Items to finish turning this on." }
        return nil
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        if status != loginItemStatus { loginItemStatus = status }
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

    /// Recomputes `shortcutNotes`. Call when what they depend on changes
    /// outside `Settings`: recording starts or stops (the system shortcuts are
    /// paused meanwhile), Accessibility trust changes, the window opens.
    func refreshShortcutNotes() {
        let profiles = Settings.shared.profiles
        let trusted = AXIsProcessTrusted()
        let overridden = SystemHotKeyOverride.shared.overriddenShortcuts(for: profiles.map(\.combo))
        var notes: [UUID: String] = [:]
        for (profile, name) in zip(profiles, overridden) {
            notes[profile.id] = Self.shortcutNote(for: profile.combo, overriding: name, trusted: trusted)
        }
        if notes != shortcutNotes { shortcutNotes = notes }
    }

    /// What a shortcut stands in for, its reverse, and how it commits.
    private static func shortcutNote(for combo: HotKeyCombo, overriding overridden: String?, trusted: Bool) -> String {
        var notes: [String] = []
        if !trusted {
            notes.append("⚠︎ Accessibility access is off, so macOS shortcuts such as ⌘Tab cannot be replaced. Turn Wicher on in System Settings → Privacy & Security → Accessibility.")
        }
        if let name = overridden {
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
