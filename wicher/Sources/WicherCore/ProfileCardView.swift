import AppKit
import Carbon.HIToolbox

protocol ProfileCardDelegate: AnyObject {
    /// Why `combo` cannot be this card's shortcut, or nil to accept it.
    func card(_ id: UUID, problemWithShortcut combo: HotKeyCombo) -> String?
    func card(_ id: UUID, didSetShortcut combo: HotKeyCombo)
    func card(_ id: UUID, didSetScope scope: WindowScope)
    func card(_ id: UUID, didSetSpaces spaces: SpaceScope)
    func card(_ id: UUID, didSetMinimized placement: Placement)
    func card(_ id: UUID, didSetHidden placement: Placement)
    func card(_ id: UUID, didSetApps placement: Placement)
    func cardDidRequestRemove(_ id: UUID)
}

/// One switcher's settings as a self-contained, layer-backed card: a shortcut
/// recorder followed by the scope / Spaces / placement controls, and a Remove
/// button on every card except the first. The card's height follows its pinned
/// content stack (an NSBox did not size to its content under Auto Layout).
final class ProfileCardView: NSView {
    let profileID: UUID
    weak var delegate: ProfileCardDelegate?

    private let shortcutButton = NSButton(title: "", target: nil, action: nil)
    private var recordingMonitor: Any?
    private var currentCombo: HotKeyCombo

    init(profile: SwitcherProfile, isRemovable: Bool, delegate: ProfileCardDelegate) {
        self.profileID = profile.id
        self.delegate = delegate
        self.currentCombo = profile.combo
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        applyLayerColors()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])

        shortcutButton.title = currentCombo.displayString
        shortcutButton.bezelStyle = .rounded
        shortcutButton.target = self
        shortcutButton.action = #selector(startRecording)
        stack.addArrangedSubview(row("Shortcut:", shortcutButton))

        stack.addArrangedSubview(row("Show windows of:",
            seg(WindowScope.allCases.map { $0.title }, profile.scope.rawValue, #selector(scopeChanged(_:)))))
        stack.addArrangedSubview(row("Show windows from:",
            seg(SpaceScope.allCases.map { $0.title }, profile.spaces.rawValue, #selector(spacesChanged(_:)))))
        stack.addArrangedSubview(row("Minimized windows:",
            seg(Placement.allCases.map { $0.title }, profile.minimized.rawValue, #selector(minimizedChanged(_:)))))
        stack.addArrangedSubview(row("Hidden windows:",
            seg(Placement.allCases.map { $0.title }, profile.hidden.rawValue, #selector(hiddenChanged(_:)))))
        stack.addArrangedSubview(row("Apps without windows:",
            seg(Placement.allCases.map { $0.title }, profile.appsWithoutWindows.rawValue, #selector(appsChanged(_:)))))

        if isRemovable {
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeTapped))
            remove.bezelStyle = .rounded
            stack.addArrangedSubview(remove)
        }
    }

    required init?(coder: NSCoder) { preconditionFailure("not used") }

    override func updateLayer() { applyLayerColors() }

    private func applyLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    // MARK: - Actions

    @objc private func scopeChanged(_ s: NSSegmentedControl) {
        delegate?.card(profileID, didSetScope: WindowScope(rawValue: s.selectedSegment) ?? .allApps)
    }
    @objc private func spacesChanged(_ s: NSSegmentedControl) {
        delegate?.card(profileID, didSetSpaces: SpaceScope(rawValue: s.selectedSegment) ?? .allSpaces)
    }
    @objc private func minimizedChanged(_ s: NSSegmentedControl) {
        delegate?.card(profileID, didSetMinimized: Placement(rawValue: s.selectedSegment) ?? .showAtBottom)
    }
    @objc private func hiddenChanged(_ s: NSSegmentedControl) {
        delegate?.card(profileID, didSetHidden: Placement(rawValue: s.selectedSegment) ?? .showAtBottom)
    }
    @objc private func appsChanged(_ s: NSSegmentedControl) {
        delegate?.card(profileID, didSetApps: Placement(rawValue: s.selectedSegment) ?? .showAtBottom)
    }
    @objc private func removeTapped() { delegate?.cardDidRequestRemove(profileID) }

    @objc private func startRecording() {
        shortcutButton.title = "Press keys…"
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.finishRecording(with: event)
            return nil
        }
    }

    private func finishRecording(with event: NSEvent) {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        if Int(event.keyCode) == kVK_Escape {
            shortcutButton.title = currentCombo.displayString
            return
        }
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        let combo = HotKeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
        if let problem = delegate?.card(profileID, problemWithShortcut: combo) {
            shortcutButton.title = problem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.recordingMonitor == nil else { return }
                self.shortcutButton.title = self.currentCombo.displayString
            }
            return
        }
        currentCombo = combo
        shortcutButton.title = currentCombo.displayString
        delegate?.card(profileID, didSetShortcut: currentCombo)
    }

    // MARK: - Layout helpers

    private func row(_ label: String, _ control: NSView) -> NSView {
        let field = NSTextField(labelWithString: label)
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let r = NSStackView(views: [field, control])
        r.orientation = .horizontal
        r.spacing = 10
        r.alignment = .centerY
        return r
    }

    private func seg(_ labels: [String], _ selected: Int, _ action: Selector) -> NSSegmentedControl {
        let s = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: action)
        s.segmentDistribution = .fillEqually
        s.selectedSegment = selected
        return s
    }
}
