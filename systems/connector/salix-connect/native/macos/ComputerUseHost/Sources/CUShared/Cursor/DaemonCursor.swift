import AppKit
import CoreGraphics
import Foundation

/// The single, long-lived overlay cursor owned by the daemon.
///
/// State model mirrors demo/mouse-pose-demo.js:
/// - Pose is stored as AppKit screen point (for panel placement) plus a
///   canvas-style heading (y-down CCW). The view applies
///   `canvasTheta + cursorBaseRotation` as its rotation, so at rest
///   (`canvasTheta == cursorDockHeading`) the sprite is un-rotated.
/// - The bezier planner works in canvas coords; we flip y once at the
///   boundary when building the plan and once when mapping samples back
///   onto the AppKit screen.
@MainActor
public final class DaemonCursor {
    public static let shared = DaemonCursor()

    private let size = CGSize(width: 160, height: 160)
    private var panel: ActionOverlayPanel?
    private var view: ActionOverlayCursorView?
    private var currentAnchor: CursorAnchor?
    private var materialized = false

    private var poseScreen: CGPoint = .zero
    private var poseCanvasTheta: CGFloat = ActionOverlayApproachConstants.cursorDockHeading
    private var hasAnimatedApproachOnce = false
    private var stopRequested: Bool = false

    private let planner = ActionOverlayBezierPlanner.default

    private init() {}

    // MARK: - Public API

    public func runApproachThenAction(
        kind: ActionOverlayKind,
        target: CursorAnchor,
        fallbackScreenPoint: CGPoint,
        fallbackWindowFrame: CGRect,
        tracking: ActionOverlayTracking,
        perform body: () throws -> Void
    ) throws {
        stopRequested = false
        _ = ActionOverlayRuntime.prepareAppKit()
        ensureMaterialized(target: target, fallbackWindowFrame: fallbackWindowFrame)

        if kind.usesApproachAnimation {
            try animateApproach(
                tracking: tracking,
                fallbackTargetScreen: fallbackScreenPoint
            )
        } else {
            let target = tracking.resolvePlacement()?.screenPoint ?? fallbackScreenPoint
            applyPose(screenPoint: target, canvasTheta: ActionOverlayApproachConstants.cursorDockHeading)
        }

        ActionOverlayRuntime.pump(for: ActionOverlayTiming.postApproachDwell)

        try body()

        ActionOverlayRuntime.pump(for: ActionOverlayTiming.finalHold)
    }

    public func runApproachThenDrag(
        button _: MouseButton,
        target: CursorAnchor,
        startScreenPoint: CGPoint,
        endScreenPoint: CGPoint,
        fallbackWindowFrame: CGRect,
        approachTracking: ActionOverlayTracking,
        onDragDown: () throws -> Void,
        onDragMove: (CGPoint, CGFloat) throws -> Void,
        onDragUp: (CGPoint) throws -> Void
    ) throws {
        stopRequested = false
        _ = ActionOverlayRuntime.prepareAppKit()
        ensureMaterialized(target: target, fallbackWindowFrame: fallbackWindowFrame)
        try animateApproach(
            tracking: approachTracking,
            fallbackTargetScreen: startScreenPoint
        )

        ActionOverlayRuntime.pump(for: ActionOverlayTiming.postApproachDwell)

        try onDragDown()

        let dragCanvasTheta = ActionOverlayApproachConstants.cursorDockHeading

        let duration = ActionOverlayTiming.dragDuration
        let step = max(ActionOverlayTiming.dragStep, 0.001)
        let startedAt = ProcessInfo.processInfo.systemUptime

        var lastPoint = startScreenPoint
        do {
            while true {
                if stopRequested {
                    stopRequested = false
                    throw Interrupted()
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                let progress = duration > 0 ? min(1, CGFloat(elapsed / duration)) : 1
                let eased = easeInOut(progress)
                let point = CGPoint(
                    x: startScreenPoint.x + (endScreenPoint.x - startScreenPoint.x) * eased,
                    y: startScreenPoint.y + (endScreenPoint.y - startScreenPoint.y) * eased
                )
                lastPoint = point

                applyPose(screenPoint: point, canvasTheta: dragCanvasTheta)

                try onDragMove(point, progress)

                if progress >= 1 {
                    break
                }

                ActionOverlayRuntime.pump(for: step)
            }
        } catch {
            // Down has fired; we MUST release the button before
            // propagating the error or the system stays in a pressed
            // state and subsequent clicks will misfire.
            try? onDragUp(lastPoint)
            throw error
        }

        try onDragUp(endScreenPoint)

        ActionOverlayRuntime.pump(for: ActionOverlayTiming.finalHold)
    }

    public func tearDown() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        view = nil
        currentAnchor = nil
        materialized = false
        hasAnimatedApproachOnce = false
        stopRequested = false
    }

