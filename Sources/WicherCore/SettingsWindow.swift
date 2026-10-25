import AppKit
import SwiftUI

/// The Settings window: a sidebar of panes beside a grouped form, in an
/// ordinary resizable titled window, so it follows `NSApp.appearance`.
///
/// AppKit owns the window and split view (native sidebar material, a
/// non-collapsible sidebar, frame autosave); SwiftUI draws the contents.
@MainActor
final class SettingsWindow: NSObject {
    private(set) var window: NSWindow?
    let model = SettingsModel()

    func show(pane: SettingsPane? = nil) {
        if window == nil { build() }
        if let pane { model.pane = pane }
        model.refreshShortcutNotes()
        model.watchAccessibilityTrust()
        model.refreshLoginItem()
        WindowActivator.activateSelf()
        window?.makeKeyAndOrderFront(nil)
        // Start with nothing focused: a sidebar row left focused (the first
        // one, or the last one Tabbed to) draws a second, dimmer highlight
        // beside the selected pane. Tab enters at the selected row.
        window?.makeFirstResponder(nil)
    }

    func build() {
        let sidebarHost = NSHostingController(rootView: SettingsSidebar(model: model))
        let detailHost = NSHostingController(rootView: SettingsDetail(model: model))
        // The split view and window decide the size; SwiftUI just fills it.
        sidebarHost.sizingOptions = []
        detailHost.sizingOptions = []

        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebar.canCollapse = false
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 260
        let detail = NSSplitViewItem(viewController: detailHost)
        detail.minimumThickness = 460

        let split = NSSplitViewController()
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(detail)

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered,
                           defer: false)
        win.contentViewController = split
        // No title bar of its own: the sidebar already names the pane, so the
        // content runs up under the traffic lights. The title stays set for
        // the Window menu and Mission Control.
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.contentMinSize = NSSize(width: 660, height: 420)
        win.setContentSize(NSSize(width: 760, height: 560))
        win.isReleasedWhenClosed = false   // see WindowEnumerator.cacheSelfWindows
        win.center()
        win.setFrameAutosaveName("WicherSettings")

        // The sidebar and the pane are separate hosting views; without this the
        // key-view loop is the one computed for the first pane shown, and Tab
        // skips controls or can't get back to the sidebar on the others.
        win.autorecalculatesKeyViewLoop = true

        win.title = model.pane.title
        model.onPaneChange = { [weak win] pane in win?.title = pane.title }
        // Disclosures and the trust poll don't outlast the window; the window itself does.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win,
                                               queue: .main) { [model] _ in
            MainActor.assumeIsolated {
                model.expandedPlacements = []
                model.stopWatchingAccessibilityTrust()
            }
        }
        window = win
    }
}
