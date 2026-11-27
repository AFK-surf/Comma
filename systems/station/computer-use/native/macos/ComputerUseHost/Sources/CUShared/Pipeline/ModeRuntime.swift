import Foundation

/// Mode-specific session runtime mounted by `SessionRegistry`.
@MainActor
public protocol ModeRuntime: AnyObject {
    /// Bring up virtual desktop, overlays, stream, notch panel, etc.
    /// Throws on failure (the registry treats failure as "session not active"
    /// and surfaces the error).
    func activate(payload: SessionControl) async throws

    /// Tear down everything `activate` brought up. Idempotent and synchronous
    /// so the daemon's signal-driven shutdown path never deadlocks.
    func deactivate()

    /// Parse and execute the action args for this mode. Returns a
    /// `DaemonResponse` ready to ship to the CLI.
    func dispatch(args: [String]) async -> DaemonResponse

    /// Surface a live thinking / progress update in the session's Notch HUD.
    func recordThinking(_ text: String)
}

public extension ModeRuntime {
    func recordThinking(_: String) {}
}
