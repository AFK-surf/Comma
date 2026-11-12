import AppKit
import CoreGraphics
@_exported import CUShared

/// Foreground-mode presentation: orchestrates the dim workspace, HUD (blue
/// bubble), cursor overlay, and observe-exit notice.
///
/// Cursor ownership mirrors legacy ComputerUse: during `.following` the
/// system cursor is hidden and a follower sprite tracks `CGEvent.location`
/// off a CVDisplayLink; on intervention it flips to `.marker` at the
/// paused point and returns system-cursor control to the user, so the user
/// can see both where they are and where the AI paused. Per-action
/// approach animations stay on `CUShared.DaemonCursor`, which materializes
/// its own overlay on top while it's animating.
@MainActor
final class AgentPresentationCoordinator {
    private let cursorOverlay: AgentCursorOverlay
    private let hudController: AgentHUDController
    private let observeExitNotice: ObserveExitNoticeController

    private static let activeAppearance = Appearance(
        opacity: 0.7,
        showColorfulBorder: true,
        colorfulBorderAmplitude: 1.0
    )

    private static let pausedAppearance = Appearance(
        opacity: 0.4,
        showColorfulBorder: true,
        colorfulBorderAmplitude: 0.0
    )

    init() {
        cursorOverlay = AgentCursorOverlay()
        hudController = AgentHUDController()
        observeExitNotice = ObserveExitNoticeController()
    }

    /// Enter foreground presentation: dim mask up, system cursor hidden,
    /// agent sprite (DaemonCursor) parked at the current system cursor
    /// position so the first action's bezier starts from where the real
    /// cursor is right now, HUD reset, exit notice hidden.
    func beginSession() {
        DimmedWorkspace.appearance = Self.activeAppearance
        DimmedWorkspace.activate()
        cursorOverlay.activate()
        let cursor = CGEvent(source: nil)?.location ?? .zero
        DaemonCursor.shared.syncPose(toScreenPoint: cursor)
        DaemonCursor.shared.showPanel()
        observeExitNotice.hide()
        hudController.resetAgentOperating()
    }

    /// Transition to "observing" (user intervention detected): switch
    /// the dim appearance, hide the agent sprite (so the user sees only
    /// their real cursor + the pink marker), drop a marker at the paused
    /// point, pin the HUD near the cursor, surface the exit notice.
    func beginObserving(at screenPoint: CGPoint, initialText: String = "Observing your actions...") {
        DimmedWorkspace.appearance = Self.pausedAppearance
        DaemonCursor.shared.hidePanel()
        cursorOverlay.show(at: screenPoint)
        observeExitNotice.show(near: screenPoint)
        hudController.startObserving(
            initialText: initialText,
            anchoredAt: DesktopCoordinateSpace.appKitPoint(fromScreenPoint: screenPoint)
        )
    }

    func updateObservation(_ text: String) {
        hudController.updateObservation(text)
    }

    @discardableResult
    func updateThinking(_ text: String) -> Bool {
        hudController.updateAgentOperatingText(text)
    }

    @discardableResult
    func beginActionThinking(_ text: String) -> Bool {
        hudController.beginTemporaryAgentOperatingText(text)
    }

    func endActionThinking() {
        hudController.endTemporaryAgentOperatingText()
    }

    func finishObservation() {
        DimmedWorkspace.appearance = Self.activeAppearance
        cursorOverlay.activate()
        // `RecoveryMonitor` warped the system cursor back to the paused
        // point before firing onRecovery; resync the agent sprite there
        // so the next action's bezier starts from the user's hand-off
        // point instead of wherever the last action landed.
        let cursor = CGEvent(source: nil)?.location ?? .zero
        DaemonCursor.shared.syncPose(toScreenPoint: cursor)
        DaemonCursor.shared.showPanel()
        observeExitNotice.hide()
        hudController.startObserveSummary()
    }

    func finishObserveSummary() {
        hudController.resetAgentOperating()
    }

    func showAgentOperatingHUD() {
        hudController.showCurrentAgentOperating()
    }

    /// Tear down all foreground overlays. Call on session end / deactivate.
    func endSession() {
        cursorOverlay.deactivate()
        observeExitNotice.hide()
        hudController.hide()
        DimmedWorkspace.deactivate()
    }

    /// Synchronously reposition the HUD bubble against whatever
    /// `DaemonCursor.currentPoseAppKitScreenPoint` reads right now.
    /// Called from `ForegroundModeRuntime`'s `onPoseApplied` hook so
    /// the bubble tracks the sprite frame-by-frame instead of lagging
    /// on the CVDisplayLink task queue.
    func nudgeHUD() {
        hudController.nudge()
    }
}
