import AppKit

enum ComputerUseCursor {
    static let canvasSize = NSSize(width: 101.0 / 4.0, height: 101.0 / 4.0)
    static let hotSpot = CGPoint.zero

    static let followingImage = makeImage(named: "ComputerUseCursor")
    static let markerImage = makeImage(named: "ComputerUseMarkerCursor")

    static func frame(for pointerLocation: CGPoint, desktopMaxY: CGFloat) -> NSRect {
        let appKitPoint = DesktopCoordinateSpace.appKitPoint(
            fromScreenPoint: pointerLocation,
            mainDisplayHeight: desktopMaxY
        )
        return NSRect(
            x: appKitPoint.x - hotSpot.x,
            y: appKitPoint.y - canvasSize.height + hotSpot.y,
            width: canvasSize.width,
            height: canvasSize.height
        )
    }

    private static func makeImage(named resourceName: String) -> NSImage {
        guard let url = Bundle.commaResources.url(forResource: resourceName, withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else {
            preconditionFailure("Missing \(resourceName).png resource")
        }

        image.size = canvasSize
        return image
    }
}
