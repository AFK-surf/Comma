import AppKit

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func asWindowServerBounds(in screens: [NSScreen]) -> CGRect {
        DesktopCoordinateSpace.screenRect(fromAppKitRect: self, screens: screens)
    }
}
