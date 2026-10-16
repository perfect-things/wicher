import AppKit

// Entry point. Agent app: no Dock icon, lives in the menu bar.
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
