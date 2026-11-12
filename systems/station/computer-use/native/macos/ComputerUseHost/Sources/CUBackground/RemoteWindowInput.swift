import AppKit
import ApplicationServices
import CUShared
import Foundation

/// A person's input for one window of a process, by the background route: it reaches the window whatever covers it,
/// does not raise it and does not move the pointer. Points are global, top-left-origin screen points.
public struct RemoteWindowInput {
    /// The WindowServer window behind an accessibility window, using the same bridge as background input.
    public static func windowID(of window: AXUIElement) -> CGWindowID? {
        BackgroundSkyLight.cgWindowID(forAXWindow: window)
    }

    private let dispatcher: BackgroundMouseDispatcher

    public init(pid: pid_t, windowNumber: Int, windowFrame: CGRect, flags: CGEventFlags) {
        dispatcher = BackgroundMouseDispatcher(
            targetPID: pid,
            windowNumber: windowNumber,
            windowLayer: 0,
            windowFrame: windowFrame,
            modifierFlags: flags
        )
    }

    private func local(_ point: CGPoint) -> CGPoint {
        translatedWindowLocalPoint(screenPoint: point, windowFrame: dispatcher.windowFrame)
    }

    /// The window takes the keys and the next press. Blocks for about 170 ms.
    public func focus(at point: CGPoint) {
        try? dispatcher.primeClick(at: local(point))
    }

    public func mouseEvent(_ type: CGEventType, at point: CGPoint, button: Int, clicks: Int) -> CGEvent? {
        guard let kind = NSEvent.EventType(rawValue: UInt(type.rawValue)) else { return nil }
        let released = [.mouseMoved, .leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type)
        return try? dispatcher.skyLightMouseEvent(
            type: kind,
            at: local(point),
            clickState: type == .mouseMoved ? 0 : clicks,
            pressure: released ? 0 : 1,
            button: button == 0 ? .left : button == 1 ? .right : .middle
        )
    }

    public func postMouse(_ type: CGEventType, at point: CGPoint, button: Int, clicks: Int) {
        if let event = mouseEvent(type, at: point, button: button, clicks: clicks) { dispatcher.postMouseEvent(event) }
    }

    public func postScroll(at point: CGPoint, dx: Int32, dy: Int32) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0
        ) else { return }
        event.location = point
        event.flags = dispatcher.modifierFlags
        dispatcher.postMouseEvent(event)
    }

    /// Keys stay on the public per-process route, as BackgroundKeyboardDispatcher's do.
    public func postKey(_ code: CGKeyCode, down: Bool) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = dispatcher.modifierFlags
        event?.postToPid(dispatcher.targetPID)
    }

    /// Keyboard events made elsewhere (text carried as a Unicode string), on the keys' route.
    public func postEvents(_ events: [CGEvent]) {
        for event in events {
            event.postToPid(dispatcher.targetPID)
        }
    }
}
