import SwiftUI

private enum CommaLogoAnimationMetrics {
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

/// Swift form of the desktop `CommaLogoAnimation`, adapted from the macOS Notch host:
/// an endless zoom into the comma while Comma is thinking.
struct CommaLogoAnimation: View {
    var ink: Color = CommaTheme.textPrimary
    /// The surface the mark sits on; the nested comma's aperture is cut in this colour.
    var aperture: Color = CommaTheme.bgPrimary
    var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                CommaLogoFrame(values: .init(), ink: ink, aperture: aperture)
            } else {
                // One indicator per transcript, capped at 30 Hz.
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { timeline in
                    CommaLogoFrame(
                        values: .animationFrame(elapsed: timeline.date.timeIntervalSinceReferenceDate),
                        ink: ink, aperture: aperture
                    )
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct CommaLogoFrame: View {
    let values: CommaLogoAnimationValues
    let ink: Color
    let aperture: Color

    var body: some View {
        Canvas { context, size in
            let canvasScale = min(size.width, size.height) / CommaLogoAnimationMetrics.canvasSize
            let canvasOffset = CGPoint(
                x: (size.width - CommaLogoAnimationMetrics.canvasSize * canvasScale) / 2,
                y: (size.height - CommaLogoAnimationMetrics.canvasSize * canvasScale) / 2
            )
            var drawingContext = context
            drawingContext.translateBy(x: canvasOffset.x, y: canvasOffset.y)
            drawingContext.scaleBy(x: canvasScale, y: canvasScale)
            drawingContext.clip(to: Self.maskPath)

            let sceneTransform = CGAffineTransform(
                a: values.zoom,
                b: 0,
                c: 0,
                d: values.zoom,
                tx: values.translationX,
                ty: values.translationY
            )

            drawingContext.fill(
                Self.logoPath.applying(sceneTransform),
                with: .color(ink.opacity(values.ringOpacity))
            )
            drawingContext.fill(Self.commaPath.applying(sceneTransform), with: .color(ink))

            let nestedTransform = CGAffineTransform(
                translationX: CommaLogoAnimationMetrics.nestedAnchor.x,
                y: CommaLogoAnimationMetrics.nestedAnchor.y
            )
            .scaledBy(x: values.nestedScale, y: values.nestedScale)
            .translatedBy(
                x: -CommaLogoAnimationMetrics.nestedAnchor.x,
                y: -CommaLogoAnimationMetrics.nestedAnchor.y
            )

            let recursiveTransform = CGAffineTransform(
                translationX: CommaLogoAnimationMetrics.nestedAnchor.x,
                y: CommaLogoAnimationMetrics.nestedAnchor.y
            )
            .scaledBy(
                x: CommaLogoAnimationMetrics.recursiveScale,
                y: CommaLogoAnimationMetrics.recursiveScale
            )
            .translatedBy(
                x: -CommaLogoAnimationMetrics.recursiveSourceCenter.x,
                y: -CommaLogoAnimationMetrics.recursiveSourceCenter.y
            )

            let aperturePath = Self.nestedAperturePath
                .applying(recursiveTransform)
                .applying(nestedTransform)
                .applying(sceneTransform)
            let recursiveComma = Self.commaPath
                .applying(recursiveTransform)
                .applying(nestedTransform)
                .applying(sceneTransform)

            drawingContext.fill(aperturePath, with: .color(aperture))
            drawingContext.fill(recursiveComma, with: .color(ink))
        }
    }

    private static let maskPath = Path { path in
        path.move(to: CGPoint(x: 365, y: 0))
        path.addCurve(
            to: CGPoint(x: 730, y: 365),
            control1: CGPoint(x: 566.584, y: 0),
            control2: CGPoint(x: 730, y: 163.416)
        )
        path.addLine(to: CGPoint(x: 730, y: 395))
        path.addCurve(
            to: CGPoint(x: 395, y: 730),
            control1: CGPoint(x: 730, y: 580.015),
            control2: CGPoint(x: 580.015, y: 730)
        )
        path.addLine(to: CGPoint(x: 365, y: 730))
        path.addCurve(
            to: CGPoint(x: 0, y: 365),
            control1: CGPoint(x: 163.416, y: 730),
            control2: CGPoint(x: 0, y: 566.584)
        )
        path.addCurve(
            to: CGPoint(x: 365, y: 0),
            control1: CGPoint(x: 0, y: 163.416),
            control2: CGPoint(x: 163.416, y: 0)
        )
        path.closeSubpath()
    }

    private static let logoPath = Path { path in
        path.move(to: CGPoint(x: 365.205, y: 0))
        path.addCurve(
            to: CGPoint(x: 730.411, y: 365.205), control1: CGPoint(x: 566.902, y: 0),
            control2: CGPoint(x: 730.411, y: 163.508))
        path.addCurve(
            to: CGPoint(x: 721.737, y: 444.273), control1: CGPoint(x: 730.411, y: 392.364),
            control2: CGPoint(x: 727.389, y: 418.813))
        path.addCurve(
            to: CGPoint(x: 704.742, y: 445.605), control1: CGPoint(x: 719.941, y: 452.362),
            control2: CGPoint(x: 708.534, y: 452.973))
        path.addCurve(
            to: CGPoint(x: 628.529, y: 365.681), control1: CGPoint(x: 688.107, y: 413.29),
            control2: CGPoint(x: 662.342, y: 385.203))
        path.addCurve(
            to: CGPoint(x: 360.331, y: 437.565), control1: CGPoint(x: 534.639, y: 311.479),
            control2: CGPoint(x: 414.537, y: 343.676))
        path.addCurve(
            to: CGPoint(x: 432.215, y: 705.722), control1: CGPoint(x: 306.144, y: 531.45),
            control2: CGPoint(x: 338.338, y: 651.516))
        path.addCurve(
            to: CGPoint(x: 434.82, y: 707.198), control1: CGPoint(x: 433.08, y: 706.222),
            control2: CGPoint(x: 433.949, y: 706.715))
        path.addCurve(
            to: CGPoint(x: 432.968, y: 724.093), control1: CGPoint(x: 442.064, y: 711.222),
            control2: CGPoint(x: 441.112, y: 722.559))
        path.addCurve(
            to: CGPoint(x: 365.205, y: 730.411), control1: CGPoint(x: 411.011, y: 728.229),
            control2: CGPoint(x: 388.362, y: 730.411))
        path.addCurve(
            to: CGPoint(x: 0, y: 365.205), control1: CGPoint(x: 163.51, y: 730.411),
            control2: CGPoint(x: 0.00300803, y: 566.9))
        path.addCurve(
            to: CGPoint(x: 365.205, y: 0), control1: CGPoint(x: 0.000195125, y: 163.508),
            control2: CGPoint(x: 163.508, y: 0.000175857))
        path.closeSubpath()
    }

    private static let commaPath = Path { path in
        path.move(to: CGPoint(x: 429.061, y: 468.826))
        path.addCurve(
            to: CGPoint(x: 608.03, y: 420.871), control1: CGPoint(x: 465.24, y: 406.162),
            control2: CGPoint(x: 545.367, y: 384.693))
        path.addCurve(
            to: CGPoint(x: 660.141, y: 592.052), control1: CGPoint(x: 668.125, y: 455.568),
            control2: CGPoint(x: 690.333, y: 530.683))
        path.addCurve(
            to: CGPoint(x: 660.366, y: 592.27), control1: CGPoint(x: 660.216, y: 592.125),
            control2: CGPoint(x: 660.291, y: 592.197))
        path.addCurve(
            to: CGPoint(x: 656.801, y: 598.406), control1: CGPoint(x: 659.322, y: 594.203),
            control2: CGPoint(x: 658.133, y: 596.254))
        path.addCurve(
            to: CGPoint(x: 655.986, y: 599.84), control1: CGPoint(x: 656.532, y: 598.885),
            control2: CGPoint(x: 656.261, y: 599.364))
        path.addCurve(
            to: CGPoint(x: 631.448, y: 630.594), control1: CGPoint(x: 649.213, y: 611.571),
            control2: CGPoint(x: 640.898, y: 621.858))
        path.addCurve(
            to: CGPoint(x: 480.175, y: 708.083), control1: CGPoint(x: 600.921, y: 662.613),
            control2: CGPoint(x: 550.308, y: 698.191))
        path.addCurve(
            to: CGPoint(x: 477.946, y: 703.31), control1: CGPoint(x: 477.447, y: 708.468),
            control2: CGPoint(x: 475.903, y: 705.159))
        path.addCurve(
            to: CGPoint(x: 520.57, y: 663.529), control1: CGPoint(x: 490.729, y: 691.748),
            control2: CGPoint(x: 505.726, y: 678.045))
        path.addCurve(
            to: CGPoint(x: 477.015, y: 647.796), control1: CGPoint(x: 505.64, y: 660.994),
            control2: CGPoint(x: 490.898, y: 655.812))
        path.addCurve(
            to: CGPoint(x: 429.061, y: 468.826), control1: CGPoint(x: 414.351, y: 611.617),
            control2: CGPoint(x: 392.882, y: 531.489))
        path.closeSubpath()
    }

    private static let nestedAperturePath = Path(
        ellipseIn: CGRect(x: 334.02307818, y: 339.36314038, width: 392.66472374, height: 392.66472374)
    )
}
