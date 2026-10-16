import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Owns the menu-bar item and wires together the hot keys, the switcher, the
/// appearance choice, and the Preferences window.
final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let switcher = SwitcherController()
    private let preferences = PreferencesWindow()
    private var hotKeyIDs: [UInt32] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceManager.apply(Settings.shared.appearanceMode)
        setupStatusItem()
        WindowEnumerator.shared.seedMRU()
        observeAppActivation()
        preferences.onProfilesChanged = { [weak self] in self?.registerHotKeys() }
        registerHotKeys()
        promptForAccessibilityIfNeeded()
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                   accessibilityDescription: "Wicher")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Show", action: #selector(showSwitcher), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Wicher", action: #selector(quit), keyEquivalent: "q")
            .target = self

        item.menu = menu
        statusItem = item
    }

    @objc private func showSwitcher() {
        if let first = Settings.shared.profiles.first {
            switcher.summon(profile: first, forward: true)
        }
    }

    @objc private func openPreferences() { preferences.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Hot keys (one forward + one reverse per profile)

    private func registerHotKeys() {
        hotKeyIDs.forEach { HotKeyCenter.shared.unregister($0) }
        hotKeyIDs.removeAll()

        for profile in Settings.shared.profiles {
            if let id = HotKeyCenter.shared.register(profile.combo, handler: { [weak self] pressed in
                self?.switcher.hotKey(profile: profile, forward: true, pressed: pressed)
            }) {
                hotKeyIDs.append(id)
            }
            let reverse = HotKeyCombo(keyCode: profile.combo.keyCode,
                                      carbonModifiers: profile.combo.carbonModifiers | UInt32(shiftKey))
            if let id = HotKeyCenter.shared.register(reverse, handler: { [weak self] pressed in
                self?.switcher.hotKey(profile: profile, forward: false, pressed: pressed)
            }) {
                hotKeyIDs.append(id)
            }
        }
    }

    // MARK: - App activation tracking (MRU)

    private func observeAppActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil)
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        WindowEnumerator.shared.noteActivated(pid: app.processIdentifier)
    }

    // MARK: - Accessibility permission

    private func promptForAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            let alert = NSAlert()
            alert.messageText = "Accessibility access needed"
            alert.informativeText = "Wicher needs Accessibility access to list and raise windows. "
                + "Enable Wicher under System Settings → Privacy & Security → Accessibility, then relaunch."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
