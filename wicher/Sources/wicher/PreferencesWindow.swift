import AppKit
import ServiceManagement

/// Flipped stack so cards lay out top-to-bottom inside a scroll view.
private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// Settings window — General, Appearance, and Switchers. An ordinary titled
/// window, so it respects `NSApp.appearance` (the Light/Dark/System support
/// Contexts' settings window lacks).
final class PreferencesWindow: NSObject, ProfileCardDelegate {
    /// Called when profiles (or their shortcuts) change, so hot keys re-register.
    var onProfilesChanged: (() -> Void)?

    private var window: NSWindow?
    private var profiles: [SwitcherProfile] = []
    private let cardsStack = FlippedStack()

    private lazy var delayLabel = NSTextField(labelWithString: "")
    private lazy var iconLabel = NSTextField(labelWithString: "")
    private lazy var textLabel = NSTextField(labelWithString: "")
    private lazy var paddingLabel = NSTextField(labelWithString: "")

    func show() {
        if window == nil { build() }
        profiles = Settings.shared.profiles
        rebuildCards()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered,
                           defer: false)
        win.title = "Wicher Preferences"
        win.isReleasedWhenClosed = false

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(tab("General", buildGeneralTab()))
        tabView.addTabViewItem(tab("Appearance", buildAppearanceTab()))
        tabView.addTabViewItem(tab("Switchers", buildSwitchersTab()))