    /// Thrown mid-animation when `requestStopAnimation()` was called
    /// (user intervened). Foreground callers catch this to drop the
    /// pending click without firing its CGEvent body.
    public struct Interrupted: Error {}

    /// AppKit-space (y-up, origin bottom-left) location of the cursor
    /// sprite's centre right now. Foreground mode reads this at
    /// intervention time so the pink marker gets anchored where the
    /// agent sprite actually is, including mid-animation.
    public var currentPoseAppKitScreenPoint: CGPoint {
        poseScreen
    }

    /// Ask any in-flight `runApproachThen…` call to bail out on its
    /// next frame check and throw `Interrupted`. The `body` closure
    /// does NOT fire for a stopped approach; for `runApproachThenDrag`,
    /// if the mouse button has already been pressed, the caller is
    /// responsible for posting the matching up event before rethrowing.
    public func requestStopAnimation() {
        stopRequested = true
    }

    /// Fired every time the sprite's pose changes — both during bezier
    /// animation and when `syncPose` / `applyPose` nudges it to a new
    /// place. The point is in AppKit screen space (y-up, origin at the
    /// bottom-left of the primary display, same space `applyPose` uses).
    ///
    /// Foreground mode sets this so the real system cursor follows the
    /// sprite frame-by-frame: if the user intervenes mid-animation, the
    /// hidden system cursor is already at the sprite's current position,
    /// so there's no jump between "where the sprite is" and "where the
    /// user's cursor takes over from" once the cursor un-hides.
    /// Background mode leaves it `nil`.
    public var onPoseApplied: (@Sendable (CGPoint) -> Void)?

    /// Foreground-mode helpers: let the host reposition the cursor
    /// sprite to an arbitrary screen point before an action runs.
    ///
    /// In foreground mode the daemon hides the real system cursor, so
    /// this sprite is the ONLY cursor the user sees. To avoid the
    /// bezier animation starting from yesterday's last-action endpoint
    /// (which looks teleporty after an intervention+recovery), the
    /// foreground executor calls `syncPose(toScreenPoint:)` with
    /// `CGEvent.location` just before each `runApproachThen…`, so the
    /// approach bezier always starts from where the real cursor is now.
    /// First call materializes the panel; later calls just move it.
    public func syncPose(toScreenPoint screenPoint: CGPoint) {
        ensureMaterialized(
            target: .display(screenID: CGMainDisplayID()),
            fallbackWindowFrame: .zero
        )
        applyPose(
            screenPoint: screenPoint,
            canvasTheta: ActionOverlayApproachConstants.cursorDockHeading
        )
        // Reset the "first approach" flag so the next animation starts
        // at dock-heading rather than inferring from a stale pose.
        hasAnimatedApproachOnce = false
    }

    /// Temporarily take the panel off-screen without destroying state.
    /// Foreground uses this when an intervention switches to observe
    /// mode: the user needs their real system cursor back and the pink
    /// marker overlay takes over; leaving our sprite visible alongside
    /// would double-draw.
    public func hidePanel() {
        panel?.orderOut(nil)
    }

    /// Inverse of `hidePanel()` — re-orders the existing panel front at
    /// the current pose. Does nothing if not materialized.
    public func showPanel() {
        guard let panel else { return }
        panel.orderFrontRegardless()
    }

    // MARK: - Private

