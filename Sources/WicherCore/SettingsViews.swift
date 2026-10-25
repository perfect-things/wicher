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
            case .exceptions: ExceptionsPane()
            case .about: AboutPane(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
