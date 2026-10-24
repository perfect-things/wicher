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

            Section {
                SurfaceRow(title: "Panel background", surface: $settings.backgroundSurface)
                SurfaceRow(title: "Selection highlight", surface: $settings.highlightSurface)
            } header: {
                SurfaceRow.ColumnCaptions()
            } footer: {
                Text("Set a tint's opacity in the color panel. Solid fills with the tint color. Text switches to light or dark to stay readable on it.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                ValueSlider(title: "Icon size", value: $settings.iconSize,
                            range: HUDMetrics.iconRange, unit: "pt")
                ValueSlider(title: "Row padding", value: $settings.rowPadding,
                            range: HUDMetrics.paddingRange, unit: "pt")
                ValueSlider(title: "Panel width", value: $settings.panelWidthScale,
                            range: HUDMetrics.widthScaleRange, step: 5, unit: "%")
                ValueSlider(title: "Text size", value: $settings.textSize,
                            range: HUDMetrics.textRange, unit: "pt")
                SettingToggle("Show app names on the left", isOn: $settings.showAppNames)
            } header: {
                ResettableHeader(title: "List", isDefault: settings.isListLayoutDefault,
                                 reset: settings.resetListLayout)
            }

            Section {
                ValueSlider(title: "Icon size",
                            info: "Icons shrink to fit when there are too many for the screen.",
                            value: $settings.gridIconSize, range: IconGridLayout.iconRange, unit: "pt")
                ValueSlider(title: "Icon padding", value: $settings.gridIconPadding,
                            range: IconGridLayout.paddingRange, unit: "pt")
                ValueSlider(title: "Icon spacing", value: $settings.gridIconSpacing,
                            range: IconGridLayout.spacingRange, unit: "pt")
                ValueSlider(title: "Text size", value: $settings.gridTextSize,
                            range: IconGridLayout.textRange, unit: "pt")
            } header: {
                ResettableHeader(title: "Icons", isDefault: settings.isIconsLayoutDefault,
                                 reset: settings.resetIconsLayout)
            }
        }
        .formStyle(.grouped)
    }
}

/// A section title with a reset button at its end, shown once a value in
/// the section differs from its default. Hidden rather than removed, so the
/// header keeps its height and the boxes below don't jump.
private struct ResettableHeader: View {
    let title: String
    let isDefault: Bool
    let reset: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button("Reset \(title) to default", systemImage: "arrow.counterclockwise", action: reset)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Reset to default")
                .opacity(isDefault ? 0 : 1)
                .disabled(isDefault)
                .accessibilityHidden(isDefault)
        }
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
                    ProfileRows(model: model, profile: binding, isRemovable: index > 0)
                    PlacementRows(model: model, profile: binding)
                } header: {
                    if index == 0 && !model.accessibilityTrusted { accessibilityWarning }
                } footer: {
                    if index == settings.profiles.count - 1 { addButton.padding(.top, 8) }
                }
            }
        }
        .formStyle(.grouped)
        // With no header above it, the first box starts level with the sidebar's first row.
        .contentMargins(.top, -5, for: .scrollContent)
    }

    /// Once for all switchers, rather than beside every shortcut.
    private var accessibilityWarning: some View {
        Text("⚠︎ Accessibility access is off, so macOS shortcuts such as ⌘Tab cannot be replaced. Turn Wicher on in System Settings → Privacy & Security → Accessibility.")
            .font(.callout.weight(.regular))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var addButton: some View {
        Button(action: model.addProfile) {
            Label("Add Switcher", systemImage: "plus")
        }
    }
}

private struct ProfileRows: View {
    let model: SettingsModel
    @Binding var profile: SwitcherProfile
    let isRemovable: Bool

