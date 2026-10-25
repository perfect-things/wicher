import AppKit
import SwiftUI

// Settings → Appearance.

struct AppearancePane: View {
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
