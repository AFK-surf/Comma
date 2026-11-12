import CoreGraphics
import Foundation

/// Anthropic computer-use vision-API limits that the agent's screenshots
/// must fit inside: long edge ≤ 1568 px, total area ≤ 0.6 megapixels.
/// Numeric values mirror legacy ComputerUse's `MAX_LONG_EDGE` /
/// `MAX_PIXELS` exactly — the 0.6 MP budget is measured against
/// 0.6 × 1024² (629_145.6), NOT a flat 600_000; the Anthropic spec is
/// written in binary megapixels and using the decimal value would quietly
/// downscale edge cases that legacy kept at native size.
///
/// Both modes size their screenshots with `fittedSize`, so the image the
/// model sees is the image its coordinates are mapped against.
public enum AnthropicImageLimits {
    public static let maxLongEdgePixels: Int = 1568
    public static let maxPixelArea: Int = 629_145

    /// The largest size with the source's aspect ratio that fits both
    /// limits; the source size itself when it already fits.
    public static func fittedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (max(1, width), max(1, height)) }
        let w = CGFloat(width)
        let h = CGFloat(height)
        let longEdgeScale = CGFloat(maxLongEdgePixels) / max(w, h)
        let areaScale = sqrt(CGFloat(maxPixelArea) / (w * h))
        let scale = min(1.0, min(longEdgeScale, areaScale))
        if scale >= 1.0 { return (width, height) }
        return (
            width: max(1, Int((w * scale).rounded())),
            height: max(1, Int((h * scale).rounded()))
        )
    }
}
