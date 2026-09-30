import AppKit
import CoreGraphics

/// Clamp a Quartz-space screen point (top-left origin, y-down) to the
/// union of every active display's bounds. Used by the foreground
/// pose-follow hook so `CGWarpMouseCursorPosition` doesn't try to park
/// the real cursor off-screen if a bezier sample strays past a display
/// edge mid-animation.
///
/// Multi-display layouts: we take the union rect of all currently
/// active `CGDisplayBounds`, then do a rectangular clamp. This will
/// allow points inside an L-shaped dead zone between two displays, but
/// the OS itself will snap the cursor back to the nearest display edge
/// when the warp lands there, so that's a "live with it" case.
func clampToDesktop(_ point: CGPoint) -> CGPoint {
    var count: UInt32 = 0
    guard
        CGGetActiveDisplayList(0, nil, &count) == .success,
        count > 0
    else {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return clampToRect(point, rect: bounds)
    }

    var ids = Array(repeating: CGDirectDisplayID(), count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return clampToRect(point, rect: bounds)
    }

    var union = CGRect.null
    for id in ids.prefix(Int(count)) {
        let rect = CGDisplayBounds(id)
        union = union.isNull ? rect : union.union(rect)
    }
    if union.isNull {
        union = CGDisplayBounds(CGMainDisplayID())
    }
    return clampToRect(point, rect: union)
}

/// Move the real system cursor to `point` using a CGEvent.post call
/// tagged with `COMPUTER_USE_EVENT_TAG`. This is the foreground-mode
/// replacement for `CGWarpMouseCursorPosition` in the pose-follow
/// hook: the tag makes `InterventionDetector` skip the event instead
/// of treating the synthesized motion as a real user intervention.
func postTaggedMouseMoved(at point: CGPoint) {
    guard let event = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
    ) else { return }
    event.setIntegerValueField(.eventSourceUserData, value: COMPUTER_USE_EVENT_TAG)
    event.post(tap: .cghidEventTap)
}

private func clampToRect(_ point: CGPoint, rect: CGRect) -> CGPoint {
    guard rect.width > 0, rect.height > 0 else { return point }
    // Pull in one point on the max edges — `CGWarpMouseCursorPosition`
    // at exactly `maxX/maxY` sometimes silently no-ops on macOS 14+
    // because that coord is off the last row of usable pixels.
    return CGPoint(
        x: min(max(point.x, rect.minX), rect.maxX - 1),
        y: min(max(point.y, rect.minY), rect.maxY - 1)
    )
}