    var body: some View {
        HStack(spacing: 10) {
            ShortcutField(combo: profile.combo,
                          validate: { [id = profile.id] in model.problem(with: $0, for: id) },
                          onChange: { [id = profile.id] in Settings.shared[profileID: id].combo = $0 },
                          onRecordingChanged: { _ in model.refreshShortcutNotes() })
            if let note = model.shortcutNotes[profile.id], !note.isEmpty {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Picker("Layout", selection: $profile.layout) {
                ForEach(SwitcherLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            if isRemovable {
                Button { model.removeProfile(profile.id) } label: {
                    Label("Remove Switcher", systemImage: "trash").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Remove Switcher")
            }
        }
        .padding(.vertical, 2)
        SegmentedPicker("Show windows of", selection: $profile.scope) { $0.title }
    }
}

/// Where each category of window goes: in the list, in the group at the
/// bottom, or nowhere — behind a disclosure that sums them up while closed.
private struct PlacementRows: View {
    let model: SettingsModel
    @Binding var profile: SwitcherProfile

    var body: some View {
        // A row of its own rather than a DisclosureGroup: in a grouped Form
        // that packs its rows without dividers and clips the first control.
        Button { isExpanded.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                Text("Window placement")
                Spacer()
                if !isExpanded.wrappedValue {
                    Text(summary).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
        if isExpanded.wrappedValue {
            Group {
                SegmentedPicker("On other displays", selection: $profile.otherDisplays) { $0.title }
                SegmentedPicker("On other Spaces", selection: $profile.otherSpaces) { $0.title }
                SegmentedPicker("Minimized", selection: $profile.minimized) { $0.title }
                SegmentedPicker("Of hidden apps", selection: $profile.hidden) { $0.title }
                SegmentedPicker("Apps without windows", selection: $profile.appsWithoutWindows) { $0.title }
            }
            .padding(.leading, 18)
        }
    }

    private var isExpanded: Binding<Bool> {
        let id = profile.id
        return Binding(get: { model.expandedPlacements.contains(id) },
                       set: { if $0 { model.expandedPlacements.insert(id) } else { model.expandedPlacements.remove(id) } })
    }

    /// "1 shown · 3 at bottom · 1 hidden", leaving out the empty ones.
    private var summary: String {
        let all = [profile.otherDisplays, profile.otherSpaces, profile.minimized,
                   profile.hidden, profile.appsWithoutWindows]
        return Placement.allCases.compactMap { placement in
            let count = all.filter { $0 == placement }.count
            return count == 0 ? nil : "\(count) \(placement.summaryTitle)"
        }.joined(separator: " · ")
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
                Text(recorder.title).frame(minWidth: 72)
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
            Link(destination: Self.repository) {
                Label {
                    Text("GitHub")
                } icon: {
                    Image(nsImage: Self.githubMark)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
            }
            .buttonStyle(.bordered)
            .help(Self.repository.absoluteString)
            .padding(.top, 12)
            Spacer()
            Spacer()
        }
        .padding(24)
    }

    static let repository = URL(string: "https://github.com/perfect-things/wicher")!

    /// The GitHub mark (Octicons `mark-github`, MIT) as a template image: SF
    /// Symbols has no brand logos, and an inline SVG needs no resource pipeline.
    static let githubMark: NSImage = {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">\
            <path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/>\
            </svg>
            """
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}

// MARK: - Shared rows

/// A surface on one row: its style, then its tint for Light and for Dark
/// mode, in columns that `ColumnCaptions` (the section header) names.
private struct SurfaceRow: View {
    let title: String
    @Binding var surface: SurfaceAppearance

    static let styleWidth: CGFloat = 130
    static let tintWidth: CGFloat = 66
    static let spacing: CGFloat = 10

    var body: some View {
        LabeledContent {
            HStack(spacing: Self.spacing) {
                Picker("\(title) style", selection: $surface.style) {
                    ForEach(SurfaceStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .frame(width: Self.styleWidth, alignment: .trailing)
                TintWell(title: "\(title) Light mode tint", tint: $surface.light)
                    .frame(width: Self.tintWidth, alignment: .leading)
                TintWell(title: "\(title) Dark mode tint", tint: $surface.dark)
                    .frame(width: Self.tintWidth, alignment: .leading)
            }
        } label: {
            SettingLabel(title)
        }
    }

    struct ColumnCaptions: View {
        var body: some View {
            HStack(spacing: SurfaceRow.spacing) {
                Spacer()
                Text("Style").frame(width: SurfaceRow.styleWidth, alignment: .trailing)
                Text("Light tint").frame(width: SurfaceRow.tintWidth, alignment: .leading)
                Text("Dark tint").frame(width: SurfaceRow.tintWidth, alignment: .leading)
            }
            .font(.caption)
            .fontWeight(.regular)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }
}

/// A color well whose color panel sets the opacity too, and a clear button
/// that takes the tint to 0% — no tint at all.
private struct TintWell: View {
    let title: String
    @Binding var tint: Tint

    var body: some View {
        HStack(spacing: 4) {
            CheckerColorWell.Representable(title: title, color: color)
                .help("\(tint.opacity) %")
            // Hidden, not removed, when there's nothing to clear, so the
            // columns don't shift.
            Button("Clear \(title)", systemImage: "xmark.circle.fill") { tint.opacity = 0 }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("No tint")
                .opacity(tint.opacity == 0 ? 0 : 1)
                .disabled(tint.opacity == 0)
                .accessibilityHidden(tint.opacity == 0)
        }
    }

    private var color: Binding<NSColor> {
        Binding(get: { tint.color.nsColor.withAlphaComponent(tint.alpha) },
                set: { picked in
                    let rgb = RGBColor(picked)
                    var opacity = Int(((picked.usingColorSpace(.sRGB)?.alphaComponent ?? 1) * 100).rounded())
                    // A cleared tint hands the panel a transparent color, and
                    // picking another color would keep it invisible: a new
                    // color on a cleared tint comes in opaque.
                    if opacity == 0, tint.opacity == 0, !rgb.isClose(to: tint.color) { opacity = 100 }
                    tint = Tint(color: rgb, opacity: opacity)
                })
    }
}

/// A color well that shows a translucent color as one swatch over a
/// checkerboard, not AppKit's diagonal split into opaque and translucent.
/// SwiftUI's `ColorPicker` can't change that, and the well draws itself with
/// SwiftUI inside (`drawWell(inside:)` is never called), so the swatch is a
/// view laid over the well's own, which keeps the well's ring, clicks and
/// color panel.
final class CheckerColorWell: NSColorWell {
    /// The well's own swatch sits this far inside its bounds (measured; the
    /// ring around it is the well's).
    private static let swatchInset: CGFloat = 3

    private let swatch = Swatch()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(swatch)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var color: NSColor {
        didSet { swatch.color = color }
    }

    override func layout() {
        super.layout()
        // On top of the well's hosting view, which may be (re)added later.
        if subviews.last !== swatch { addSubview(swatch, positioned: .above, relativeTo: nil) }
        swatch.frame = bounds.insetBy(dx: Self.swatchInset, dy: Self.swatchInset)
    }

    private final class Swatch: NSView {
        var color: NSColor = .clear {
            didSet { needsDisplay = true }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).addClip()
            NSColor.white.setFill()
            bounds.fill()
            NSColor(white: 0.78, alpha: 1).setFill()
            let side: CGFloat = 4
            for row in 0..<Int((bounds.height / side).rounded(.up)) {
                for column in stride(from: row % 2, to: Int((bounds.width / side).rounded(.up)), by: 2) {
                    NSRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side).fill()
                }
            }
            color.setFill()
            bounds.fill(using: .sourceOver)
        }
    }

    struct Representable: NSViewRepresentable {
        let title: String
        @Binding var color: NSColor

        func makeNSView(context: Context) -> CheckerColorWell {
            let well = CheckerColorWell()
            well.supportsAlpha = true
            well.target = context.coordinator
            well.action = #selector(Coordinator.colorChanged(_:))
            return well
        }

        func updateNSView(_ well: CheckerColorWell, context: Context) {
            context.coordinator.color = $color
            well.setAccessibilityLabel(title)
            if well.color != color { well.color = color }
        }

        func makeCoordinator() -> Coordinator { Coordinator(color: $color) }

        @MainActor final class Coordinator: NSObject {
            var color: Binding<NSColor>
            init(color: Binding<NSColor>) { self.color = color }
            @objc func colorChanged(_ well: NSColorWell) { color.wrappedValue = well.color }
        }
    }
}

/// A labelled slider with its value printed beside it.
private struct ValueSlider: View {
    let title: String
    var subtitle: String?
    var info: String?
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
            SettingLabel(title, hint: subtitle, info: info)
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
/// generously than a grouped Form's built-in subtitle — and an optional info
/// button beside it for text that shouldn't take up a line.
private struct SettingLabel: View {
    let title: String
    let hint: String?
    let info: String?

    init(_ title: String, hint: String? = nil, info: String? = nil) {
        self.title = title
        self.hint = hint
        self.info = info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title)
                if let info { InfoButton(text: info) }
            }
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

/// An ⓘ that shows `text` as a tooltip on hover, and in a popover when
/// clicked or pressed with Space (a tooltip can't be opened from the
/// keyboard). VoiceOver reads the text as the button's help.
private struct InfoButton: View {
    let text: String
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(text)
        .accessibilityLabel("More Info")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240, alignment: .leading)
                .padding(12)
        }
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
