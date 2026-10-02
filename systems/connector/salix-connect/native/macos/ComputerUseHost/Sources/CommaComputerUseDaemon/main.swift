import AppKit
import CUBackground
import CUForeground
import CUShared
import Darwin
import Foundation

if #available(macOS 14.0, *) {
    MainActor.assumeIsolated {
        if CommandLine.arguments.contains("--prepare-app") {
            do {
                print(try StandaloneApplication.prepare().path)
            } catch {
                fputs("Could not install Comma Computer Use: \(error)\n", stderr)
                exit(1)
            }
        } else if StandaloneApplication.isNested(Bundle.main.bundleURL) {
            fputs("Run --prepare-app and open the returned application before using Computer Use.\n", stderr)
            exit(1)
        } else if CommandLine.arguments.contains("--permissions-status") {
            do {
                let response = CommaComputerUseResponse.success(permissions: commaPermissionInfo())
                let data = try JSONEncoder().encode(response)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            } catch {
                fputs("Could not encode permission status.\n", stderr)
                exit(1)
            }
        } else {
            startCommaComputerUseDaemon()
        }
    }
} else {
    fputs("CommaComputerUseDaemon requires macOS 14 or newer.\n", stderr)
    exit(1)
}

@available(macOS 14.0, *)
@MainActor
private func startCommaComputerUseDaemon() {
    signal(SIGPIPE, SIG_IGN)

    let app = NSApplication.shared
    let delegate = CommaComputerUseDaemonAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

@available(macOS 14.0, *)
@MainActor
private final class CommaComputerUseDaemonAppDelegate: NSObject, NSApplicationDelegate {
    private var socketServer: CommaComputerUseSocketServer?
    private var permissionWindow: PermissionAuthWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let authToken = commaComputerUseAuthToken(environment: environment)
        if CommandLine.arguments.contains("--permissions-ui") {
            let window = PermissionAuthWindowController()
            window.onClose = { NSApplication.shared.terminate(nil) }
            permissionWindow = window
            window.show()
            return
        }
        let socketPath = commaComputerUseSocketPath(environment: environment)
        guard !authToken.isEmpty else {
            fputs("Failed to start daemon: COMMA_COMPUTER_USE_AUTH_TOKEN is required.\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }

        DaemonPermissionBridge.shared = PermissionFlowBridge()
        SessionRegistry.shared.registerBackground(
            factory: { BackgroundModeRuntime() },
            help: ComputerUseCLI.agentUsage
        )
        SessionRegistry.shared.registerForeground(
            factory: { ForegroundModeRuntime() },
            help: ForegroundParser.agentUsage
        )

        let socketServer = CommaComputerUseSocketServer(socketPath: socketPath, authToken: authToken)
        self.socketServer = socketServer
        socketServer.onShutdownRequested = { [weak self] in
            self?.shutdown()
        }
        socketServer.onRequest = { [weak self] request in
            guard let self else { return .failure("Daemon shutting down") }
            return await self.handle(request)
        }

        do {
            try socketServer.start()
        } catch {
            fputs("Failed to start daemon: \(error)\n", stderr)
            NSApplication.shared.terminate(nil)
        }

        signal(SIGTERM) { _ in
            DispatchQueue.main.async {
                (NSApplication.shared.delegate as? CommaComputerUseDaemonAppDelegate)?.shutdown()
            }
        }

        signal(SIGINT) { _ in
            DispatchQueue.main.async {
                (NSApplication.shared.delegate as? CommaComputerUseDaemonAppDelegate)?.shutdown()
            }
        }
    }

    private func handle(_ request: CommaComputerUseRequest) async -> CommaComputerUseResponse {
        switch request.kind {
        case let .control(control):
            return handleControl(control)
        case let .action(action):
            return await handleAction(action, display: request.display, thinking: request.thinking)
        }
    }

    private func handleControl(_ control: String) -> CommaComputerUseResponse {
        switch control.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "hello":
            return .success(message: "comma-computer-use-daemon")

        case "open-permission-flow":
            let message = SessionRegistry.shared.openPermissionFlow()
            return .success(message: message, permissions: commaPermissionInfo())

        case "permissions-status":
            return .success(text: permissionStatusText(), permissions: commaPermissionInfo())

        case "shutdown":
            return .success()

        default:
            return .failure("Unsupported computer_use control: \(control)")
        }
    }

    private func handleAction(
        _ action: CommaComputerUseAction,
        display: Int?,
        thinking: String?
    ) async -> CommaComputerUseResponse {
        switch action.name {
        case "start":
            let mode = action.string("mode").flatMap(ModeKind.init(rawValue:)) ?? .foreground
            let apps = action.stringArray("apps")
            let control = SessionControl(
                op: .start,
                mode: mode,
                foreground: mode == .foreground
                    // TODO(COMMA-46): wire the board observer proxy through salix-connect
                    // so foreground mode can request visual summaries without depending
                    // on the Electron app process.
                    ? ForegroundStartArgs(apps: apps, display: display, observer: nil)
                    : nil,
                background: mode == .background ? BackgroundStartArgs() : nil
            )
            return await commaResponse(from: SessionRegistry.shared.handle(session: control))

        case "end", "stop":
            return await commaResponse(
                from: SessionRegistry.shared.handle(session: SessionControl(op: .stop))
            )

        case "status":
            return .success(text: SessionRegistry.shared.sessionStatusJSON(), permissions: commaPermissionInfo())

        case "permissions_status":
            return .success(text: permissionStatusText(), permissions: commaPermissionInfo())

        case "mode_help":
            let mode = action.string("mode").flatMap(ModeKind.init(rawValue:)) ?? .foreground
            if let help = SessionRegistry.shared.helpText(for: mode) {
                return .success(text: help)
            }
            return .failure("No help registered for mode=\(mode.rawValue)")

        default:
            do {
                let argv = try commaArgv(for: action, display: display, thinking: thinking)
                return await commaResponse(from: SessionRegistry.shared.handle(action: argv))
            } catch {
                return .failure("\(error)")
            }
        }
    }

    private func commaResponse(from response: DaemonResponse) -> CommaComputerUseResponse {
        if response.ok {
            return CommaComputerUseResponse.fromDaemonText(response.text)
        }
        return .failure(response.error ?? response.text ?? "computer_use failed")
    }

    private func permissionStatusText() -> String {
        PermissionStatusProbe.report().pretty()
    }

    fileprivate func shutdown() {
        socketServer?.stop()
        SessionRegistry.shared.deactivateIfActive()
        DaemonCursor.shared.tearDown()
        NSApplication.shared.terminate(nil)
    }
}

private func commaComputerUseSocketPath(environment: [String: String]) -> String {
    if let path = environment["COMMA_COMPUTER_USE_SOCKET_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !path.isEmpty {
        return path
    }
    return NSTemporaryDirectory()
        .appending("comma-computer-use")
        .appending("/")
        .appending("computeruse.sock")
}

private func commaComputerUseAuthToken(environment: [String: String]) -> String {
    environment["COMMA_COMPUTER_USE_AUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func commaPermissionInfo() -> CommaComputerUsePermissionInfo {
    let report = PermissionStatusProbe.report()
    var accessibility = false
    var screenRecording = false
    for status in report.statuses {
        switch status.pane {
        case .accessibility:
            accessibility = status.granted
        case .screenRecording:
            screenRecording = status.granted
        }
    }
    return CommaComputerUsePermissionInfo(
        accessibility: accessibility,
        screenRecording: screenRecording
    )
}

private func commaArgv(
    for action: CommaComputerUseAction,
    display: Int?,
    thinking: String?
) throws -> [String] {
    let name = action.name
    switch name {
    case "get_screenshot", "screenshot":
        return withDisplay(["screenshot"], display: display)
    case "get_screen_size", "screen_size":
        return withDisplay(["screen-size"], display: display)
    case "get_cursor_position", "cursor_position":
        return withDisplay(["cursor-position"], display: display)
    case "zoom":
        return try withDisplay([
            "zoom",
            "--x1", action.requiredString("x1"),
            "--y1", action.requiredString("y1"),
            "--x2", action.requiredString("x2"),
            "--y2", action.requiredString("y2"),
        ], display: display)
    case "click", "left_click", "right_click", "middle_click":
        var argv = try [
            "click",
            "--x", action.requiredString("x"),
            "--y", action.requiredString("y"),
            "--button", mouseButton(for: name),
        ]
        if let count = action.string("count") {
            argv += ["--count", count]
        }
        return withDisplay(argv, display: display)
    case "double_click":
        return try withDisplay([
            "click",
            "--x", action.requiredString("x"),
            "--y", action.requiredString("y"),
            "--button", "left",
            "--count", "2",
        ], display: display)
    case "triple_click":
        return try withDisplay([
            "click",
            "--x", action.requiredString("x"),
            "--y", action.requiredString("y"),
            "--button", "left",
            "--count", "3",
        ], display: display)
    case "mouse_move":
        return try withDisplay([
            "mouse-move",
            "--x", action.requiredString("x"),
            "--y", action.requiredString("y"),
        ], display: display)
    case "left_click_drag":
        return try withDisplay([
            "drag",
            "--from-x", action.requiredString("from_x"),
            "--from-y", action.requiredString("from_y"),
            "--to-x", action.requiredString("to_x"),
            "--to-y", action.requiredString("to_y"),
            "--button", "left",
        ], display: display)
    case "drag":
        return try withDisplay([
            "drag",
            "--from-x", action.requiredString("from_x"),
            "--from-y", action.requiredString("from_y"),
            "--to-x", action.requiredString("to_x"),
            "--to-y", action.requiredString("to_y"),
            "--button", action.optionalString("button") ?? "left",
        ], display: display)
    case "left_mouse_down":
        return try withDisplay([
            "mouse-down",
            "--x", action.requiredString("x"),
            "--y", action.requiredString("y"),
            "--button", "left",
        ], display: display)
    case "left_mouse_up":
        return try withDisplay([
            "mouse-up",
            "--x", action.requiredString("x"),
            "--y", action.requiredString("y"),
            "--button", "left",
        ], display: display)
    case "scroll":
        return try withDisplay([
            "scroll",
            "--x", action.requiredString("x"),
            "--y", action.requiredString("y"),
            "--direction", action.requiredString("direction"),
            "--amount", action.optionalString("amount") ?? "3",
        ], display: display)
    case "key":
        return try ["press-key", "--key", action.requiredString("combo")]
    case "type":
        return try ["type-text", "--text", action.requiredString("text")]
    case "hold_key":
        return try [
            "hold-key",
            "--key", action.requiredString("key"),
            "--seconds", action.requiredString("duration"),
        ]
    case "wait", "wait_action":
        return ["wait", "--seconds", action.optionalString("duration") ?? "1"]
    case "focus":
        return try ["focus", "--app", action.requiredString("app")]
    case "thinking":
        return [
            "thinking",
            "--text", action.optionalString("text") ?? thinking ?? "",
        ]
    case "list_applications", "list-applications":
        return ["list-applications"]
    case "list_windows", "list-windows":
        return ["list-windows"]
    default:
        throw CommaComputerUseRequestError("unsupported computer_use action \(name)")
    }
}

private func mouseButton(for actionName: String) -> String {
    switch actionName {
    case "right_click":
        return "right"
    case "middle_click":
        return "middle"
    default:
        return "left"
    }
}

private func withDisplay(_ argv: [String], display: Int?) -> [String] {
    // Board foreground runtime currently operates on the main display.
    // Keep accepting display in the outer protocol so the Go/Electron contract
    // remains stable while multi-display support is ported.
    argv
}
