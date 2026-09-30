import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Where the overlay cursor sits in the window-server stack.
///
/// - `.window`: pin above a specific window number, riding that window's
///   layer so unrelated foreground windows still occlude the sprite
///   correctly. Used by background mode (per-window automation).
/// - `.display`: float above an entire display at a fixed level (above
///   normal app windows, below the screen-saver). Used by foreground mode
///   when there is no single owning window — the agent acts on whatever is
///   on top of the user's display.
public enum CursorAnchor: Equatable, Sendable {
    case window(number: Int, layer: Int)
    case display(screenID: CGDirectDisplayID)
}

/// Backwards-compatible wrapper preserved for in-tree call sites that were
/// constructed before `CursorAnchor` existed. Treats every instance as a
/// `.window` anchor.
public typealias ActionOverlayTarget = CursorAnchor
public extension CursorAnchor {
    init(windowNumber: Int, windowLayer: Int) {
        self = .window(number: windowNumber, layer: windowLayer)
    }

    var windowNumber: Int {
        if case let .window(n, _) = self { return n }
        return 0
    }

    var windowLayer: Int {
        if case let .window(_, l) = self { return l }
        return Int(CGWindowLevelForKey(.normalWindow))
    }
}

public enum ActionOverlayKind: Sendable {
    case click(button: MouseButton)
    case drag(button: MouseButton)
    case scroll(direction: String)
    case accessibilityAction
    case secondaryAction

    public var usesApproachAnimation: Bool {
        true
    }
}

public struct ActionOverlayPlacement: Sendable {
    public let screenPoint: CGPoint
    public let target: CursorAnchor
    public let windowFrame: CGRect?

    public init(screenPoint: CGPoint, target: CursorAnchor, windowFrame: CGRect?) {
        self.screenPoint = screenPoint
        self.target = target
        self.windowFrame = windowFrame
    }
}

public struct ActionOverlayTracking: @unchecked Sendable {
    public let resolvePlacement: () -> ActionOverlayPlacement?

    public init(resolvePlacement: @escaping () -> ActionOverlayPlacement?) {
        self.resolvePlacement = resolvePlacement
    }
}

public enum ActionOverlayRuntime {
    @MainActor
    public static func prepareAppKit() -> Bool {
        guard Thread.isMainThread else {
            return false
        }

        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        return true
    }

    public static func pump(for duration: TimeInterval) {
        guard duration > 0 else {
            return
        }

        let until = Date(timeIntervalSinceNow: duration)
        while Date() < until {
            _ = RunLoop.current.run(mode: .default, before: until)
            _ = RunLoop.current.run(mode: .eventTracking, before: until)
        }
    }
}

public enum ActionOverlayTiming {
    public static var bootstrapHold: TimeInterval {
        milliseconds(from: "CUNEXT_OVERLAY_BOOTSTRAP_MS", fallback: 20)
    }

    public static var updateHold: TimeInterval {
        milliseconds(from: "CUNEXT_OVERLAY_UPDATE_MS", fallback: 8)
    }

    public static var preActionHold: TimeInterval {
        milliseconds(from: "CUNEXT_OVERLAY_PRE_MS", fallback: 40)
    }

    /// Dwell at the target after the approach settles so the user sees the
    /// cursor "land" before it changes into pressed/dragging state.
    public static var postApproachDwell: TimeInterval {
        milliseconds(from: "CUNEXT_OVERLAY_DWELL_MS", fallback: 180)
    }

    public static var finalHold: TimeInterval {
        milliseconds(from: "CUNEXT_OVERLAY_HOLD_MS", fallback: 80)
    }

    public static var trackingInterval: TimeInterval {
        milliseconds(from: "CUNEXT_OVERLAY_TRACK_MS", fallback: 16)
    }

    public static var approachDuration: TimeInterval {
        milliseconds(from: "CUNEXT_OVERLAY_APPROACH_MS", fallback: 460)
    }

    public static var approachStep: TimeInterval {
        milliseconds(from: "CUNEXT_OVERLAY_APPROACH_STEP_MS", fallback: 12)
    }

    public static var approachSettleTimeout: TimeInterval {
        milliseconds(from: "CUNEXT_OVERLAY_APPROACH_SETTLE_MS", fallback: 900)
    }

