import AppKit

// The apps Settings → Exceptions offers and the icons it shows for them.

/// One app the picker offers.
struct AppChoice: Identifiable, Hashable, Sendable {
    let app: AppRef
    var id: String { app.key }
}

/// Where the picker's apps come from.
enum AppCatalog {
    /// Running apps with a Dock icon, A–Z. Menu-bar apps and the ~150
    /// background agents are left out — the ones that ever had a row
    /// (loginwindow…) are under "Seen by Wicher". A few LaunchServices
    /// reads per process: done once, when the picker opens.
    @MainActor static func running() -> [AppChoice] {
        var byKey: [String: AppChoice] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let name = app.localizedName, !name.isEmpty else { continue }
            let ref = AppRef(bundleID: app.bundleIdentifier, name: name)
            byKey[ref.key] = AppChoice(app: ref)
        }
        return byKey.values.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    }

    static let searchedFolders: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    /// The `.app`s directly in `searchedFolders`, A–Z, read off the main thread.
    static func installed() async -> [AppChoice] {
        await Task.detached(priority: .userInitiated) {
            var byKey: [String: AppChoice] = [:]
            for folder in searchedFolders {
                let urls = (try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                for url in urls where url.pathExtension == "app" {
                    if let app = app(at: url) { byKey[app.key] = AppChoice(app: app) }
                }
            }
            return byKey.values.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        }.value
    }

    static func app(at url: URL) -> AppRef? {
        guard let bundle = Bundle(url: url) else { return nil }
        // Some apps ship an empty display name.
        let name = ["CFBundleDisplayName", "CFBundleName"]
            .lazy.compactMap { bundle.object(forInfoDictionaryKey: $0) as? String }
            .first { !$0.trimmed.isEmpty }
            ?? url.deletingPathExtension().lastPathComponent
        return AppRef(bundleID: bundle.bundleIdentifier, name: name)
    }
}

/// App icons by bundle ID (else by running app name), cached. Apps that
/// aren't installed or running get the generic app icon.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for app: AppRef) -> NSImage {
        if let icon = cache[app.key] { return icon }
        let icon = lookUp(app) ?? NSWorkspace.shared.icon(for: .applicationBundle)
        cache[app.key] = icon
        return icon
    }

    private static func lookUp(_ app: AppRef) -> NSImage? {
        if let id = app.bundleID {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.icon
        }
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == app.name }?.icon
    }
}
