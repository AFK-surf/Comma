import Foundation
import MCP

/// What tools share: permission state, the EventKit store, the AppleScript
/// runner and where this Mac keeps the files tools read.
public final class ToolContext: @unchecked Sendable {
    let permissions: PermissionAuthority
    let events: EventStoreBox
    let appleScript: AppleScriptRunner
    let files: FileLocations

    /// The same context with the Drive folder Main resolved for one call.
    func with(driveRoot: URL?) -> ToolContext {
        guard let driveRoot else { return self }
        return ToolContext(
            permissions: permissions, events: events, appleScript: appleScript,
            files: FileLocations(driveRoot: driveRoot))
    }

    init(permissions: PermissionAuthority, events: EventStoreBox, appleScript: AppleScriptRunner, files: FileLocations) {
        self.permissions = permissions
        self.events = events
        self.appleScript = appleScript
        self.files = files
    }
}

public struct FileLocations: Sendable {
    /// The local folder Comma Drive syncs, which tools address as `/drive/...`. Main
    /// passes the current one with each call (`_meta` key `comma/driveRoot`), because
    /// the user can set Drive up while this server runs.
    public let driveRoot: URL?

    public init(driveRoot: URL?) {
        self.driveRoot = driveRoot
    }

    /// `COMMA_DRIVE_ROOT` sets a default Drive folder, for running the server by hand.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> FileLocations
    {
        let drive = environment["COMMA_DRIVE_ROOT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return FileLocations(driveRoot: drive)
    }
}

/// `comma/permissions`: every app's permission state, for Comma's Plugins page.
public enum CommaPermissions: MCP.Method {
    public static let name = "comma/permissions"
    public typealias Result = Value
}

/// `comma/requestPermission`: asks macOS for the permissions an app needs when the
/// user turns it on. Only Main sends this, from the user's click.
public enum CommaRequestPermission: MCP.Method {
    public static let name = "comma/requestPermission"
    public typealias Result = Value

    public struct Parameters: Codable, Hashable, Sendable {
        public let app: String
    }
}

/// The MCP server's behaviour: the tool list, calls, and permission reports.
/// It serves every app's tools; Main filters them by the user's switches.
public final class MacAppsService: @unchecked Sendable {
    public let tools: [ToolDefinition]
    private let byName: [String: ToolDefinition]
    private let context: ToolContext
    private let callTimeout: Duration

    public init(tools: [ToolDefinition], context: ToolContext, callTimeout: Duration = .seconds(20)) {
        self.tools = tools
        self.byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.context = context
        self.callTimeout = callTimeout
    }

    public static func live(files: FileLocations = .fromEnvironment()) -> MacAppsService {
        let events = EventStoreBox()
        let context = ToolContext(
            permissions: SystemPermissions(events: events),
            events: events,
            appleScript: AppleScriptRunner(),
            files: files
        )
        return MacAppsService(tools: Catalog.all, context: context)
    }

    public func register(on server: Server) async {
        await server.withMethodHandler(ListTools.self) { [tools] _ in
            ListTools.Result(tools: tools.map(\.mcpTool))
        }
        await server.withMethodHandler(CallTool.self) { [self] parameters in
            await call(
                parameters.name, parameters.arguments ?? [:],
                driveRoot: parameters._meta?[Self.driveRootKey]?.stringValue)
        }
        await server.withMethodHandler(CommaPermissions.self) { [self] _ in
            await permissionReport()
        }
        await server.withMethodHandler(CommaRequestPermission.self) { [self] parameters in
            guard let app = MacApp(rawValue: parameters.app) else {
                throw MCPError.invalidParams("Unknown app: \(parameters.app)")
            }
            return await requestPermissions(for: app)
        }
        await server.withMethodHandler(CommaAppIcons.self) { _ in
            await AppIcons.report()
        }
    }

    public static let driveRootKey = "comma/driveRoot"