    public static var dragDuration: TimeInterval {
        milliseconds(from: "CUNEXT_OVERLAY_DRAG_MS", fallback: 300)
    }

    public static var dragStep: TimeInterval {
        milliseconds(from: "CUNEXT_OVERLAY_DRAG_STEP_MS", fallback: 10)
    }

    private static func milliseconds(from key: String, fallback: Double) -> TimeInterval {
        guard
            let raw = ProcessInfo.processInfo.environment[key],
            let value = Double(raw),
            value >= 0
        else {
            return fallback / 1000
        }

        return value / 1000
    }
}

final class ActionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

final class ActionOverlayCursorView: NSView {
    private static let cursorImage: NSImage? = {
        guard let url = Bundle.commaResources.url(forResource: "OverlayCursor", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    /// Canvas-style heading (radians, y-down CCW), matching the demo's
    /// convention. At rest, callers set `canvasTheta = cursorDockHeading`
    /// so the applied rotation below becomes zero — the sprite is drawn in
    /// its natural un-rotated orientation.
    var canvasTheta: CGFloat = ActionOverlayApproachConstants.cursorDockHeading {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard
            let image = Self.cursorImage,
            let ctx = NSGraphicsContext.current?.cgContext
        else {
            return
        }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let size = ActionOverlayCursorGeometry.renderSize
        let hotspot = ActionOverlayCursorGeometry.hotspot
        let baseRot = ActionOverlayApproachConstants.cursorBaseRotation

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: -(canvasTheta + baseRot))
        image.draw(
            in: CGRect(
                x: -hotspot.x * size,
                y: (hotspot.y - 1) * size,
                width: size,
                height: size
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        ctx.restoreGState()
    }
}

public enum ActionOverlayCursorGeometry {
    public static let hotspot = CGPoint(x: 17.0 / 101.0, y: 13.0 / 101.0)
    public static let naturalHeading: CGFloat = 2.270552
    /// Rendered cursor edge in points. Halved from the original 56pt so
    /// the sprite reads closer to the size of the system cursor (~24pt
    /// on Retina) — applies to both foreground and background, since
    /// they share this single geometry constant through
    /// `ActionOverlayCursorView` / `DaemonCursor`.
    /// `hotspot` is normalized against the rendered rect, so clicks still
    /// land where the sprite's tip is after the scale change.
    public static let renderSize: CGFloat = 28
}

public func overlayOrigin(for screenPoint: CGPoint, size: CGSize) -> CGPoint {
    CGPoint(
        x: screenPoint.x - (size.width / 2),
        y: screenPoint.y - (size.height / 2)
    )
}

public func windowLocalPointOverlayTracking(
    target: CursorAnchor,
    fallbackWindowFrame: CGRect,
    currentWindowLocalPoint: @escaping () -> CGPoint
) -> ActionOverlayTracking {
    ActionOverlayTracking {
        let anchor = currentWindowLocalPoint()
        guard
            case let .window(windowNumber, fallbackLayer) = target,
            let snapshot = actionOverlayWindowSnapshot(
                windowNumber: windowNumber,
                fallbackLayer: fallbackLayer
            )
        else {
            return ActionOverlayPlacement(
                screenPoint: overlayScreenPointForLocalPoint(
                    windowLocalPoint: anchor,
                    windowFrame: fallbackWindowFrame
                ),
                target: target,
                windowFrame: fallbackWindowFrame
            )
        }

        guard snapshot.isOnscreen else {
            return nil
        }

        return ActionOverlayPlacement(
            screenPoint: overlayScreenPointForLocalPoint(
                windowLocalPoint: anchor,
                windowFrame: snapshot.bounds
            ),
            target: snapshot.target,
            windowFrame: snapshot.bounds
        )
    }
}

public func axFrameOverlayTracking(
    target: CursorAnchor,
    fallbackWindowFrame: CGRect,
    fallbackFrame: CGRect,
    frameProvider: @escaping () -> CGRect?
) -> ActionOverlayTracking {
    ActionOverlayTracking {
        let frame = frameProvider() ?? fallbackFrame

        guard
            case let .window(windowNumber, fallbackLayer) = target,
            let snapshot = actionOverlayWindowSnapshot(
                windowNumber: windowNumber,
                fallbackLayer: fallbackLayer
            )
        else {
            return ActionOverlayPlacement(
                screenPoint: overlayScreenPointForAXFrame(frame),
                target: target,
                windowFrame: fallbackWindowFrame
            )
        }

        guard snapshot.isOnscreen else {
            return nil
        }

        return ActionOverlayPlacement(
            screenPoint: overlayScreenPointForAXFrame(frame),
            target: snapshot.target,
            windowFrame: snapshot.bounds
        )
    }
}

private struct ActionOverlayWindowSnapshot {
    let bounds: CGRect
    let target: CursorAnchor
    let isOnscreen: Bool
}

private func actionOverlayWindowSnapshot(
    windowNumber: Int,
    fallbackLayer: Int
) -> ActionOverlayWindowSnapshot? {
    guard
        windowNumber > 0,
        let rows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowNumber)
        ) as? [[String: Any]],
        let row = rows.first
    else {
        return nil
    }

    let bounds = CGRect(
        dictionaryRepresentation: (
            row[kCGWindowBounds as String] as? [String: Any] ?? [:]
        ) as CFDictionary
    ) ?? .zero
    let layer = row[kCGWindowLayer as String] as? Int ?? fallbackLayer
    let onscreen = row[kCGWindowIsOnscreen as String] as? Int ?? 1

    return ActionOverlayWindowSnapshot(
        bounds: bounds,
        target: .window(number: windowNumber, layer: layer),
        isOnscreen: onscreen != 0
    )
}

public func actionOverlayAXFrame(of element: AXUIElement) -> CGRect? {
    guard
        let positionRef = actionOverlayAXAttribute(element, name: kAXPositionAttribute),
        let sizeRef = actionOverlayAXAttribute(element, name: kAXSizeAttribute)
    else {
        return nil
    }

    let positionValue = positionRef as! AXValue
    let sizeValue = sizeRef as! AXValue
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard
        AXValueGetType(positionValue) == .cgPoint,
        AXValueGetValue(positionValue, .cgPoint, &origin),
        AXValueGetType(sizeValue) == .cgSize,
        AXValueGetValue(sizeValue, .cgSize, &size)
    else {
        return nil
    }

    return CGRect(origin: origin, size: size)
}

private func actionOverlayAXAttribute(
    _ element: AXUIElement,
    name: String
) -> AnyObject? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard error == .success else {
        return nil
    }
    return value
}

