import AppKit
import SwiftUI

// Settings → General.

struct GeneralPane: View {
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
            NSPasteboard.general.setString(report + ExceptionRules.diagnosticsReport(), forType: .string)
            copied = true
        }
    }
}
