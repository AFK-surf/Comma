import Foundation

/// Mode-specific session runtime mounted by `SessionRegistry`. The
/// foreground and background implementations live in CUForeground and
/// CUBackground respectively; CUShared only knows the protocol so it does not
/// depend on either mode.
@MainActor
public protocol ModeRuntime: AnyObject {
    /// Whether the foreground intervention detector should be wired to this
    /// runtime. Background mode returns `false` since user input is
    /// expected to be concurrent with automation.
    var supportsIntervention: Bool { get }

    /// Bring up overlays, dim mask, app isolation, intervention monitors,
    /// etc. Throws on failure (the registry treats failure as "session not
    /// active" and surfaces the error).
    func activate(payload: SessionControl) async throws

    /// Tear down everything `activate` brought up. Idempotent. Kept
    /// synchronous so the daemon's signal-driven shutdown path can call
    /// it without bouncing through an async bridge (blocking the main
    /// thread on a Task that needs the main actor to run = deadlock).
    func deactivate()

    /// Parse and execute the action args for this mode. Returns a
    /// `DaemonResponse` ready to ship to the CLI.
    func dispatch(args: [String]) async -> DaemonResponse
}