public enum ActionOverlayApproachConstants {
    public static let cursorBaseRotation = ActionOverlayCursorGeometry.naturalHeading
    public static let cursorDockHeading: CGFloat = -cursorBaseRotation
}

/// AppKit screen point for a spawn location just OUTSIDE the bottom-left
/// corner of the display containing the target window. The cursor flies in
/// from off-screen on the first action so the user sees a smooth entrance
/// rather than a sprite appearing at the screen edge.
public func actionOverlayBottomLeftScreenPoint(forWindowFrame windowFrame: CGRect) -> CGPoint {
    let windowAppKitMid = overlayScreenPointForAXFrame(windowFrame)
    let screen = NSScreen.screens.first(where: { $0.frame.contains(windowAppKitMid) })
        ?? NSScreen.main
        ?? NSScreen.screens.first

    let offset: CGFloat = 60
    guard let frame = screen?.frame else {
        return CGPoint(x: -offset, y: -offset)
    }

    return CGPoint(x: frame.minX - offset, y: frame.minY - offset)
}

/// AppKit screen point just outside the bottom-left of `screenID`. Same
/// idea as `actionOverlayBottomLeftScreenPoint(forWindowFrame:)` but for
/// foreground mode where the cursor anchor is a display rather than a
/// window.
public func actionOverlayBottomLeftScreenPoint(forScreenID screenID: CGDirectDisplayID) -> CGPoint {
    let target = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == screenID
    } ?? NSScreen.main ?? NSScreen.screens.first

    let offset: CGFloat = 60
    guard let frame = target?.frame else {
        return CGPoint(x: -offset, y: -offset)
    }
    return CGPoint(x: frame.minX - offset, y: frame.minY - offset)
}
