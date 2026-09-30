import AppKit

extension NSScreen {
    var notchDisplayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func notchScreen(withDisplayID displayID: UInt32) -> NSScreen? {
        screens.first { $0.notchDisplayID == displayID }
    }

    @MainActor
    static var screenUnderPointer: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return screen
        }
        return NSApp.keyWindow?.screen ?? NSScreen.main
    }

    var notchKitSize: CGSize {
        guard safeAreaInsets.top > 0 else { return .zero }
        let notchHeight = safeAreaInsets.top
        let fullWidth = frame.width
        let leftPadding = auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = auxiliaryTopRightArea?.width ?? 0
        guard leftPadding > 0, rightPadding > 0 else { return .zero }
        let notchWidth = fullWidth - leftPadding - rightPadding
        return .init(width: ceil(notchWidth), height: ceil(notchHeight))
    }

    var isBuiltInNotchDisplay: Bool {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(id.uint32Value) == 1
    }

    static var builtInNotchDisplay: NSScreen? {
        screens.first { $0.isBuiltInNotchDisplay }
    }

    var notchKitHasFullScreenWindow: Bool {
        guard let displayID = notchDisplayID else { return false }

        let displayBounds = CGDisplayBounds(CGDirectDisplayID(displayID))
        guard displayBounds.width > 0, displayBounds.height > 0 else { return false }

        let options: CGWindowListOption = [.excludeDesktopElements, .optionOnScreenOnly]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        return windows.contains { window in
            guard
                let layer = window[kCGWindowLayer as String] as? Int,
                layer == 0,
                let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                return false
            }

            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha <= 0 {
                return false
            }

            if let ownerName = window[kCGWindowOwnerName as String] as? String,
               ownerName == "Dock" || ownerName == "Window Server"
            {
                return false
            }

            return bounds.notchKitApproximatelyMatches(displayBounds, tolerance: 3)
        }
    }
}

private extension CGRect {
    func notchKitApproximatelyMatches(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
