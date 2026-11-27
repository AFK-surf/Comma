import Darwin
import Foundation

/// Single-instance registry holding the active background session runtime with
/// explicit `sessionId` ownership isolation so concurrent tasks cannot stomp
/// on or stop each other's session.
@MainActor
public final class SessionRegistry {
    public static let shared = SessionRegistry()

    public typealias Factory = @MainActor () -> ModeRuntime

    private var backgroundFactory: Factory?
    private var backgroundHelp: String?

    public private(set) var active: ModeRuntime?
    public private(set) var activeMode: ModeKind?
    public private(set) var activeSessionID: String?
    public private(set) var activeTitle: String?
    /// True after the user ended the session from the island, until the next
    /// `start` or `stop`: the owning agent's next action is told why it failed.
    public private(set) var stoppedByUser = false
    private var stoppedByUserSessionID: String?

    /// Synchronous activation reservation so concurrent `start` requests cannot
    /// race across `await runtime.activate(...)` and leak a second virtual desktop.
    private var activatingRuntime: ModeRuntime?
    private var activatingSessionID: String?
    private var activatingTitle: String?
    private var cancelActivating = false

    /// Fail-open liveness lease: an abandoned session with no activity for
    /// `idleTimeout` seconds auto-releases so Computer Use never deadlocks.
    public var idleTimeout: TimeInterval
    private let now: () -> Date
    private var lastActivityAt: Date?

    public static let defaultIdleTimeout: TimeInterval = 15 * 60
    public static let maxTitleLength = 80
    static let stoppedByUserMessage =
        "the user stopped this Computer Use session from the notch; ask the user before starting it again"

    init(
        now: @escaping () -> Date = Date.init,
        idleTimeout: TimeInterval = SessionRegistry.defaultIdleTimeout
    ) {
        self.now = now
        self.idleTimeout = idleTimeout
    }

    // MARK: - Registration

    public func registerBackground(factory: @escaping Factory, help: String? = nil) {
        backgroundFactory = factory
        if let help { backgroundHelp = help }
    }

