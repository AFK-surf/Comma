import Foundation

/// Contract the daemon executable fulfils so any module can drive the
/// authorization UI without linking PermissionFlow / AppKit SwiftUI directly.
@MainActor
public protocol DaemonPermissionBridgeProviding: AnyObject {
    /// Show the unified authorization window to the user. Returns a short
    /// human-readable status line for the CLI. Must not block the caller —
    /// the window drives its own lifecycle and polls TCC internally.
    func showAuthorizationUI() -> String
}

public enum DaemonPermissionBridge {
    @MainActor public static var shared: (any DaemonPermissionBridgeProviding)?
}
