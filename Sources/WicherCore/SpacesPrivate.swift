import Foundation
import Darwin
import CoreGraphics

/// Access to the private `CGSCopySpacesForWindows`, used only to spot windows
/// that exist but are not in any Space: the inactive tabs of a native tab
/// group, and windows an app closed but kept alive (a menu-bar app's Settings).
/// CGWindowList reports both as merely "not on screen", exactly like a window
/// on another Space. If the symbols are ever unavailable, `isInAnySpace`
/// returns nil and no window is treated as ordered out.
enum SpacesPrivate {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    /// `kCGSAllSpacesMask`: current, other and user Spaces.
    private static let allSpacesMask: Int32 = 0x7

    private static let functions: (connection: MainConnectionFn, copySpaces: CopySpacesFn)? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let connection = dlsym(handle, "CGSMainConnectionID"),
              let copySpaces = dlsym(handle, "CGSCopySpacesForWindows")
        else { return nil }
        return (unsafeBitCast(connection, to: MainConnectionFn.self), unsafeBitCast(copySpaces, to: CopySpacesFn.self))
    }()

    static var isAvailable: Bool { functions != nil }

    /// Whether `wid` belongs to at least one Space; nil if that can't be told.
    ///
    /// Minimized windows and hidden apps' windows keep their Space, so a false
    /// here means the window is ordered out, not merely out of sight.
    static func isInAnySpace(_ wid: CGWindowID) -> Bool? {
        guard let fn = functions,
              let spaces = fn.copySpaces(fn.connection(), allSpacesMask, [wid] as CFArray)?.takeRetainedValue()
        else { return nil }
        return CFArrayGetCount(spaces) > 0
    }
}
