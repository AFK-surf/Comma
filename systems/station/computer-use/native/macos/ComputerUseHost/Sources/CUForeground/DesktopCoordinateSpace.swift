import AppKit
import CoreGraphics

enum DesktopCoordinateSpace {
    static func combinedBounds(of screens: [NSScreen] = NSScreen.screens) -> CGRect {
        screens.reduce(into: CGRect.null) { result, screen in
            result = result.union(screen.frame)
        }
    }

    static func quartzToAppKitBridgeHeight(fallback: CGFloat = 1080) -> CGFloat {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return bounds.height > 0 ? bounds.height : fallback
    }

    static func desktopMaxY(of screens: [NSScreen] = NSScreen.screens, fallback: CGFloat = 1080) -> CGFloat {
        _ = screens
        return quartzToAppKitBridgeHeight(fallback: fallback)
    }

    static func appKitPoint(
        fromScreenPoint point: CGPoint,
        screens: [NSScreen] = NSScreen.screens,
        mainDisplayHeight: CGFloat? = nil
    ) -> CGPoint {
        _ = screens
        let bridgeHeight = mainDisplayHeight ?? quartzToAppKitBridgeHeight()
        return CGPoint(x: point.x, y: bridgeHeight - point.y)
    }

    static func screenPoint(
        fromAppKitPoint point: CGPoint,
        screens: [NSScreen] = NSScreen.screens,
        mainDisplayHeight: CGFloat? = nil
    ) -> CGPoint {
        _ = screens
        let bridgeHeight = mainDisplayHeight ?? quartzToAppKitBridgeHeight()
        return CGPoint(x: point.x, y: bridgeHeight - point.y)
    }

    static func appKitRect(
        fromScreenRect rect: CGRect,
        screens: [NSScreen] = NSScreen.screens,
        mainDisplayHeight: CGFloat? = nil
    ) -> CGRect {
        _ = screens
        let bridgeHeight = mainDisplayHeight ?? quartzToAppKitBridgeHeight()
        return CGRect(
            x: rect.minX,
            y: bridgeHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func screenRect(
        fromAppKitRect rect: CGRect,
        screens: [NSScreen] = NSScreen.screens,
        mainDisplayHeight: CGFloat? = nil
    ) -> CGRect {
        _ = screens
        let bridgeHeight = mainDisplayHeight ?? quartzToAppKitBridgeHeight()
        return CGRect(
            x: rect.minX,
            y: bridgeHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func screen(containing point: CGPoint, screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        if let exactMatch = screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) {
            return exactMatch
        }

        return screens.min {
            squaredDistance(from: point, to: $0.frame) < squaredDistance(from: point, to: $1.frame)
        }
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }
}
