import Darwin
import Foundation

/// Single-instance registry that holds the active mode runtime (if any).
/// The daemon process registers foreground and background factories at startup;
/// the registry instantiates one on `start --mode <...>` and tears it down on
/// `stop`.
@MainActor
public final class SessionRegistry {
    public static let shared = SessionRegistry()

    public typealias Factory = @MainActor () -> ModeRuntime

    private var foregroundFactory: Factory?
    private var backgroundFactory: Factory?
    private var foregroundHelp: String?
    private var backgroundHelp: String?

    public private(set) var active: ModeRuntime?
    public private(set) var activeMode: ModeKind?

    private init() {}

    // MARK: - Registration

    public func registerForeground(factory: @escaping Factory, help: String? = nil) {
        foregroundFactory = factory
        if let help { foregroundHelp = help }
    }

    public func registerBackground(factory: @escaping Factory, help: String? = nil) {
        backgroundFactory = factory
        if let help { backgroundHelp = help }
    }

    public func helpText(for mode: ModeKind) -> String? {
        switch mode {
        case .foreground: foregroundHelp
        case .background: backgroundHelp
        }
    }

    public func permissionsStatusJSON() -> String {
        let report = PermissionStatusProbe.report()
        do {
            let data = try JSONEncoder().encode(report)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }

    public func openPermissionFlow() -> String {
        guard let bridge = DaemonPermissionBridge.shared else {
            return "permission bridge unavailable"
        }
        return bridge.showAuthorizationUI()
    }

    // MARK: - Dispatch

    public func handle(action args: [String]) async -> DaemonResponse {
        // Pre-session workspace introspection lets the agent list apps/windows
        // before `start` so it can choose what to pass in `apps: [...]`.
        if let first = args.first {
            switch first {
            case "list-applications":
                return .success(WorkspaceIntrospection.listApplicationsText())
            case "list-windows":
                return .success(WorkspaceIntrospection.listWindowsText())
            default:
                break
            }
        }
        if let active {
            return await active.dispatch(args: args)
        }
        return .failure("no active session; run `start --mode <foreground|background>` first")
    }

    public func handle(session control: SessionControl) async -> DaemonResponse {
        switch control.op {
        case .start:
            await startSession(control: control)
        case .stop:
            await stopSession()
        }
    }

    public func sessionStatusJSON() -> String {
        let pid = getpid()
        let modeText = if let activeMode {
            "\"\(activeMode.rawValue)\""
        } else {
            "null"
        }
        return "{\"daemon\":\"running\",\"mode\":\(modeText),\"pid\":\(pid)}"
    }

    // MARK: - Lifecycle

    private func startSession(control: SessionControl) async -> DaemonResponse {
        if let activeMode {
            return .failure("session already active in mode=\(activeMode.rawValue); call `stop` first")
        }
        guard let mode = control.mode else {
            return .failure("start: missing --mode")
        }

        let factory: Factory? = switch mode {
        case .foreground: foregroundFactory
        case .background: backgroundFactory
        }
        guard let factory else {
            return .failure("mode \(mode.rawValue) has no runtime registered")
        }

        let runtime = factory()
        do {
            try await runtime.activate(payload: control)
        } catch {
            return .failure("failed to activate mode=\(mode.rawValue): \(error)")
        }
        active = runtime
        activeMode = mode
        return .success("session started (mode=\(mode.rawValue))")
    }

    private func stopSession() async -> DaemonResponse {
        guard let active else {
            return .success("no active session")
        }
        active.deactivate()
        self.active = nil
        activeMode = nil
        return .success("session stopped")
    }

    /// Called from the daemon's signal-driven cleanup path so an in-flight
    /// session is torn down cleanly even when the daemon is being killed.
    /// Synchronous so the signal handler never waits on an async hop back
    /// to the main actor it itself is occupying.
    public func deactivateIfActive() {
        guard let active else { return }
        active.deactivate()
        self.active = nil
        activeMode = nil
    }
}
