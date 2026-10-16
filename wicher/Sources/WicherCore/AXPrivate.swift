import Foundation
import Darwin
import ApplicationServices
import CoreGraphics

/// Access to the private `_AXUIElementGetWindow`, used only to correlate an
/// Accessibility window with its `CGWindowID` so we can tell which Space a
/// window is on. If the symbol is ever unavailable, Space filtering degrades
/// gracefully (every window is treated as "current Space").
enum AXPrivate {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindow: GetWindowFn? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    static var isAvailable: Bool { getWindow != nil }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = getWindow else { return nil }
        var wid: CGWindowID = 0
        return fn(element, &wid) == .success ? wid : nil
    }
}
