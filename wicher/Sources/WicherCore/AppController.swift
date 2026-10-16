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
    private var accessibilityItem: NSMenuItem?
    private var trustTimer: Timer?
    private var isTrusted = AXIsProcessTrusted()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceManager.apply(Settings.shared.appearanceMode)
        setupMainMenu()
        setupStatusItem()
        SystemHotKeyOverride.shared.recoverAndInstallSignalHandlers()
        WindowEnumerator.shared.start()
        observeAppActivation()
        observeSettings()
        registerHotKeys()
        promptForAccessibilityIfNeeded()
        watchAccessibilityTrust()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Give ⌘Tab (or whatever a shortcut stood in for) back to the system.
        SystemHotKeyOverride.shared.restoreAll()
    }

    // MARK: - Main menu

    /// An agent app shows no menu bar, but `NSApp.mainMenu` still supplies key
    /// equivalents to its windows. Without one, ⌘W does not close Preferences
    /// and ⌘C/⌘V do nothing in its text fields.
    private func setupMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Wicher", action: #selector(quit), keyEquivalent: "q")
            .target = self
        main.addItem(submenuItem(appMenu))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenuItem(fileMenu))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenuItem(editMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenuItem(windowMenu))

        NSApp.mainMenu = main
    }

    private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
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
        let axItem = NSMenuItem(title: "Accessibility Access Needed…",
                                action: #selector(openAccessibilitySettings), keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)
        accessibilityItem = axItem
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
        updateTrustIndicator()
    }

    @objc private func showSwitcher() {
        if let first = Settings.shared.profiles.first {
            switcher.summon(profile: first, forward: true)
        }
    }

    @objc private func openPreferences() { preferences.show() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Settings

    private func observeSettings() {
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: Settings.shared,
                                               queue: .main) { [weak self] note in
            switch note.userInfo?[Settings.changeKey] as? Settings.Change {
            case .profiles: self?.registerHotKeys()
            case .appearance: AppearanceManager.apply(Settings.shared.appearanceMode)
            default: break
            }
        }
    }

    // MARK: - Hot keys (one forward + one reverse per profile)

    private func registerHotKeys() {
        hotKeyIDs.forEach { HotKeyCenter.shared.unregister($0) }
        hotKeyIDs.removeAll()

        // A shortcut the system owns (⌘Tab) only reaches us once the system's
        // own hot key is switched off; see `SystemHotKeys`.
        let profiles = Settings.shared.profiles
        SystemHotKeyOverride.shared.apply(for: profiles.flatMap { [$0.combo] + ($0.combo.reverse.map { [$0] } ?? []) })

        for profile in profiles {
            if let id = HotKeyCenter.shared.register(profile.combo, handler: { [weak self] pressed in
                self?.switcher.hotKey(profile: profile, forward: true, pressed: pressed)
            }) {
                hotKeyIDs.append(id)
            }
            // A combo that already holds Shift has no distinct reverse chord.
            guard let reverse = profile.combo.reverse else { continue }
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

    /// Trust is per code signature, and an ad-hoc signature changes on every
    /// rebuild, so it can vanish (or arrive) while wicher runs. Without it AX
    /// returns nothing and every row decays to a title-less CGWindowList
    /// stand-in — so watch for it, flag it, and recover without a relaunch.
    private func watchAccessibilityTrust() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            guard trusted != self.isTrusted else { return }
            self.isTrusted = trusted
            self.updateTrustIndicator()
            if trusted { WindowEnumerator.shared.accessibilityGranted() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    private func updateTrustIndicator() {
        accessibilityItem?.isHidden = isTrusted
        statusItem?.button?.image = NSImage(
            systemSymbolName: isTrusted ? "rectangle.on.rectangle" : "exclamationmark.triangle",
            accessibilityDescription: isTrusted ? "Wicher" : "Wicher — Accessibility access needed")
        statusItem?.button?.image?.isTemplate = true
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func promptForAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            let alert = NSAlert()
            alert.messageText = "Accessibility access needed"
            alert.informativeText = "Wicher needs Accessibility access to list and raise windows. "
                + "Enable Wicher under System Settings → Privacy & Security → Accessibility. "
                + "If it is already enabled, toggle it off and on again."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            alert.runModal()
        }
    }
}