    public func helpText(for mode: ModeKind = .background) -> String? {
        switch mode {
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

    public func handle(action args: [String], sessionId: String? = nil) async -> DaemonResponse {
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
        expireActiveIfIdle()
        let callerID = Self.normalized(sessionId)
        if let active {
            guard callerID == activeSessionID else {
                return .failure(foreignSessionError(verb: "perform actions on"))
            }
            lastActivityAt = now()
            return await active.dispatch(args: args)
        }
        if activatingRuntime != nil {
            if callerID != activatingSessionID {
                return .failure(foreignSessionError(verb: "perform actions on"))
            }
            return .failure("session is still starting; retry once start completes")
        }
        if stoppedByUser, callerID == stoppedByUserSessionID {
            return .failure(Self.stoppedByUserMessage)
        }
        return .failure("no active session; run `start` first")
    }

    public func handle(session control: SessionControl) async -> DaemonResponse {
        switch control.op {
        case .start:
            await startSession(control: control)
        case .stop:
            await stopSession(sessionId: control.sessionId)
        }
    }

    public func recordThinking(_ text: String?, sessionId: String? = nil) {
        expireActiveIfIdle()
        guard let active else { return }
        guard Self.normalized(sessionId) == activeSessionID else { return }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastActivityAt = now()
        active.recordThinking(text)
    }

    public func sessionStatusJSON(for callerSessionID: String? = nil) -> String {
        expireActiveIfIdle()
        let callerID = Self.normalized(callerSessionID)
        let isBusy = active != nil || activatingRuntime != nil
        let ownerID = active != nil ? activeSessionID : activatingSessionID
        let ownedByCaller = isBusy ? (callerID == ownerID) : nil
        let visibleTitle = (ownedByCaller == true) ? (activeTitle ?? activatingTitle) : nil
        let payload = SessionStatusPayload(
            daemon: "running",
            mode: activeMode?.rawValue,
            pid: Int(getpid()),
            busy: isBusy,
            title: visibleTitle,
            ownedByCaller: ownedByCaller
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(payload),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        let modeText = activeMode.map { "\"\($0.rawValue)\"" } ?? "null"
        return "{\"daemon\":\"running\",\"mode\":\(modeText),\"pid\":\(getpid())}"
    }

    // MARK: - Lifecycle

    private func startSession(control: SessionControl) async -> DaemonResponse {
        expireActiveIfIdle()
        let callerID = Self.normalized(control.sessionId)
        if let currentMode = activeMode {
            if callerID == activeSessionID {
                return .failure("session already active in mode=\(currentMode.rawValue); call `stop` first")
            }
            if let activeTitle {
                return .failure(
                    "Computer Use is busy with another task (“\(activeTitle)”); wait for it to finish before starting a new session"
                )
            }
            return .failure(
                "Computer Use is busy with another session; wait for it to finish before starting a new session"
            )
        }
        if activatingRuntime != nil {
            if callerID == activatingSessionID {
                return .failure("session is already starting; wait for `start` to finish")
            }
            if let activatingTitle {
                return .failure(
                    "Computer Use is busy with another task (“\(activatingTitle)”); wait for it to finish before starting a new session"
                )
            }
            return .failure(
                "Computer Use is busy with another session; wait for it to finish before starting a new session"
            )
        }
        let mode = control.mode ?? .background
        guard let factory = backgroundFactory else {
            return .failure("mode \(mode.rawValue) has no runtime registered")
        }

        let title = Self.normalizedTitle(control.background?.title)
        let runtime = factory()
        stoppedByUser = false
        stoppedByUserSessionID = nil
        activatingRuntime = runtime
        activatingSessionID = callerID
        activatingTitle = title
        cancelActivating = false

        do {
            try await runtime.activate(payload: control)
        } catch {
            if activatingRuntime === runtime {
                activatingRuntime = nil
                activatingSessionID = nil
                activatingTitle = nil
                cancelActivating = false
            }
            runtime.deactivate()
            return .failure("activate failed: \(error)")
        }

        let cancelled = cancelActivating || activatingRuntime !== runtime
        if activatingRuntime === runtime {
            activatingRuntime = nil
            activatingSessionID = nil
            activatingTitle = nil
            cancelActivating = false
        }
        if cancelled {
            runtime.deactivate()
            return .failure("session stopped during activation")
        }

        active = runtime
        activeMode = mode
        activeSessionID = callerID
        activeTitle = title
        lastActivityAt = now()
        return .success("session started (mode=\(mode.rawValue))")
    }

    private func stopSession(sessionId: String?) async -> DaemonResponse {
        expireActiveIfIdle()
        let callerID = Self.normalized(sessionId)
        if let active {
            guard callerID == activeSessionID else {
                return .failure(foreignSessionError(verb: "stop"))
            }
            active.deactivate()
            self.active = nil
            activeMode = nil
            activeSessionID = nil
            activeTitle = nil
            lastActivityAt = nil
            stoppedByUser = false
            stoppedByUserSessionID = nil
            return .success("session stopped")
        }
        if activatingRuntime != nil {
            guard callerID == activatingSessionID else {
                return .failure(foreignSessionError(verb: "stop"))
            }
            cancelActivating = true
            return .success("session stopped")
        }
        if stoppedByUser, callerID == stoppedByUserSessionID {
            stoppedByUser = false
            stoppedByUserSessionID = nil
            return .success("session already stopped by the user")
        }
        return .success("no active session")
    }

    /// The user pressed "Stop" in `runtime`'s island. Ends the session only if
    /// `runtime` is the active (or activating) one, the same way a client `stop`
    /// does, and remembers why. Returns false when `runtime` is not current.
    @discardableResult
    public func stopByUser(_ runtime: ModeRuntime) -> Bool {
        if let active, active === runtime {
            let ownerID = activeSessionID
            active.deactivate()
            self.active = nil
            activeMode = nil
            activeSessionID = nil
            activeTitle = nil
            lastActivityAt = nil
            stoppedByUser = true
            stoppedByUserSessionID = ownerID
            return true
        }
        if let activating = activatingRuntime, activating === runtime {
            let ownerID = activatingSessionID
            cancelActivating = true
            activatingRuntime = nil
            activatingSessionID = nil
            activatingTitle = nil
            activating.deactivate()
            stoppedByUser = true
            stoppedByUserSessionID = ownerID
            return true
        }
        return false
    }

    public func deactivateIfActive() {
        if let activating = activatingRuntime {
            cancelActivating = true
            activatingRuntime = nil
            activatingSessionID = nil
            activatingTitle = nil
            activating.deactivate()
        }
        guard let active else { return }
        active.deactivate()
        self.active = nil
        activeMode = nil
        activeSessionID = nil
        activeTitle = nil
        lastActivityAt = nil
        stoppedByUser = false
        stoppedByUserSessionID = nil
    }

    // MARK: - Helpers

    private func expireActiveIfIdle() {
        guard let active, idleTimeout > 0, let lastActivityAt else { return }
        guard now().timeIntervalSince(lastActivityAt) >= idleTimeout else { return }
        active.deactivate()
        self.active = nil
        activeMode = nil
        activeSessionID = nil
        activeTitle = nil
        self.lastActivityAt = nil
        stoppedByUser = false
        stoppedByUserSessionID = nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedTitle(_ value: String?) -> String? {
        guard let raw = normalized(value) else { return nil }
        let singleLine = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !singleLine.isEmpty else { return nil }
        if singleLine.count > maxTitleLength {
            return String(singleLine.prefix(maxTitleLength - 1)) + "…"
        }
        return singleLine
    }

    private func foreignSessionError(verb: String) -> String {
        if let title = activeTitle ?? activatingTitle {
            return "Computer Use is currently used by another task (“\(title)”); cannot \(verb) its session"
        }
        return "Computer Use is currently used by another session; cannot \(verb) its session"
    }
}

private struct SessionStatusPayload: Encodable {
    let daemon: String
    let mode: String?
    let pid: Int
    let busy: Bool
    let title: String?
    let ownedByCaller: Bool?

    enum CodingKeys: String, CodingKey {
        case daemon
        case mode
        case pid
        case busy
        case title
        case ownedByCaller = "owned_by_caller"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(daemon, forKey: .daemon)
        try container.encode(mode, forKey: .mode) // Explicit null when idle for backwards compatibility.
        try container.encode(pid, forKey: .pid)
        try container.encode(busy, forKey: .busy)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(ownedByCaller, forKey: .ownedByCaller)
    }
}
