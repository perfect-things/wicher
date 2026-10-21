import AppKit
import SwiftUI

// The Settings window's content: a source-list sidebar and one grouped Form
// per pane. Hosted by `SettingsWindow` in an NSSplitViewController.

/// Plain buttons rather than a selectable `List`: a List's selection is drawn
/// in the accent color, which swallows the (accent-colored) icons. This draws
/// a neutral highlight instead, like most apps' settings sidebars.
///
/// No focus ring: with keyboard navigation on, the first row took focus as
/// the window opened and wore a blue ring. Keyboard focus is drawn as a
/// fainter version of the selection highlight instead. Focus follows the
/// selection: a click selects without focusing, and the first row takes focus
/// whatever pane is shown, so otherwise a second, dimmer highlight lingered.
struct SettingsSidebar: View {
    let model: SettingsModel
    @FocusState private var focused: SettingsPane?

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(SettingsPane.allCases) { pane in
                    Button { model.pane = pane } label: { row(pane) }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .focused($focused, equals: pane)
                        .accessibilityAddTraits(pane == model.pane ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        // Entering the sidebar lands on the selected row, like a List;
        // Tab between rows still moves focus (and its highlight) freely.
        .onChange(of: focused) { old, new in
            if old == nil, let new, new != model.pane { focused = model.pane }
        }
        .onChange(of: model.pane) {
            if focused != nil { focused = model.pane }
        }
    }

    private func row(_ pane: SettingsPane) -> some View {
        HStack(spacing: 10) {
            Image(systemName: pane.symbol)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            Text(pane.title)
                .font(.system(size: 14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(pane == model.pane ? 0.1 : focused == pane ? 0.05 : 0)))
        .contentShape(Rectangle())
    }
}

struct SettingsDetail: View {
    let model: SettingsModel

    var body: some View {
        Group {
            switch model.pane {
            case .general: GeneralPane(model: model)
            case .appearance: AppearancePane()
            case .switchers: SwitchersPane(model: model)
            case .about: AboutPane(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - General

private struct GeneralPane: View {
    let model: SettingsModel
    @Bindable private var settings = Settings.shared
    @State private var copied = false
    @State private var collecting = false

    var body: some View {
        Form {
            Section {
                SettingToggle("Launch at login", hint: model.loginItemHint, isOn: model.launchAtLogin)
                if model.loginItemNeedsApproval {
                    HStack {
                        Spacer()
                        Button("Open Login Items…", action: model.openLoginItems)
                    }
                }
                SettingToggle("Show menu bar icon",
                              hint: "When it is hidden, open Wicher again (from Finder or Spotlight) to get back to Settings.",
                              isOn: $settings.showMenuBarIcon)
            }

            Section("Switcher panel") {
                SettingToggle("Change selection on mouse hover", isOn: $settings.selectOnHover)
                SettingToggle("Change selection on scroll", isOn: $settings.selectOnScroll)
                ValueSlider(title: "Show panel after",
                            subtitle: "A quick tap-and-release within the delay switches to the previous window without showing the panel — like ⌘Tab.",
                            value: $settings.showDelayMs, range: 0...400, unit: "ms")
            }

            // Window detection on macOS is mostly undocumented behavior, and
            // the cases that go wrong (hidden apps, full-screen Spaces) only
            // exist on a real desktop — this dump is how to see them.
            Section("Troubleshooting") {
                LabeledContent {
                    Button(copied ? "Copied ✓" : "Copy Diagnostics") { copyDiagnostics() }
                    .disabled(collecting)
                } label: {
                    SettingLabel("Diagnostics", hint: "If a window is missing or mislabelled in the switcher, this copies what macOS reports about every app's windows to the clipboard, for a bug report.")
                }
            }
        }
        .formStyle(.grouped)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func copyDiagnostics() {
        collecting = true
        WindowEnumerator.shared.diagnosticsReport { report in
            collecting = false
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            copied = true
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel("Theme", hint: "“System” follows macOS Appearance.")
                }
            }

            Section("Background") {
                SurfaceRows(surface: $settings.backgroundSurface)
            }

            Section {
                SurfaceRows(surface: $settings.highlightSurface)
            } header: {
                Text("Selection highlight")
            } footer: {
                Text("Solid fills with the tint color. Text switches to light or dark to stay readable on it.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                ValueSlider(title: "Icon size", value: $settings.iconSize,
                            range: HUDMetrics.iconRange, unit: "pt")
                ValueSlider(title: "Row padding", value: $settings.rowPadding,
                            range: HUDMetrics.paddingRange, unit: "pt")
                ValueSlider(title: "Panel width",
                            subtitle: "Relative to the width that suits the icon size.",
                            value: $settings.panelWidthScale,
                            range: HUDMetrics.widthScaleRange, step: 5, unit: "%")
                SettingToggle("Show app names",
                              hint: "Off, each row is just the app icon and the window title.",
                              isOn: $settings.showAppNames)
                ValueSlider(title: "Text size", value: $settings.textSize,
                            range: HUDMetrics.textRange, unit: "pt")
            } header: {
                Text("List")
            }

            Section {
                ValueSlider(title: "Icon size",
                            subtitle: "Icons shrink to fit when there are too many for the screen.",
                            value: $settings.gridIconSize, range: IconGridLayout.iconRange, unit: "pt")
                ValueSlider(title: "Icon padding",
                            subtitle: "Space between an icon and the edge of its selection highlight.",
                            value: $settings.gridIconPadding, range: IconGridLayout.paddingRange, unit: "pt")
                ValueSlider(title: "Icon spacing", value: $settings.gridIconSpacing,
                            range: IconGridLayout.spacingRange, unit: "pt")
                ValueSlider(title: "Text size", value: $settings.gridTextSize,
                            range: IconGridLayout.textRange, unit: "pt")
            } header: {
                Text("Icons")
            } footer: {
                Text("Each switcher picks List or Icons in Switchers. Changes here apply the next time the switcher opens.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Switchers

private struct SwitchersPane: View {
    let model: SettingsModel
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            ForEach(settings.profiles.enumerated(), id: \.element.id) { index, profile in
                // By id, not by index: the binding must survive Remove Switcher.
                let binding = $settings[profileID: profile.id]
                // One box per switcher, so its rows read as belonging together.
                Section {
                    ProfileRows(model: model, profile: binding)
                    PlacementRows(model: model, profile: binding,
                                  isRemovable: settings.profiles.count > 1)
                } header: {
                    if index == 0 { header }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var header: some View {
        HStack {
            Text("Each switcher has its own shortcut and decides which windows it lists.")
                .font(.callout.weight(.regular))
                .foregroundStyle(.secondary)
            Spacer()
            // A Label, not a bare Image, so VoiceOver reads "Add Switcher";
            // the circle is inside the label so all of it is clickable.
            Button(action: model.addProfile) {
                Label("Add Switcher", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Add Switcher")
        }
    }
}

private struct ProfileRows: View {
    let model: SettingsModel
    @Binding var profile: SwitcherProfile

    var body: some View {
        LabeledContent {
            ShortcutField(combo: profile.combo,
                          validate: { [id = profile.id] in model.problem(with: $0, for: id) },
                          onChange: { [id = profile.id] in Settings.shared[profileID: id].combo = $0 },
                          onRecordingChanged: { _ in model.refreshShortcutNotes() })
        } label: {
            SettingLabel("Shortcut", hint: model.shortcutNotes[profile.id] ?? "")
        }
        SegmentedPicker("Layout", selection: $profile.layout) { $0.title }
        SegmentedPicker("Show windows of", selection: $profile.scope) { $0.title }
    }
}

/// Where each category of window goes: in the list, in a section at the
/// bottom, or nowhere.
private struct PlacementRows: View {
    let model: SettingsModel
    @Binding var profile: SwitcherProfile
    let isRemovable: Bool

    var body: some View {
        SegmentedPicker("On other displays", hint: "Not on the display the switcher opens on",
                        selection: $profile.otherDisplays) { $0.title }
        SegmentedPicker("On other Spaces", hint: "Not on any display’s current Space",
                        selection: $profile.otherSpaces) { $0.title }
        SegmentedPicker("Minimized", hint: "In the Dock", selection: $profile.minimized) { $0.title }
        SegmentedPicker("Of hidden apps", hint: "Apps hidden with ⌘H",
                        selection: $profile.hidden) { $0.title }
        SegmentedPicker("Apps without windows", hint: "Running, nothing open",
                        selection: $profile.appsWithoutWindows) { $0.title }
        if isRemovable {
            HStack {
                Spacer()
                Button(role: .destructive) { model.removeProfile(profile.id) } label: {
                    Text("Remove Switcher").foregroundStyle(.red)
                }
            }
        }
    }
}

/// A segmented control over every case of an enum, sized to its segments
/// rather than stretched across the row.
private struct SegmentedPicker<E: CaseIterable & Hashable>: View where E.AllCases: RandomAccessCollection {
    let title: String
    var hint: String?
    @Binding var selection: E
    let label: (E) -> String

    init(_ title: String, hint: String? = nil, selection: Binding<E>, label: @escaping (E) -> String) {
        self.title = title
        self.hint = hint
        self._selection = selection
        self.label = label
    }

    var body: some View {
        // LabeledContent, like the Shortcut row: a bare segmented Picker sits
        // short of the trailing edge, and a long hint pushes it onto a line
        // of its own.
        LabeledContent {
            Picker(title, selection: $selection) {
                ForEach(E.allCases, id: \.self) { Text(label($0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        } label: {
            SettingLabel(title, hint: hint)
        }
    }
}

/// The shortcut button: shows the combo, records a new one when pressed
/// (click, or Space with keyboard navigation). Recording is `ShortcutRecorder`.
private struct ShortcutField: View {
    var combo: HotKeyCombo
    @State private var recorder: ShortcutRecorder

    /// The closures are wired once, when the recorder is created: they only
    /// look things up by profile id, so later renders' copies are no different.
    init(combo: HotKeyCombo, validate: @escaping (HotKeyCombo) -> String?,
         onChange: @escaping (HotKeyCombo) -> Void, onRecordingChanged: @escaping (Bool) -> Void) {
        self.combo = combo
        _recorder = State(initialValue: {
            let recorder = ShortcutRecorder(combo: combo)
            recorder.validate = validate
            recorder.onChange = onChange
            recorder.onRecordingChanged = onRecordingChanged
            return recorder
        }())
    }

    var body: some View {
        Group {
            let button = Button(action: recorder.toggleRecording) {
                Text(recorder.title).frame(minWidth: 96)
            }
            if recorder.isRecording { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
        }
        .help("Click, then press the new shortcut. Esc cancels.")
        .onChange(of: combo) { _, new in if !recorder.isRecording { recorder.combo = new } }
        .onDisappear(perform: recorder.stopRecording)   // card removed or window closed
    }
}

// MARK: - About

private struct AboutPane: View {
    let model: SettingsModel

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)   // the name is printed right below
            Text("Wicher")
                .font(.system(size: 26, weight: .semibold))
            Text(model.version)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("A keyboard-first window switcher for macOS.")
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Spacer()
            Spacer()
        }
        .padding(24)
    }
}

// MARK: - Shared rows

/// A surface's style picker, then its tint for Light and for Dark mode.
private struct SurfaceRows: View {
    @Binding var surface: SurfaceAppearance

    var body: some View {
        Picker("Style", selection: $surface.style) {
            ForEach(SurfaceStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        TintRow(title: "Light mode tint", tint: $surface.light)
        TintRow(title: "Dark mode tint", tint: $surface.dark)
    }
}

/// A color well and an opacity slider. Opacity is its own slider, not the
/// color panel's, so 0% (no tint) is one drag away.
private struct TintRow: View {
    let title: String
    @Binding var tint: Tint

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                ColorPicker(title, selection: color, supportsOpacity: false)
                    .labelsHidden()
                Slider(value: $tint.opacity[sliderStep: 1],
                       in: Double(Tint.opacityRange.lowerBound)...Double(Tint.opacityRange.upperBound))
                    .labelsHidden()
                    .frame(minWidth: 80, maxWidth: 170)
                Text("\(tint.opacity) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        } label: {
            SettingLabel(title)
        }
    }

    private var color: Binding<Color> {
        Binding(get: { Color(nsColor: tint.color.nsColor) },
                set: { tint.color = RGBColor(NSColor($0)) })
    }
}

/// A labelled slider with its value printed beside it.
private struct ValueSlider: View {
    let title: String
    var subtitle: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let unit: String

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                // Snapped here, not with `Slider(step:)`, which draws tick marks.
                Slider(value: $value[sliderStep: step],
                       in: Double(range.lowerBound)...Double(range.upperBound))
                    .labelsHidden()
                    .frame(minWidth: 120, maxWidth: 220)
                Text("\(value) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        } label: {
            SettingLabel(title, hint: subtitle)
        }
    }
}

private extension Int {
    /// The value as a slider position; set, it snaps to a multiple of `step`
    /// and writes only when that differs, so a drag doesn't write (and post)
    /// once per pixel.
    subscript(sliderStep step: Int) -> Double {
        get { Double(self) }
        set {
            let snapped = Int((newValue / Double(step)).rounded()) * step
            if snapped != self { self = snapped }
        }
    }
}

/// A setting's title with an optional hint under it — spaced and leaded more
/// generously than a grouped Form's built-in subtitle.
private struct SettingLabel: View {
    let title: String
    let hint: String?

    init(_ title: String, hint: String? = nil) {
        self.title = title
        self.hint = hint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
            if let hint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, hint == nil ? 0 : 2)
    }
}

/// A switch sized to sit beside the Form's sliders and pop-ups: regular is
/// too big next to them, the Form's default mini too small.
private struct SettingToggle: View {
    let title: String
    var hint: String?
    @Binding var isOn: Bool

    init(_ title: String, hint: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.hint = hint
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) { SettingLabel(title, hint: hint) }
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}