        let content = NSView()
        content.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        win.contentView = content
        window = win
    }

    // MARK: - General (ordered top→bottom: login, hover, scroll, delay, hint)

    private func buildGeneralTab() -> NSView {
        let stack = verticalStack()

        stack.addArrangedSubview(checkbox("Launch at login",
                                          on: SMAppService.mainApp.status == .enabled,
                                          action: #selector(toggleLaunchAtLogin(_:))))
        stack.addArrangedSubview(checkbox("Change selection on mouse hover",
                                          on: Settings.shared.selectOnHover,
                                          action: #selector(toggleHover(_:))))
        stack.addArrangedSubview(checkbox("Change selection on scroll",
                                          on: Settings.shared.selectOnScroll,
                                          action: #selector(toggleScroll(_:))))

        let slider = NSSlider(value: Double(Settings.shared.showDelayMs),
                              minValue: 0, maxValue: 400,
                              target: self, action: #selector(delayChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        delayLabel.stringValue = "\(Settings.shared.showDelayMs) ms"
        let row = NSStackView(views: [slider, delayLabel])
        row.spacing = 10
        stack.addArrangedSubview(labeledRow("Show panel after:", row))

        stack.addArrangedSubview(wrappingNote("A quick tap-and-release within the delay switches to the previous window without showing the panel — like macOS Command-Tab."))
        return wrap(stack)
    }

    @objc private func delayChanged(_ sender: NSSlider) {
        Settings.shared.showDelayMs = Int(sender.doubleValue.rounded())
        delayLabel.stringValue = "\(Settings.shared.showDelayMs) ms"
    }
    @objc private func toggleHover(_ sender: NSButton) { Settings.shared.selectOnHover = sender.state == .on }
    @objc private func toggleScroll(_ sender: NSButton) { Settings.shared.selectOnScroll = sender.state == .on }
    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            NSSound.beep()
        }
    }

    // MARK: - Appearance (theme + two size sliders)

    private func buildAppearanceTab() -> NSView {
        let stack = verticalStack()

        let themes: [AppearanceMode] = [.light, .dark, .system]
        let themeSeg = NSSegmentedControl(labels: themes.map { $0.title },
                                          trackingMode: .selectOne,
                                          target: self, action: #selector(themeChanged(_:)))
        themeSeg.segmentDistribution = .fillEqually
        themeSeg.selectedSegment = themes.firstIndex(of: Settings.shared.appearanceMode) ?? 2
        stack.addArrangedSubview(labeledRow("Theme:", themeSeg))

        let iconSlider = NSSlider(value: Double(Settings.shared.iconSize),
                                  minValue: Double(HUDMetrics.iconRange.lowerBound),
                                  maxValue: Double(HUDMetrics.iconRange.upperBound),
                                  target: self, action: #selector(iconChanged(_:)))
        iconSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        iconLabel.stringValue = "\(Settings.shared.iconSize) pt"
        let iconRow = NSStackView(views: [iconSlider, iconLabel])
        iconRow.spacing = 10
        stack.addArrangedSubview(labeledRow("Icon size:", iconRow))

        let textSlider = NSSlider(value: Double(Settings.shared.textSize),
                                  minValue: Double(HUDMetrics.textRange.lowerBound),
                                  maxValue: Double(HUDMetrics.textRange.upperBound),
                                  target: self, action: #selector(textChanged(_:)))
        textSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        textLabel.stringValue = "\(Settings.shared.textSize) pt"
        let textRow = NSStackView(views: [textSlider, textLabel])
        textRow.spacing = 10
        stack.addArrangedSubview(labeledRow("Text size:", textRow))

        let padSlider = NSSlider(value: Double(Settings.shared.rowPadding),
                                 minValue: Double(HUDMetrics.paddingRange.lowerBound),
                                 maxValue: Double(HUDMetrics.paddingRange.upperBound),
                                 target: self, action: #selector(paddingChanged(_:)))
        padSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        paddingLabel.stringValue = "\(Settings.shared.rowPadding) pt"
        let padRow = NSStackView(views: [padSlider, paddingLabel])
        padRow.spacing = 10
        stack.addArrangedSubview(labeledRow("Row padding:", padRow))

        stack.addArrangedSubview(wrappingNote("“System” follows macOS Appearance. Size changes apply the next time the switcher opens."))
        return wrap(stack)
    }

    @objc private func themeChanged(_ sender: NSSegmentedControl) {
        let themes: [AppearanceMode] = [.light, .dark, .system]
        guard themes.indices.contains(sender.selectedSegment) else { return }
        Settings.shared.appearanceMode = themes[sender.selectedSegment]
        AppearanceManager.apply(themes[sender.selectedSegment])
    }
    @objc private func iconChanged(_ sender: NSSlider) {
        Settings.shared.iconSize = Int(sender.doubleValue.rounded())
        iconLabel.stringValue = "\(Settings.shared.iconSize) pt"
    }
    @objc private func textChanged(_ sender: NSSlider) {
        Settings.shared.textSize = Int(sender.doubleValue.rounded())
        textLabel.stringValue = "\(Settings.shared.textSize) pt"
    }
    @objc private func paddingChanged(_ sender: NSSlider) {
        Settings.shared.rowPadding = Int(sender.doubleValue.rounded())
        paddingLabel.stringValue = "\(Settings.shared.rowPadding) pt"
    }

    // MARK: - Switchers (cards)

    private func buildSwitchersTab() -> NSView {
        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 14
        cardsStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = cardsStack

        let container = NSView()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            cardsStack.topAnchor.constraint(equalTo: scroll.topAnchor),
            cardsStack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        return container
    }

    private func rebuildCards() {
        cardsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, profile) in profiles.enumerated() {
            let card = ProfileCardView(profile: profile, isRemovable: index > 0, delegate: self)
            card.translatesAutoresizingMaskIntoConstraints = false
            cardsStack.addArrangedSubview(card)
            card.leadingAnchor.constraint(equalTo: cardsStack.leadingAnchor, constant: cardsStack.edgeInsets.left).isActive = true
            card.widthAnchor.constraint(equalToConstant: 500).isActive = true
        }
        let add = NSButton(title: "＋  Add Switcher", target: self, action: #selector(addProfile))
        add.bezelStyle = .rounded
        add.translatesAutoresizingMaskIntoConstraints = false
        cardsStack.addArrangedSubview(add)
    }

    @objc private func addProfile() {
        let p = SwitcherProfile(id: UUID(), name: "Switcher \(profiles.count + 1)",
                                keyCode: HotKeyCombo.defaultCombo.keyCode,
                                carbonModifiers: HotKeyCombo.defaultCombo.carbonModifiers,
                                scope: .activeApp, spaces: .allSpaces,
                                minimized: .showAtBottom, hidden: .hide, appsWithoutWindows: .hide)
        profiles.append(p)
        saveProfiles()
        rebuildCards()
    }

    private func saveProfiles() {
        Settings.shared.profiles = profiles
        onProfilesChanged?()
    }

    private func mutate(_ id: UUID, _ change: (inout SwitcherProfile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&profiles[i])
        saveProfiles()
    }

    // MARK: - ProfileCardDelegate

    func card(_ id: UUID, didSetShortcut combo: HotKeyCombo) { mutate(id) { $0.combo = combo } }
    func card(_ id: UUID, didSetScope scope: WindowScope) { mutate(id) { $0.scope = scope } }
    func card(_ id: UUID, didSetSpaces spaces: SpaceScope) { mutate(id) { $0.spaces = spaces } }
    func card(_ id: UUID, didSetMinimized placement: Placement) { mutate(id) { $0.minimized = placement } }
    func card(_ id: UUID, didSetHidden placement: Placement) { mutate(id) { $0.hidden = placement } }
    func card(_ id: UUID, didSetApps placement: Placement) { mutate(id) { $0.appsWithoutWindows = placement } }

    func cardDidRequestRemove(_ id: UUID) {
        guard profiles.count > 1 else { NSSound.beep(); return }
        profiles.removeAll { $0.id == id }
        saveProfiles()
        rebuildCards()
    }

    // MARK: - Layout helpers

    private func tab(_ label: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    private func verticalStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func wrap(_ stack: NSStackView) -> NSView {
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])
        return container
    }

    private func labeledRow(_ label: String, _ control: NSView) -> NSView {
        let field = NSTextField(labelWithString: label)
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let r = NSStackView(views: [field, control])
        r.orientation = .horizontal
        r.spacing = 10
        r.alignment = .centerY
        return r
    }

    private func checkbox(_ title: String, on: Bool, action: Selector) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: action)
        box.state = on ? .on : .off
        return box
    }

    private func wrappingNote(_ text: String) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.widthAnchor.constraint(equalToConstant: 480).isActive = true
        return note
    }
}
