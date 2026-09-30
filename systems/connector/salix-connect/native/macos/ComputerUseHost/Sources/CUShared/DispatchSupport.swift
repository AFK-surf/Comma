import AppKit
import ApplicationServices
import Darwin
import Foundation

public enum UIElementError: Error, CustomStringConvertible {
    case permissionDenied
    case synthesizedEventCreationFailed(type: String)
    case axError(AXError, action: String)

    public var description: String {
        switch self {
        case .permissionDenied:
            "Accessibility permission is required for this process"
        case let .synthesizedEventCreationFailed(type):
            "synthesizedEventCreationFailed type=\(type)"
        case let .axError(error, action):
            "AXError(\(error.rawValue)) for action \(action)"
        }
    }
}

// Button number and mouse-subtype fields don't have public symbols, so we
// construct them from the documented raw values once up front.
public let buttonNumberField = CGEventField(rawValue: 3)!
public let mouseSubtypeField = CGEventField(rawValue: 7)!
// Fields 91 / 92 are `kCGMouseEventWindowUnderMousePointer` /
// `...ThatCanHandleThisEvent` — private constants Quartz uses to attach a
// target window to a synthesized event so the app routes it without a
// cursor-hit-test. Not in any SDK header.
public let mouseWindowUnderPointerField = CGEventField(rawValue: 91)!
public let mouseWindowUnderPointerThatCanHandleField = CGEventField(rawValue: 92)!

public let backgroundDispatchFlag = CGEventFlags.maskCommand

public func backgroundDispatchFlags(
    modifierFlags: CGEventFlags,
    isTargetActive: Bool
) -> CGEventFlags {
    isTargetActive ? modifierFlags : modifierFlags.union(backgroundDispatchFlag)
}

// MARK: - Legacy CGPoint helpers

// These kept their old names because many call sites (overlay tracking,
// action routing) pass CGPoints through closures; keeping the shape stable
// limits the refactor blast radius. Internally each goes through the typed
// conversions in CoordinateSpaces.swift.

public func translatedScreenPoint(
    windowLocalPoint point: CGPoint,
    windowFrame: CGRect
) -> CGPoint {
    axScreenPoint(
        fromWindowLocal: Point<WindowLocalSpace>(point),
        windowFrame: windowFrame
    ).cgPoint
}

public func translatedWindowLocalPoint(
    screenPoint point: CGPoint,
    windowFrame: CGRect
) -> CGPoint {
    windowLocalPoint(
        fromAXScreen: Point<AXScreenSpace>(point),
        windowFrame: windowFrame
    ).cgPoint
}

public func translatedWindowLocalPoint(
    fromAppKitScreenPoint point: CGPoint,
    windowFrame: CGRect
) -> CGPoint {
    windowLocalPoint(
        fromAppKitScreen: Point<AppKitScreenSpace>(point),
        windowFrame: windowFrame
    ).cgPoint
}

public func overlayScreenPointForLocalPoint(
    windowLocalPoint point: CGPoint,
    windowFrame: CGRect
) -> CGPoint {
    appKitScreenPoint(
        fromWindowLocal: Point<WindowLocalSpace>(point),
        windowFrame: windowFrame
    ).cgPoint
}

public func overlayScreenPointForAXFrame(_ frame: CGRect) -> CGPoint {
    appKitScreenPoint(
        from: Point<AXScreenSpace>(x: frame.midX, y: frame.midY)
    ).cgPoint
}

public let cgEventWindowLocationSetter: (@convention(c) (CGEvent, CGPoint) -> Void)? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else {
        return nil
    }
    return unsafeBitCast(symbol, to: (@convention(c) (CGEvent, CGPoint) -> Void).self)
}()
