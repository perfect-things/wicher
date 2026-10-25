import AppKit
import SwiftUI

// Settings → Switchers.

struct SwitchersPane: View {
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
    let validate: (HotKeyCombo) -> String?
    let onChange: (HotKeyCombo) -> Void
    let onRecordingChanged: (Bool) -> Void
    /// Made on appear, not in `init`: a view's `init` runs on every parent
    /// render, and `State(initialValue:)` would build (and drop) a recorder
    /// each time. Its closures only look things up by profile id, so the
    /// first render's are as good as any later one's.
    @State private var recorder: ShortcutRecorder?

    var body: some View {
        Group {
            let button = Button { recorder?.toggleRecording() } label: {
                Text(recorder?.title ?? combo.displayString).frame(minWidth: 72)
            }
            if recorder?.isRecording == true { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
        }
        .help("Click, then press the new shortcut. Esc cancels.")
        .onAppear {
            guard recorder == nil else { return }
            let recorder = ShortcutRecorder(combo: combo)
            recorder.validate = validate
            recorder.onChange = onChange
            recorder.onRecordingChanged = onRecordingChanged
            self.recorder = recorder
        }
        .onChange(of: combo) { _, new in if recorder?.isRecording == false { recorder?.combo = new } }
        .onDisappear { recorder?.stopRecording() }   // card removed or window closed
    }
}
