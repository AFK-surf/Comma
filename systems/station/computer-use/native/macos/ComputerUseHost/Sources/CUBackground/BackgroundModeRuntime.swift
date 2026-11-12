import CoreGraphics
import CUShared
import Foundation
import OSLog

private let backgroundBorderLogger = Logger(
    subsystem: "surf.comma.CommaComputerUse",
    category: "BackgroundModeRuntime.Border"
)

/// Background mode: snapshot-driven, per-window automation. Runs alongside
/// the user (no app hiding, no dim mask, no system cursor hide).
///
/// Border lifecycle:
///   - First action that resolves a target window (get_app_state on a new
///     window, or any action carrying a snapshot_id) pins the colorful
///     border around that window.
///   - Subsequent actions on the same window refresh the border's frame in
///     place (no fade-out/fade-in blink) so the halo stays continuous even
///     if the user drags the window between actions.
///   - Switching to a different target window repositions the single border
///     onto the new window's frame.
///   - Actions without a target window (list_apps, permissions) leave the
///     border pinned to whatever the agent is currently focused on.
///   - `deactivate()` on session end tears the border down.
@MainActor
public final class BackgroundModeRuntime: ModeRuntime {
    public var supportsIntervention: Bool {
        false
    }

    private let borderOverlay: BorderOverlay
    private var attachedWindowID: CGWindowID?

    public init() {
        borderOverlay = BorderOverlay()
    }

    public func activate(payload _: SessionControl) async throws {
        // Background mode is lazy — overlays appear on the first action.
    }

    public func deactivate() {
        borderOverlay.detach()
        attachedWindowID = nil
        DaemonCursor.shared.tearDown()
    }

    public func dispatch(args: [String]) async -> DaemonResponse {
        do {
            let command = try ComputerUseCLI.parse(arguments: args)
            // Pre-action: pin the border around the window referenced by
            // the command's snapshot_id (if any) so the halo is already
            // visible during the cursor approach animation.
            if let preWindowID = resolveWindowID(forCommand: command) {
                attachBorder(for: preWindowID, reason: "pre-action")
            }
            let output = try execute(command: command)
            // Post-action: the action's freshly settled snapshot is the
            // authoritative "what the agent now sees". Follow it — this
            // is what keeps the border pinned across get_app_state (which
            // has no pre-action snapshot) and catches window switches.
            if let post = output.metadata {
                attachBorder(for: CGWindowID(post.windowID), reason: "post-action")
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
            ComputerUseAction.listApps()
        case let .getAppState(app, title):
            try ComputerUseAction.getAppState(
                appIdentifier: app,
                windowTitle: title
            )
        case let .click(snapshotID, elementIndex, x, y):
            try ComputerUseAction.click(
                snapshotID: snapshotID,
                elementIndex: elementIndex,
                x: x,
                y: y
            )
        case let .typeText(snapshotID, text, elementIndex):
            try ComputerUseAction.typeText(
                snapshotID: snapshotID,
                text: text,
                elementIndex: elementIndex
            )
        case let .setValue(snapshotID, elementIndex, value):
            try ComputerUseAction.setValue(
                snapshotID: snapshotID,
                elementIndex: elementIndex,
                value: value
            )
        case let .pressKey(snapshotID, key):
            try ComputerUseAction.pressKey(
                snapshotID: snapshotID,
                key: key
            )
        case let .scroll(snapshotID, elementIndex, direction, pages):
            try ComputerUseAction.scroll(
                snapshotID: snapshotID,
                elementIndex: elementIndex,
                direction: direction,
                pages: pages
            )
        case let .performSecondaryAction(snapshotID, elementIndex, action):
            try ComputerUseAction.performSecondaryAction(
                snapshotID: snapshotID,
                elementIndex: elementIndex,
                action: action
            )
        case let .drag(snapshotID, fromX, fromY, toX, toY):
            try ComputerUseAction.drag(
                snapshotID: snapshotID,
                fromX: fromX,
                fromY: fromY,
                toX: toX,
                toY: toY
            )
        case let .permissions(action):
            try handlePermissions(action)
        }
    }

    private func handlePermissions(_ action: PermissionAction) throws -> ComputerUseCommandOutput {
        switch action {
        case .status:
            let report = PermissionStatusProbe.report()
            let payload = try JSONEncoder().encode(report)
            let json = String(data: payload, encoding: .utf8) ?? ""
            return ComputerUseCommandOutput(text: report.pretty() + "\n---\n" + json)
        case .openUI:
            guard let bridge = DaemonPermissionBridge.shared else {
                throw ComputerUseError.invalidArgument(
                    "permission bridge unavailable; daemon was launched without the authorization UI"
                )
            }
            let head = bridge.showAuthorizationUI()
            let tail = "Poll status with: ComputerUse permissions status"
            return ComputerUseCommandOutput(text: "\(head)\n\(tail)")
        }
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
