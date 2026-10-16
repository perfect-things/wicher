import AppKit

/// The app's entry point, called from the `wicher` executable's main.swift.
/// Agent app: no Dock icon, lives in the menu bar.
public enum WicherApp {
    public static func run() -> Never {
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller   // weak: keep `controller` alive below
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) { app.run() }
        exit(0)
    }
}
