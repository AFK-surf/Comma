import AppKit
import Foundation

// Every coordinate we pass around in this codebase belongs to exactly one of
// these spaces. Historically each file baked its own y-flip and each caller
// had to remember which convention it was speaking — that produced a string
// of upside-down / off-by-titlebar bugs during the overlay rewrite. The
// phantom-typed `Point<Space>` wrapper below makes the space part of the
// value, so a conversion that forgets to flip y stops compiling rather than
// silently landing clicks in the wrong place.

// MARK: - Space tags

public protocol CoordinateSpace {}

/// Quartz "global display" space. y grows **down** from the top-left of the
/// primary display. What `kAXPositionAttribute` returns and what
/// `CGWindowListCopyWindowInfo`'s bounds are in.
public enum AXScreenSpace: CoordinateSpace {}

/// AppKit screen space. y grows **up** from the bottom-left of the primary
/// display. What `NSScreen.frame` / `NSWindow.frame` / `convertPoint(toScreen:)`
/// return.
public enum AppKitScreenSpace: CoordinateSpace {}

/// AppKit window-local space (bottom-origin, relative to the window's
/// content + frame). What `NSEvent.locationInWindow` gives and what
/// `NSEvent.mouseEvent(location:)` expects when paired with `windowNumber`.
public enum WindowLocalSpace: CoordinateSpace {}

/// Quartz window-local space (top-origin, relative to the window bounds).
/// What `CGEventSetWindowLocation` expects.
public enum QuartzWindowSpace: CoordinateSpace {}

/// Pixel space of a captured screenshot image. Top-origin, in image pixels
/// (which may be 2× the window's point size on retina displays). Only the
/// `--x / --y` CLI flags live here.
public enum ScreenshotPixelSpace: CoordinateSpace {}

// MARK: - Typed point wrapper

public struct Point<Space: CoordinateSpace>: Equatable {
    public var x: CGFloat
    public var y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    public init(_ cgPoint: CGPoint) {
        x = cgPoint.x
        y = cgPoint.y
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

// MARK: - Screen-space conversions (AX ↔ AppKit)

/// AppKit screen point at the same display location as `point`. Falls back
/// to the nearest display if `point` is off every screen (e.g. an
/// off-screen overlay spawn point).
public func appKitScreenPoint(from point: Point<AXScreenSpace>) -> Point<AppKitScreenSpace> {
    let spaces = DisplayCoordinateSpaceRegistry.current()
    let space = spaces.first(where: { $0.axFrame.contains(point.cgPoint) })
        ?? spaces.min(by: {
            DisplayCoordinateSpaceRegistry.distanceSquared(from: point.cgPoint, to: $0.axFrame) <
                DisplayCoordinateSpaceRegistry.distanceSquared(from: point.cgPoint, to: $1.axFrame)
        })
    guard let space else { return Point(point.cgPoint) }

    let localX = point.x - space.axFrame.minX
    let localY = point.y - space.axFrame.minY
    return Point(
        x: space.appKitFrame.minX + localX,
        y: space.appKitFrame.maxY - localY
    )
}

public func axScreenPoint(from point: Point<AppKitScreenSpace>) -> Point<AXScreenSpace> {
    let spaces = DisplayCoordinateSpaceRegistry.current()
    let space = spaces.first(where: { $0.appKitFrame.contains(point.cgPoint) })
        ?? spaces.min(by: {
            DisplayCoordinateSpaceRegistry.distanceSquared(from: point.cgPoint, to: $0.appKitFrame) <
                DisplayCoordinateSpaceRegistry.distanceSquared(from: point.cgPoint, to: $1.appKitFrame)
        })
    guard let space else { return Point(point.cgPoint) }

    let localX = point.x - space.appKitFrame.minX
    let localY = space.appKitFrame.maxY - point.y
    return Point(
        x: space.axFrame.minX + localX,
        y: space.axFrame.minY + localY
    )
}

// MARK: - Window-local ↔ screen

/// `windowFrame` is the AX (top-origin) bounds for the window. Window-local
/// is bottom-origin, so converting to the matching AX screen point flips y
/// inside the frame.
public func axScreenPoint(
    fromWindowLocal point: Point<WindowLocalSpace>,
    windowFrame: CGRect
) -> Point<AXScreenSpace> {
    Point(
        x: point.x + windowFrame.minX,
        y: windowFrame.minY + (windowFrame.height - point.y)
    )
}

public func windowLocalPoint(
    fromAXScreen point: Point<AXScreenSpace>,
    windowFrame: CGRect
) -> Point<WindowLocalSpace> {
    Point(
        x: point.x - windowFrame.minX,
        y: windowFrame.height - (point.y - windowFrame.minY)
    )
}

// MARK: - Convenience round-trips through screen spaces

public func appKitScreenPoint(
    fromWindowLocal point: Point<WindowLocalSpace>,
    windowFrame: CGRect
) -> Point<AppKitScreenSpace> {
    appKitScreenPoint(
        from: axScreenPoint(fromWindowLocal: point, windowFrame: windowFrame)
    )
}

public func windowLocalPoint(
    fromAppKitScreen point: Point<AppKitScreenSpace>,
    windowFrame: CGRect
) -> Point<WindowLocalSpace> {
    windowLocalPoint(
        fromAXScreen: axScreenPoint(from: point),
        windowFrame: windowFrame
    )
}

// MARK: - Window-local → Quartz window-local (for CGEventSetWindowLocation)

/// AppKit's window-local is bottom-origin; Quartz's is top-origin. Within
/// the same window, the conversion is just a y-flip around `height`.
public func quartzWindowPoint(
    fromWindowLocal point: Point<WindowLocalSpace>,
    windowHeight: CGFloat
) -> Point<QuartzWindowSpace> {
    Point(x: point.x, y: windowHeight - point.y)
}

// MARK: - Screenshot pixel → window-local

/// Screenshots are taken in Quartz (top-origin) pixel space. The window
/// frame in AppKit points may have a different resolution (retina), so we
/// normalize through the pixel extents.
public func windowLocalPoint(
    fromScreenshotPixel pixel: Point<ScreenshotPixelSpace>,
    screenshotSize: CGSize,
    windowFrame: CGRect
) -> Point<WindowLocalSpace> {
    let clampedX = min(max(0, pixel.x), screenshotSize.width)
    let clampedY = min(max(0, pixel.y), screenshotSize.height)
    let normalizedX = screenshotSize.width == 0 ? 0 : clampedX / screenshotSize.width
    let normalizedY = screenshotSize.height == 0 ? 0 : clampedY / screenshotSize.height
    return Point(
        x: normalizedX * windowFrame.width,
        y: windowFrame.height - (normalizedY * windowFrame.height)
    )
}

// MARK: - Display registry (shared by AX ↔ AppKit conversions)

private enum DisplayCoordinateSpaceRegistry {
    struct DisplaySpace {
        let appKitFrame: CGRect
        let axFrame: CGRect
    }

    static func current() -> [DisplaySpace] {
        NSScreen.screens.compactMap { screen in
            guard
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            return DisplaySpace(
                appKitFrame: screen.frame,
                axFrame: CGDisplayBounds(displayID)
            )
        }
    }

    static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx: CGFloat = if point.x < rect.minX {
            rect.minX - point.x
        } else if point.x > rect.maxX {
            point.x - rect.maxX
        } else {
            0
        }

        let dy: CGFloat = if point.y < rect.minY {
            rect.minY - point.y
        } else if point.y > rect.maxY {
            point.y - rect.maxY
        } else {
            0
        }

        return (dx * dx) + (dy * dy)
    }
}
