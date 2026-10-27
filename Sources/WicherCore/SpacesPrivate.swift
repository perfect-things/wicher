import Foundation
import Darwin
import CoreGraphics

/// Access to the private `CGSCopySpacesForWindows`, used to tell apart the
/// off-screen windows CGWindowList lumps together as "not on screen":
/// - in no Space at all: the inactive tabs of a native tab group, and windows
///   an app closed but kept alive (a menu-bar app's Settings);
/// - in a display's current Space: minimized, or its app hidden — both keep
///   their Space;
/// - anything else: on another Space.
///
/// If the symbols are ever unavailable, `spaces(of:)` and `currentSpaces()`
/// return nil and every off-screen window passes for one on another Space.
enum SpacesPrivate {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    /// `kCGSAllSpacesMask`: current, other and user Spaces.
    private static let allSpacesMask: Int32 = 0x7

    private static let functions: (connection: MainConnectionFn,
                                   copySpaces: CopySpacesFn,
                                   copyDisplaySpaces: CopyDisplaySpacesFn?)? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let connection = dlsym(handle, "CGSMainConnectionID"),
              let copySpaces = dlsym(handle, "CGSCopySpacesForWindows")
        else { return nil }
        return (unsafeBitCast(connection, to: MainConnectionFn.self),
                unsafeBitCast(copySpaces, to: CopySpacesFn.self),
                dlsym(handle, "CGSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: CopyDisplaySpacesFn.self) })
    }()

    static var isAvailable: Bool { functions != nil }

    /// The Spaces `wid` belongs to; nil if that can't be told. Empty means the
    /// window is ordered out, not merely out of sight.
    static func spaces(of wid: CGWindowID) -> Set<UInt64>? {
        guard let fn = functions,
              let spaces = fn.copySpaces(fn.connection(), allSpacesMask, [wid] as CFArray)?.takeRetainedValue()
                as? [NSNumber]
        else { return nil }
        return Set(spaces.map(\.uint64Value))
    }

    /// Each display's current Space (`CGSCopyManagedDisplaySpaces`); nil if
    /// that can't be told.
    static func currentSpaces() -> Set<UInt64>? {
        guard let fn = functions, let copy = fn.copyDisplaySpaces,
              let displays = copy(fn.connection())?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        let ids = displays.compactMap { display in
            let space = display["Current Space"] as? [String: Any]
            return ((space?["id64"] ?? space?["ManagedSpaceID"]) as? NSNumber)?.uint64Value
        }
        return ids.isEmpty ? nil : Set(ids)
    }
}
