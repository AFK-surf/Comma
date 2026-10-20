import SwiftUI

// Timing and geometry of the `CommaLogoAnimation` zoom loop, and the frame values it yields over time.

enum CommaLogoAnimationMetrics {
    static let canvasSize: CGFloat = 730
    static let zoomDuration = 2.0
    static let holdDuration = 1.4
    static let nestedDelay = zoomDuration * 0.01
    static let finalZoom: CGFloat = 2.7756653992
    static let finalTranslation = CGSize(width: -1140.7984790875, height: -1118.5931558935)
    static let nestedAnchor = CGPoint(x: 606.44863, y: 595.56644)
    static let recursiveScale: CGFloat = 0.3602739726
    static let recursiveSourceCenter = CGPoint(x: 542.5, y: 534.5)
    /// Seconds into the zoom over which the outgoing ring fades. At 16pt the
    /// crescent's last frames read as a stray line, as in the macOS Notch.
    static let ringFadeStart = 0.8
    static let ringFadeEnd = 0.97
}

struct CommaLogoAnimationValues {
    var zoom: CGFloat = 1
    var translationX: CGFloat = 0
    var translationY: CGFloat = 0
    var nestedScale: CGFloat = 0.001
    /// The outgoing logo's own disk. Hidden under the zoom's aperture by the
    /// hold, so the loop's first and last frames are unchanged.
    var ringOpacity: CGFloat = 1

    static func animationFrame(elapsed rawElapsed: TimeInterval) -> Self {
        let cycleDuration =
            CommaLogoAnimationMetrics.zoomDuration
            + CommaLogoAnimationMetrics.holdDuration
        let elapsed = rawElapsed.truncatingRemainder(dividingBy: cycleDuration)
        guard elapsed < CommaLogoAnimationMetrics.zoomDuration else {
            return .init(
                zoom: CommaLogoAnimationMetrics.finalZoom,
                translationX: CommaLogoAnimationMetrics.finalTranslation.width,
                translationY: CommaLogoAnimationMetrics.finalTranslation.height,
                nestedScale: 1,
                ringOpacity: 0
            )
        }

        let zoomProgress = easedProgress(elapsed / CommaLogoAnimationMetrics.zoomDuration)
        let nestedProgress: CGFloat
        if elapsed <= CommaLogoAnimationMetrics.nestedDelay {
            nestedProgress = 0
        } else {
            nestedProgress = easedProgress(
                (elapsed - CommaLogoAnimationMetrics.nestedDelay)
                    / (CommaLogoAnimationMetrics.zoomDuration
                        - CommaLogoAnimationMetrics.nestedDelay)
            )
        }

        let ringFade = (elapsed - CommaLogoAnimationMetrics.ringFadeStart)
            / (CommaLogoAnimationMetrics.ringFadeEnd - CommaLogoAnimationMetrics.ringFadeStart)

        return .init(
            zoom: 1 + (CommaLogoAnimationMetrics.finalZoom - 1) * zoomProgress,
            translationX: CommaLogoAnimationMetrics.finalTranslation.width * zoomProgress,
            translationY: CommaLogoAnimationMetrics.finalTranslation.height * zoomProgress,
            nestedScale: 0.001 + 0.999 * nestedProgress,
            ringOpacity: 1 - CGFloat(min(max(ringFade, 0), 1))
        )
    }

    /// Solves the source animation's cubic-bezier(0.77, 0, 0.175, 1).
    private static func easedProgress(_ progress: Double) -> CGFloat {
        let target = min(max(progress, 0), 1)
        if target == 0 { return 0 }
        if target == 1 { return 1 }

        var lower = 0.0
        var upper = 1.0

        for _ in 0..<16 {
            let parameter = (lower + upper) / 2
            let inverse = 1 - parameter
            let x =
                3 * inverse * inverse * parameter * 0.77
                + 3 * inverse * parameter * parameter * 0.175
                + parameter * parameter * parameter
            if x < target {
                lower = parameter
            } else {
                upper = parameter
            }
        }

        let parameter = (lower + upper) / 2
        let inverse = 1 - parameter
        let y = 3 * inverse * parameter * parameter + parameter * parameter * parameter
        return CGFloat(y)
    }
}
