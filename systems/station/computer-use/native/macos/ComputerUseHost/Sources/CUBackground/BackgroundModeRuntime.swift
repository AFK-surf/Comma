import AppKit
import CoreGraphics
import CUShared
import Foundation
import OSLog

private let backgroundBorderLogger = Logger(
    subsystem: "surf.comma.CommaComputerUse",
    category: "BackgroundModeRuntime"
)

/// Default Computer Use runtime: runs target app windows on an isolated
/// secondary virtual desktop (`CGVirtualDisplay`) with live AI cursor overlay,
/// `ScreenCaptureKit` preview streaming, and the macOS Notch Dynamic Island HUD.
@MainActor
public final class BackgroundModeRuntime: ModeRuntime {
    private let borderOverlay: BorderOverlay
    private let virtualDesktop: VirtualDesktopManager
    private let stream: VirtualDesktopStream?
    private let notchController: NotchOverlayController?
    private var attachedWindowID: CGWindowID?
    private var preferencesWatcher: DispatchSourceFileSystemObject?
    private var preferencesWatcherFD: Int32 = -1
    private var screenParametersObserver: NSObjectProtocol?

    public init() {
        borderOverlay = BorderOverlay()
        virtualDesktop = VirtualDesktopManager()
        if #available(macOS 14.0, *) {
            stream = VirtualDesktopStream()
            notchController = NotchOverlayController()
        } else {
            stream = nil
            notchController = nil
        }
    }

    public static func shouldUseVirtualDesktop(
        explicit: Bool?,
        preferenceURL: URL = ComputerUsePreferences.preferencesURL
    ) -> Bool {
        explicit ?? ComputerUsePreferences.showInNotch(from: preferenceURL)
    }

    public func activate(payload: SessionControl) async throws {
        let args = payload.background ?? BackgroundStartArgs()
        let useVirtualDesktop = Self.shouldUseVirtualDesktop(explicit: args.virtualDesktop)
        let sessionTitle = args.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskTitle = (sessionTitle?.isEmpty == false) ? sessionTitle : nil
        let activeApp = args.apps.first

        guard useVirtualDesktop else { return }

        do {
            let vdID = try await virtualDesktop.start(initialApps: args.apps)
            let bounds = virtualDesktop.displayBounds

            if !bounds.isEmpty {
                DaemonCursor.shared.emitClickRipples = true
                DaemonCursor.shared.onPoseApplied = { pt in
                    MainActor.assumeIsolated {
                        VirtualDesktopClickRipple.shared.updateCursorBadge(at: pt, label: "Comma AI")
                    }
                }
                DaemonCursor.shared.parkOnVirtualDesktop(displayID: vdID, bounds: bounds)
            }

            if #available(macOS 14.0, *), let stream, let notchController {
                // Thumbnail-size capture; the viewer raises it to full size while open.
                await stream.start(displayID: vdID, fps: 30)
                notchController.onRestoreWindowsRequested = { [weak self] in
                    _ = self?.virtualDesktop.restoreAllWindows()
                }
                notchController.onStopRequested = { [weak self] in
                    self?.stopRequestedByUser()
                }
                notchController.show(
                    stream: stream,
                    virtualDisplayID: vdID,
                    virtualDisplayBounds: bounds,
                    taskTitle: taskTitle,
                    activeAppName: activeApp,
                    playEntrance: true
                )
            }
            startScreenParametersObserver()
            if args.virtualDesktop == nil {
                startPreferencesWatcher()
            }
        } catch {
            downgradeToPlainBackground()
            backgroundBorderLogger.warning(
                "Virtual desktop unavailable, continuing in plain background mode: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// "Stop" in the island: end this session through the registry, so the
    /// daemon's session state, the windows on the virtual desktop and the UI
    /// all end together.
    private func stopRequestedByUser() {
        if !SessionRegistry.shared.stopByUser(self) {
            // Not (or no longer) the registered session: still clean up its UI
            // and virtual desktop. `deactivate` is idempotent.
            deactivate()
        }
    }

    /// Turns off the virtual desktop and Notch island while keeping the session
    /// active in plain background mode (windows return to the main screen).
    private func downgradeToPlainBackground() {
        stopPreferencesWatcher()
        stopScreenParametersObserver()
        if #available(macOS 14.0, *) {
            notchController?.onStopRequested = nil
            notchController?.onRestoreWindowsRequested = nil
            notchController?.tearDown()
            stream?.stopSync()
        }
        DaemonCursor.shared.emitClickRipples = false
        DaemonCursor.shared.onPoseApplied = nil
        DaemonCursor.shared.tearDown()
        virtualDesktop.stop()
    }

    private func startScreenParametersObserver() {
        stopScreenParametersObserver()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenParametersChanged()
            }
        }
    }

    private func stopScreenParametersObserver() {
        if let obs = screenParametersObserver {
            NotificationCenter.default.removeObserver(obs)
            screenParametersObserver = nil
        }
    }

    private func handleScreenParametersChanged() {
        guard virtualDesktop.isActive else { return }
        switch virtualDesktop.handleScreenParametersChanged() {
        case .shouldDowngrade:
            backgroundBorderLogger.notice("Display topology changed; downgrading virtual desktop to plain background mode")
            downgradeToPlainBackground()
        case let .updated(bounds):
            if #available(macOS 14.0, *) {
                notchController?.handleScreenParametersChanged(
                    virtualDisplayID: virtualDesktop.displayID,
                    virtualDisplayBounds: bounds
                )
            }
        case .unchanged:
            if #available(macOS 14.0, *) {
                notchController?.handleScreenParametersChanged(
                    virtualDisplayID: virtualDesktop.displayID,
                    virtualDisplayBounds: virtualDesktop.displayBounds
                )
            }
        }
    }

    private func startPreferencesWatcher() {
        stopPreferencesWatcher()
        let dirURL = ComputerUsePreferences.preferencesURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let fd = open(dirURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.virtualDesktop.isActive else { return }
                if !ComputerUsePreferences.showInNotch() {
                    self.downgradeToPlainBackground()
                }
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        preferencesWatcherFD = fd
        preferencesWatcher = source
        source.resume()
    }

    private func stopPreferencesWatcher() {
        if let watcher = preferencesWatcher {
            preferencesWatcher = nil
            preferencesWatcherFD = -1
            watcher.cancel()
        } else if preferencesWatcherFD >= 0 {
            close(preferencesWatcherFD)
            preferencesWatcherFD = -1
        }
    }

    public func deactivate() {
        downgradeToPlainBackground()
        borderOverlay.detach()
        attachedWindowID = nil
    }

    public func recordThinking(_ text: String) {
        if #available(macOS 14.0, *) {
            notchController?.recordStatus(text)
        }
    }

    public func dispatch(args: [String]) async -> DaemonResponse {
        if virtualDesktop.isActive, preferencesWatcher != nil, !ComputerUsePreferences.showInNotch() {
            downgradeToPlainBackground()
        }
        do {
            let command = try ComputerUseCLI.parse(arguments: args)
            if #available(macOS 14.0, *) {
                recordCommandSummaryIfNeeded(command)
            }
            if let preWindowID = resolveWindowID(forCommand: command) {
                attachBorder(for: preWindowID, reason: "pre-action")
            }
            let output = try execute(command: command)
            if let post = output.metadata {
                attachBorder(for: CGWindowID(post.windowID), reason: "post-action")
                if #available(macOS 14.0, *) {
                    notchController?.setActiveApp(post.appName)
                }
            }
            return .success(output.text)
        } catch {
            return .failure("\(error)")
        }
    }

    // MARK: - Action dispatch

    private func execute(command: ComputerUseCLICommand) throws -> ComputerUseCommandOutput {
        switch command {
        case .listApps:
            return ComputerUseAction.listApps()
        case let .getAppState(app, title):
            if virtualDesktop.isActive {
                virtualDesktop.migrateApps(named: [app], preferredWindowTitle: title)
            }
            return try ComputerUseAction.getAppState(
                appIdentifier: app,
                windowTitle: title
            )
        case let .click(snapshotID, elementIndex, x, y):
            return try ComputerUseAction.click(
                snapshotID: snapshotID,
                elementIndex: elementIndex,
                x: x,
                y: y
            )
        case let .typeText(snapshotID, text, elementIndex):
            return try ComputerUseAction.typeText(
                snapshotID: snapshotID,
                text: text,
                elementIndex: elementIndex
            )
        case let .setValue(snapshotID, elementIndex, value):
            return try ComputerUseAction.setValue(
                snapshotID: snapshotID,
                elementIndex: elementIndex,
                value: value
            )
        case let .pressKey(snapshotID, key):
            return try ComputerUseAction.pressKey(
                snapshotID: snapshotID,
                key: key
            )
        case let .scroll(snapshotID, elementIndex, direction, pages):
            return try ComputerUseAction.scroll(
                snapshotID: snapshotID,
                elementIndex: elementIndex,
                direction: direction,
                pages: pages
            )
        case let .performSecondaryAction(snapshotID, elementIndex, action):
            return try ComputerUseAction.performSecondaryAction(
                snapshotID: snapshotID,
                elementIndex: elementIndex,
                action: action
            )
        case let .drag(snapshotID, fromX, fromY, toX, toY):
            return try ComputerUseAction.drag(
                snapshotID: snapshotID,
                fromX: fromX,
                fromY: fromY,
                toX: toX,
                toY: toY
            )
        case let .permissions(permAction):
            if permAction == .status {
                return ComputerUseCommandOutput(
                    text: SessionRegistry.shared.permissionsStatusJSON()
                )
            }
            guard let bridge = DaemonPermissionBridge.shared else {
                throw ComputerUseError.invalidArgument(
                    "permission authorization UI is unavailable in this host"
                )
            }
            let head = bridge.showAuthorizationUI()
            let tail = "Poll status with: ComputerUse permissions status"
            return ComputerUseCommandOutput(text: "\(head)\n\(tail)")
        }
    }

    /// Puts the action about to run on the island's status line, named from
    /// the snapshot it acts on (element title or role, and app).
    @available(macOS 14.0, *)
    private func recordCommandSummaryIfNeeded(_ command: ComputerUseCLICommand) {
        guard let notchController else { return }
        var target = snapshotID(of: command)
            .flatMap { try? ComputerUseSnapshotStore.load(snapshotID: $0) }
            .map(NotchActivityText.Target.init(metadata:))
        if case let .getAppState(app, _) = command,
           let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == app }),
           let name = running.localizedName {
            // The agent may name the app by bundle id; show its display name.
            target = NotchActivityText.Target(appName: name, elements: [])
        }
        guard let line = NotchActivityText.describe(command, target: target) else { return }
        notchController.recordStatus(line, appName: target?.appName)
    }

    // MARK: - Border lifecycle

    private func attachBorder(for windowID: CGWindowID, reason: String) {
        if windowID != attachedWindowID {
            let previousWindowID = attachedWindowID.map(String.init) ?? "none"
            backgroundBorderLogger.info(
                "border switch (\(reason, privacy: .public)): \(previousWindowID, privacy: .public) -> \(windowID, privacy: .public)"
            )
        }
        attachedWindowID = windowID
        borderOverlay.attach(toCGWindow: windowID)
    }

    private func resolveWindowID(forCommand command: ComputerUseCLICommand) -> CGWindowID? {
        guard let snapshotID = snapshotID(of: command) else { return nil }
        guard let windowID = BackgroundSnapshotLookup.cgWindowID(forSnapshot: snapshotID) else {
            backgroundBorderLogger.warning(
                "pre-action lookup skipped: snapshot \(snapshotID, privacy: .public) did not resolve to a CGWindowID"
            )
            return nil
        }
        return windowID
    }

    private func snapshotID(of command: ComputerUseCLICommand) -> String? {
        switch command {
        case let .click(id, _, _, _),
             let .typeText(id, _, _),
             let .setValue(id, _, _),
             let .pressKey(id, _),
             let .scroll(id, _, _, _),
             let .performSecondaryAction(id, _, _),
             let .drag(id, _, _, _, _):
            id
        case .listApps, .getAppState, .permissions:
            nil
        }
    }
}
