import OSLog
import AppKit
import CoreGraphics
import CUShared
import Foundation

/// Foreground mode: agent acts on whatever is in the foreground for the
/// user. Presentation (dim mask, blue bubble HUD, observe-exit notice) is
/// owned by `AgentPresentationCoordinator`, adapted from the legacy
/// ComputerUse stack. Cursor animation stays on
/// `CUShared.DaemonCursor` so background and foreground share the same
/// overlay sprite and bezier motion.
@MainActor
public final class ForegroundModeRuntime: ModeRuntime {
    public var supportsIntervention: Bool {
        true
    }

    private let presentation: AgentPresentationCoordinator
    private let stateMachine: StateMachine
    private let interventionDetector: InterventionDetector
    private let recoveryMonitor: RecoveryMonitor
    private let observer: ObserverManager
    private var startArgs: ForegroundStartArgs = .init()
    private var exitRequested = false

    public init() {
        presentation = AgentPresentationCoordinator()
        stateMachine = StateMachine()
        interventionDetector = InterventionDetector()
        recoveryMonitor = RecoveryMonitor()
        observer = ObserverManager()
    }

    static let diagnostics = Logger(subsystem: "surf.comma.computer-use", category: "foreground")

    public func activate(payload: SessionControl) async throws {
        if let foreground = payload.foreground {
            startArgs = foreground
        }

        // 0. If the caller passed `apps`, hide every other regular app so
        //    the agent is operating on a clean workspace. Snapshot is
        //    written to disk so a crashed session can be recovered via
        //    `ComputerUse recover`. Restored on `deactivate()` below.
        AppWorkspaceIsolation.isolate(apps: startArgs.apps)

        // 0.5 Wire the per-frame warp hook so the REAL (hidden) system
        //     cursor tracks the sprite during bezier animation. Without
        //     this the cursor stays at the pre-animation location while
        //     the sprite eases toward the target; an intervention mid-
        //     animation would then hand the user a cursor that's
        //     nowhere near where they just saw the sprite stop.
        //
        //     Move via CGEvent.post with COMPUTER_USE_EVENT_TAG (not
        //     CGWarpMouseCursorPosition alone). Reason: on macOS 14+,
        //     `CGWarpMouseCursorPosition` emits an untagged mouseMoved
        //     through the session event tap, which `InterventionDetector`
        //     then classifies as user mouse intervention and pauses the
        //     session on the first bezier frame. A tagged event is
        //     skipped by the detector AND moves the cursor when posted.
        DaemonCursor.shared.onPoseApplied = { [weak self] appKitPoint in
            let bridgeHeight = DesktopCoordinateSpace.desktopMaxY()
            let quartz = CGPoint(x: appKitPoint.x, y: bridgeHeight - appKitPoint.y)
            let clamped = clampToDesktop(quartz)
            postTaggedMouseMoved(at: clamped)
            // Keep the HUD bubble anchored to the sprite on the same
            // main-actor turn as the warp, not via the bubble's own
            // display-link task (which piles up behind `pump` loops).
            MainActor.assumeIsolated {
                self?.presentation.nudgeHUD()
            }
        }

        // 1. Bring up the dim mask + HUD via the presentation coordinator.
        //    DimmedWorkspace paints a dark overlay below the focused window
        //    so the user can still see what the agent is acting on;
        //    everything else is visually muted. HUD starts in the default
        //    "Agent is operating…" state.
        presentation.beginSession()

        // 2. Bring up the observer if the host supplied an observer bridge.
        //    Without an explicit bridge socket the observer is a no-op.
        observer.updateConfiguration(.fromStartArgs(startArgs.observer))
        observer.onSummary = { [weak self] text in
            MainActor.assumeIsolated {
                self?.presentation.updateObservation(text)
            }
        }
        observer.onError = { error in
            FileHandle.standardError.write(Data("[observer] \(error)\n".utf8))
        }
        observer.start()

        // 3. Wire the state machine + intervention/recovery detectors so
        //    user activity pauses the agent and post-intervention idleness
        //    resumes it.
        Self.diagnostics.notice("state=active pid=\(ProcessInfo.processInfo.processIdentifier)")
        stateMachine.transitionToActive()
        interventionDetector.stateMachine = stateMachine
        interventionDetector.onIntervention = { [weak self] type in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Marker goes where OUR sprite currently is, including
                // mid-animation — that's the position the user has to
                // bring their cursor back to in order to resume. The
                // InterventionDetector populated `pausedIntervention`
                // with the user's event.location (Quartz), which is
                // where THEY are, not where we are; overwrite the
                // context so RecoveryMonitor anchors on the sprite too.
                let appKit = DaemonCursor.shared.currentPoseAppKitScreenPoint
                let markerQuartz = CGPoint(
                    x: appKit.x,
                    y: DesktopCoordinateSpace.desktopMaxY() - appKit.y
                )
                self.stateMachine.transitionToPaused(
                    PausedInterventionContext(
                        type: type,
                        cursor: PausedCursorLocation(display: 0, x: 0, y: 0),
                        screenPoint: markerQuartz
                    )
                )
                // If a click/drag was animating, bail it out so the
                // body closure (CGEvent post) doesn't fire — the agent
                // should learn about the intervention, not commit a
                // click the user just interrupted.
                DaemonCursor.shared.requestStopAnimation()
                self.handleInterventionPaused(at: markerQuartz)
            }
        }
        interventionDetector.onExitRequested = { [weak self] in
            MainActor.assumeIsolated {
                self?.requestExit()
            }
        }
        recoveryMonitor.stateMachine = stateMachine
        recoveryMonitor.onRecovery = { [weak self] in
            MainActor.assumeIsolated {
                self?.handleRecovered()
            }
        }
        interventionDetector.start()
    }

    /// ESC-while-paused handler. Tears the session down through
    /// `SessionRegistry` so the daemon's `active` slot clears and subsequent
    /// `action` calls from the agent return "no active session". Deferred via
    /// `Task` so teardown doesn't re-enter the CGEvent tap dispatch that
    /// triggered it (same pattern legacy `CommandHandler.requestExit` used).
    private func requestExit() {
        guard !exitRequested else { return }
        exitRequested = true
        Task { @MainActor in
            SessionRegistry.shared.deactivateIfActive()
        }
    }

    public func deactivate() {
        Self.diagnostics.notice("state=idle session_deactivated")
        interventionDetector.onExitRequested = nil
        interventionDetector.stop()
        recoveryMonitor.stopMonitoring()
        observer.stop()
        stateMachine.transitionToIdle()
        presentation.endSession()
        // Drop the warp hook FIRST so the next `tearDown`'s applyPose
        // (if any) doesn't fire a ghost warp. Also so a subsequent
        // background-mode session on the same daemon doesn't inherit
        // the foreground hook and start warping the user's cursor.
        DaemonCursor.shared.onPoseApplied = nil
        DaemonCursor.shared.tearDown()
        // Unhide whatever we hid in `activate()`; no-op if `--apps` was
        // empty (no snapshot was written).
        AppWorkspaceIsolation.restore()
    }

    private func handleInterventionPaused(at screenPoint: CGPoint) {
        Self.diagnostics.notice("state=paused marker_x=\(screenPoint.x) marker_y=\(screenPoint.y)")
        // Visually switch to the "observing" appearance so the user can
        // tell the agent stepped back; recovery monitor watches for the
        // pointer to settle before resuming.
        presentation.beginObserving(at: screenPoint)
        recoveryMonitor.startMonitoring()
        // Kick off Observer: periodic screenshots + host-provided summaries.
        // during the intervention window.
        observer.beginRound()
    }

    private func handleRecovered() {
        recoveryMonitor.stopMonitoring()
        Self.diagnostics.notice("state=active pid=\(ProcessInfo.processInfo.processIdentifier)")
        stateMachine.transitionToActive()
        presentation.finishObservation()
        // Request the detailed final summary; the HUD is updated from
        // `observer.onSummary` when the backend responds.
        Task { [weak self] in
            _ = await self?.observer.endRoundAndRequestFinal()
            await MainActor.run {
                self?.presentation.finishObserveSummary()
            }
        }
    }

    public func dispatch(args: [String]) async -> DaemonResponse {
        // Block actions while the user is intervening; surface a clear
        // error so the agent knows to back off rather than retry blindly.
        if stateMachine.isPaused {
            Self.diagnostics.info("dispatch_rejected reason=paused")
            return .failure("session paused (user intervention detected); will auto-resume when user idles")
        }
        do {
            let command = try ForegroundParser.parse(args)
            let output = try await ForegroundExecutor.execute(command, presentation: presentation)
            return .success(output.text)
        } catch is DaemonCursor.Interrupted {
            // Approach animation bailed out because the user intervened
            // mid-move. The action body (CGEvent post) did NOT fire.
            // Surface that to the agent so it knows the command was not
            // committed — matching legacy's `interventionNotice` flow.
            return .failure("action cancelled by user intervention; will auto-resume when user returns to marker")
        } catch let error as ForegroundCLIError {
            switch error {
            case let .helpRequested(text):
                return .success(text)
            default:
                return .failure("\(error)")
            }
        } catch {
            return .failure("\(error)")
        }
    }
}
