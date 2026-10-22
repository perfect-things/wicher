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

/// What the Settings window needs beyond `Settings` itself, which the panes
/// bind to directly: the selected pane, login-item state, shortcut notes.
@Observable @MainActor
final class SettingsModel {
    var pane: SettingsPane = .general {
        didSet { onPaneChange?(pane) }
    }
    /// Called synchronously on every pane change; `SettingsWindow` retitles itself.
    @ObservationIgnored var onPaneChange: ((SettingsPane) -> Void)?
    /// `shortcutNote`s by profile id. Worked out here, not in `body`: each one
    /// reads the system shortcut table (≈13 ms).
    private(set) var shortcutNotes: [UUID: String] = [:]
    /// `SMAppService.mainApp.status`, cached: it is an XPC round trip (≈1.4 ms,
    /// 8 ms cold), and the toggle reads it on every render. See `refreshLoginItem()`.
    private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    /// Why the last (un)registration failed, until the next attempt.
    private(set) var loginItemError: String?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        Settings.observe({ Settings.shared.profiles.map(\.combo) }) { [weak self] _ in
            self?.refreshShortcutNotes()
        }
        let center = NotificationCenter.default
        // Approval happens in System Settings; pick it up when the user comes back.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLoginItem() }
        })
    }

    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

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

    func addProfile() {
        let all = Settings.shared.profiles
        Settings.shared.profiles = all + [
            SwitcherProfile(id: UUID(), name: "Switcher \(all.count + 1)",
                            keyCode: HotKeyCombo.defaultCombo.keyCode,
                            carbonModifiers: HotKeyCombo.defaultCombo.carbonModifiers,
                            scope: .activeApp, otherDisplays: .show, otherSpaces: .show,
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
    /// outside `Settings`: Accessibility trust changes, the window opens.
    func refreshShortcutNotes() {
        let profiles = Settings.shared.profiles
        let trusted = AXIsProcessTrusted()
        var notes: [UUID: String] = [:]
        for profile in profiles {
            notes[profile.id] = Self.shortcutNote(for: profile.combo, trusted: trusted)
        }
        if notes != shortcutNotes { shortcutNotes = notes }
    }

    /// A shortcut's reverse, and how it commits.
    private static func shortcutNote(for combo: HotKeyCombo, trusted: Bool) -> String {
        var notes: [String] = []
        if !trusted {
            notes.append("⚠︎ Accessibility access is off, so macOS shortcuts such as ⌘Tab cannot be replaced. Turn Wicher on in System Settings → Privacy & Security → Accessibility.")
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
