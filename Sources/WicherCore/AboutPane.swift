import AppKit
import SwiftUI

// Settings → About.

struct AboutPane: View {
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