    public func call(_ name: String, _ arguments: [String: Value], driveRoot: String? = nil) async -> CallTool.Result {
        let context = self.context.with(driveRoot: driveRoot.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) })
        guard let tool = byName[name] else {
            return Self.failure(ToolFailure("unknown_tool", "There is no tool named \(name)."))
        }
        do {
            for requirement in tool.requirements {
                let state = await context.permissions.status(requirement)
                // An Automation target that is not running is checked again once
                // the AppleScript runner has opened it.
                if state == .granted { continue }
                if case .automation = requirement, state == .unknown { continue }
                throw ToolFailure.permissionRequired(requirement, state)
            }
            let value = try await withDeadline(callTimeout) { [context] in
                try await tool.run(Arguments(arguments), context)
            }
            return CallTool.Result(
                content: [.text(text: value.jsonText, annotations: nil, _meta: nil)],
                structuredContent: Optional(value)
            )
        } catch let failure as ToolFailure {
            return Self.failure(failure)
        } catch {
            return Self.failure(ToolFailure("app_error", error.localizedDescription))
        }
    }

    public func permissionReport() async -> Value {
        var apps: [Value] = []
        for app in MacApp.allCases {
            apps.append(await appPermissions(app))
        }
        return ["apps": .array(apps)]
    }

    public func requestPermissions(for app: MacApp) async -> Value {
        // The answer to a request stands: an app opened only to ask is closed again,
        // and a closed app's Automation status reads as unknown.
        var answered: [String: PermissionState] = [:]
        for entry in AppRequirements.of(app) where entry.onEnable {
            let state = await context.permissions.status(entry.requirement)
            // Screen Recording is asked again even when granted: macOS's separate
            // question about capturing without its window picker comes with a capture.
            if state != .granted || entry.requirement == .screenRecording {
                answered[entry.requirement.id] = await context.permissions.request(entry.requirement)
            }
        }
        return await appPermissions(app, answered: answered)
    }

    private func appPermissions(_ app: MacApp, answered: [String: PermissionState] = [:]) async -> Value {
        var requirements: [Value] = []
        for entry in AppRequirements.of(app) {
            var state = await context.permissions.status(entry.requirement)
            if let asked = answered[entry.requirement.id], state == .unknown { state = asked }
            requirements.append([
                "requirement": .string(entry.requirement.id),
                "state": .string(state.rawValue),
                "on_enable": .bool(entry.onEnable),
                "tools": .array(entry.tools.map { .string($0) }),
            ])
        }
        let toolCount = tools.filter { $0.app == app }.count
        return ["app": .string(app.rawValue), "tool_count": .int(toolCount), "requirements": .array(requirements)]
    }

    private static func failure(_ failure: ToolFailure) -> CallTool.Result {
        let value = failure.value
        return CallTool.Result(
            content: [.text(text: value.jsonText, annotations: nil, _meta: nil)],
            structuredContent: Optional(value),
            isError: true
        )
    }
}

/// Runs `operation`, or fails with `timeout` when it takes longer than `limit`.
/// The caller gets the timeout at once even when the work is blocked in an app;
/// the work is cancelled, and a change it already sent may still be made.
func withDeadline<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let outcome = FirstOutcome<T>()
    return try await withCheckedThrowingContinuation { continuation in
        outcome.attach(continuation)
        let work = Task {
            do {
                outcome.resolve(.success(try await operation()))
            } catch {
                outcome.resolve(.failure(error))
            }
        }
        let timer = Task {
            try await Task.sleep(for: limit)
            outcome.resolve(.failure(ToolFailure(
                "timeout",
                "This Mac did not finish in \(limit.components.seconds) seconds. A change may or may not have been made."
            )))
            work.cancel()
        }
        outcome.onResolve { timer.cancel() }
    }
}

/// Resumes a continuation with whichever result arrives first.
private final class FirstOutcome<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var resolved = false
    private var cleanup: (() -> Void)?

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func onResolve(_ action: @escaping () -> Void) {
        lock.lock()
        let done = resolved
        if !done { cleanup = action }
        lock.unlock()
        if done { action() }
    }

    func resolve(_ result: Result<T, Error>) {
        lock.lock()
        guard !resolved, let continuation else {
            lock.unlock()
            return
        }
        resolved = true
        self.continuation = nil
        let action = cleanup
        cleanup = nil
        lock.unlock()
        continuation.resume(with: result)
        action?()
    }
}
