import AppKit
import CoreGraphics
import Foundation

/// Tracks the dimensions of the last screenshot handed to the agent so
/// subsequent click/move/drag coordinates can be mapped back to display
/// logical points.
///
/// The agent receives screenshots that have been downscaled to fit
/// Anthropic's vision limits (long edge ≤ 1568 px, area ≤ 0.6 MP), so a
/// pixel in what the agent sees is NOT a device pixel and definitely not
/// a display point. Legacy ComputerUse's `CoordinateConverter.imageToScreen`
/// applies `image → physical → logical` with the live image dimensions;
/// this helper plays the same role for foreground mode.
@MainActor
enum ForegroundCoordinateMap {
    /// Most-recent screenshot's scaled image dimensions. Updated by
    /// `ScreenCapture.captureToPNG` each time. `nil` until the first
    /// screenshot of the session — in that case we fall back to
    /// treating the input as device pixels (legacy behaviour).
    private(set) static var lastImage: (width: Int, height: Int)?

    static func recordLastImage(width: Int, height: Int) {
        lastImage = (width: width, height: height)
    }

    /// Convert screenshot-pixel coordinates (top-left origin, in the
    /// scaled image the agent received) into Quartz CG points suitable
    /// for `CGEvent` / `CGWarpMouseCursorPosition`.
    ///
    /// Formula mirrors legacy `CoordinateConverter.imageToScreen`:
    ///   logicalX = imageX × (physicalW / imageW) / scaleFactor
    ///           = imageX × (logicalW / imageW)
    /// — i.e., just rescale from image-pixel space to display-point space.
    static func imageToScreen(x: Double, y: Double) -> CGPoint {
        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        let logicalW = max(bounds.width, 1)
        let logicalH = max(bounds.height, 1)

        let imageW: CGFloat
        let imageH: CGFloat
        if let last = lastImage, last.width > 0, last.height > 0 {
            imageW = CGFloat(last.width)
            imageH = CGFloat(last.height)
        } else {
            // No screenshot taken yet — predict what dimensions
            // `ScreenCapture.scaleToAnthropicLimits` would produce for
            // the current display. The agent might legitimately
            // `cursor-position`/`mouse-move` before its first
            // screenshot (e.g., via a host status card), and falling
            // back to `backingScale` would land clicks at ~1/3 of
            // screen coords on Retina.
            let predicted = predictAnthropicClampedSize(forDisplayID: displayID)
            imageW = CGFloat(predicted.width)
            imageH = CGFloat(predicted.height)
        }

        return CGPoint(
            x: bounds.origin.x + x * Double(logicalW / imageW),
            y: bounds.origin.y + y * Double(logicalH / imageH)
        )
    }

    /// Mirror of `ScreenCapture.scaleToAnthropicLimits` arithmetic,
    /// computed directly from the display's native pixel mode. Keep in
    /// sync with `AnthropicImageLimits` — if the constants there change,
    /// bump them here too.
    private static func predictAnthropicClampedSize(forDisplayID id: CGDirectDisplayID) -> (width: Int, height: Int) {
        let mode = CGDisplayCopyDisplayMode(id)
        let pw = CGFloat(mode?.pixelWidth ?? Int(CGDisplayBounds(id).width))
        let ph = CGFloat(mode?.pixelHeight ?? Int(CGDisplayBounds(id).height))
        guard pw > 0, ph > 0 else { return (1, 1) }

        let maxLong: CGFloat = 1568
        let maxArea: CGFloat = 629_145
        let longEdgeScale = maxLong / max(pw, ph)
        let areaScale = sqrt(maxArea / (pw * ph))
        let scale = min(1.0, min(longEdgeScale, areaScale))
        return (
            width: max(1, Int((pw * scale).rounded())),
            height: max(1, Int((ph * scale).rounded()))
        )
    }
}