    private func ensureMaterialized(
        target: CursorAnchor,
        fallbackWindowFrame: CGRect
    ) {
        if materialized {
            applyAnchor(target)
            return
        }

        let initialScreenPoint: CGPoint = switch target {
        case .window:
            actionOverlayBottomLeftScreenPoint(
                forWindowFrame: fallbackWindowFrame
            )
        case let .display(screenID):
            actionOverlayBottomLeftScreenPoint(forScreenID: screenID)
        }
        poseScreen = initialScreenPoint
        poseCanvasTheta = ActionOverlayApproachConstants.cursorDockHeading

        let newView = ActionOverlayCursorView(
            frame: CGRect(origin: .zero, size: size)
        )
        newView.canvasTheta = poseCanvasTheta

        let newPanel = ActionOverlayPanel(
            contentRect: CGRect(origin: panelOrigin(forScreen: initialScreenPoint), size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = false
        newPanel.ignoresMouseEvents = true
        newPanel.animationBehavior = .none
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        newPanel.contentView = newView

        panel = newPanel
        view = newView
        applyAnchor(target)

        newPanel.displayIfNeeded()
        ActionOverlayRuntime.pump(for: ActionOverlayTiming.bootstrapHold)

        materialized = true
    }

    private func applyAnchor(_ anchor: CursorAnchor) {
        guard let panel else { return }
        switch anchor {
        case let .window(number, layer):
            panel.level = NSWindow.Level(rawValue: layer)
            if number > 0 {
                panel.order(.above, relativeTo: number)
            } else {
                panel.orderFrontRegardless()
            }
        case .display:
            // Foreground anchor: float above normal app windows but below
            // the screen-saver layer. Adding +2 puts us comfortably above
            // a dim mask if one is later layered at the screen-saver level.
            let level = Int(CGWindowLevelForKey(.screenSaverWindow)) + 2
            panel.level = NSWindow.Level(rawValue: level)
            panel.orderFrontRegardless()
        }
        currentAnchor = anchor
    }

    private func applyPose(screenPoint: CGPoint, canvasTheta: CGFloat) {
        guard let panel, let view else { return }
        poseScreen = screenPoint
        poseCanvasTheta = canvasTheta
        panel.setFrameOrigin(panelOrigin(forScreen: screenPoint))
        view.canvasTheta = canvasTheta
        panel.displayIfNeeded()
        onPoseApplied?(screenPoint)
    }

    private func animateApproach(
        tracking: ActionOverlayTracking,
        fallbackTargetScreen: CGPoint
    ) throws {
        let targetScreen = tracking.resolvePlacement()?.screenPoint ?? fallbackTargetScreen

        let startCanvas = canvasPoint(fromAppKitScreen: poseScreen)
        let endCanvas = canvasPoint(fromAppKitScreen: targetScreen)

        let startHeading: CGFloat
        if hasAnimatedApproachOnce {
            startHeading = poseCanvasTheta
        } else {
            let dx = endCanvas.x - startCanvas.x
            let dy = endCanvas.y - startCanvas.y
            let distance = hypot(dx, dy)
            startHeading = distance > 120 ? atan2(dy, dx) : poseCanvasTheta
        }

        let plan = planner.buildPlan(
            startPoint: startCanvas,
            startHeading: startHeading,
            endPoint: endCanvas,
            endHeading: ActionOverlayApproachConstants.cursorDockHeading
        )
        let duration = planner.planDuration(plan)

        guard duration > 0 else {
            applyPose(
                screenPoint: targetScreen,
                canvasTheta: ActionOverlayApproachConstants.cursorDockHeading
            )
            hasAnimatedApproachOnce = true
            return
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + duration + ActionOverlayTiming.approachSettleTimeout

        while true {
            if stopRequested {
                stopRequested = false
                throw Interrupted()
            }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - startedAt
            let progress = min(1, CGFloat(elapsed / duration))
            let eased = easeInOut(progress)
            let s = eased * plan.totalLength
            let sample = planner.samplePlan(plan, atArcLength: s)
            let screenPt = screenPoint(fromCanvas: sample.point)

            if let placement = tracking.resolvePlacement() {
                applyAnchor(placement.target)
            }

            applyPose(screenPoint: screenPt, canvasTheta: sample.theta)

            if progress >= 1 || now >= deadline {
                break
            }

            ActionOverlayRuntime.pump(for: ActionOverlayTiming.approachStep)
        }

        hasAnimatedApproachOnce = true
    }

    // MARK: Coordinate helpers

    private func panelOrigin(forScreen p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2)
    }

    private func canvasPoint(fromAppKitScreen p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: -p.y)
    }

    private func screenPoint(fromCanvas p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: -p.y)
    }
}

private func easeInOut(_ t: CGFloat) -> CGFloat {
    let x = min(max(t, 0), 1)
    return (10 * pow(x, 3)) - (15 * pow(x, 4)) + (6 * pow(x, 5))
}
