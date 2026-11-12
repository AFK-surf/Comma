import AppKit
import CoreGraphics
import CUShared
import Foundation

/// Public shim that exposes CUForeground internals (`AgentCursorOverlay`,
/// DaemonCursor-based foreground animation) to the `CoordDemo` test
/// harness without having to promote every individual type to `public`.
///
/// Only used by `CoordDemo`. Not referenced from the real daemon code
/// path — the daemon has direct access to the internal types.
@MainActor
public enum DemoBridge {
    public static func makeAgentCursorOverlay() -> AnyObject {
        AgentCursorOverlay()
    }

    public static func activate(overlay: AnyObject) {
        (overlay as? AgentCursorOverlay)?.activate()
    }

    public static func deactivate(overlay: AnyObject) {
        (overlay as? AgentCursorOverlay)?.deactivate()
    }

    /// Run the same bezier+rotation approach animation the foreground
    /// executor uses for clicks. Caller provides Quartz-space screen
    /// coordinates (top-left, y-down); we convert to AppKit for the
    /// DaemonCursor pose API, warp the system cursor at the end, and
    /// leave the sprite at the target.
    public static func animatedMove(to targetScreen: CGPoint) async throws {
        // Precondition: AgentCursorOverlay.activate() has already run so
        // the system cursor is hidden.
        let bridgeHeight = DesktopCoordinateSpace.desktopMaxY()
        let appKitTarget = CGPoint(
            x: targetScreen.x,
            y: bridgeHeight - targetScreen.y
        )
        let appKitCurrent: CGPoint = {
            guard let cg = CGEvent(source: nil)?.location else { return appKitTarget }
            return CGPoint(x: cg.x, y: bridgeHeight - cg.y)
        }()
        DaemonCursor.shared.syncPose(toScreenPoint: appKitCurrent)
        DaemonCursor.shared.showPanel()
        try DaemonCursor.shared.runApproachThenAction(
            kind: .accessibilityAction,
            target: .display(screenID: CGMainDisplayID()),
            fallbackScreenPoint: appKitTarget,
            fallbackWindowFrame: .zero,
            tracking: ActionOverlayTracking(resolvePlacement: { nil })
        ) {
            // End-of-approach: snap the system cursor to the target so
            // subsequent `CGEvent.location` reads are accurate.
            CGWarpMouseCursorPosition(targetScreen)
        }
    }
}
