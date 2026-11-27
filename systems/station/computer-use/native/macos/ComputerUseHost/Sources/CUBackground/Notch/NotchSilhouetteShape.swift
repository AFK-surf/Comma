import SwiftUI

/// Authentic macOS Notch / Dynamic Island silhouette:
/// - On legacy notched and non-notched displays (`topCornerRadius == 0`), renders a
///   top-flush body with continuous-curvature bottom corners plus concave top-left &
///   top-right bezel ears that fuse seamlessly into the display's top edge.
/// - On floating Dynamic Island displays (`earRadius == 0`, `topCornerRadius > 0`),
///   renders an all-around continuous rounded pill / capsule floating below the bezel.
public struct NotchSilhouetteShape: Shape {
    public var earRadius: CGFloat
    public var bottomCornerRadius: CGFloat
    public var topCornerRadius: CGFloat

    public init(
        earRadius: CGFloat = 14,
        bottomCornerRadius: CGFloat = 32,
        topCornerRadius: CGFloat = 0
    ) {
        self.earRadius = earRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.topCornerRadius = topCornerRadius
    }

    public var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(earRadius, AnimatablePair(bottomCornerRadius, topCornerRadius)) }
        set {
            earRadius = newValue.first
            bottomCornerRadius = newValue.second.first
            topCornerRadius = newValue.second.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        guard rect.height > 0.5, rect.width > 1 else { return Path() }
        let e = max(0, min(earRadius, rect.width * 0.25, rect.height * 0.45))
        let body = CGRect(
            x: rect.minX + e,
            y: rect.minY,
            width: rect.width - 2 * e,
            height: rect.height
        )
        let r = max(0, min(bottomCornerRadius, body.width * 0.5, body.height))
        let topR: CGFloat = e > 0.5
            ? 0
            : max(0, min(topCornerRadius, min(body.width * 0.5, body.height * 0.5)))
        let botR: CGFloat = topR > 0 ? min(r, body.height - topR) : r
        let bodyPath = UnevenRoundedRectangle(
            topLeadingRadius: topR,
            bottomLeadingRadius: botR,
            bottomTrailingRadius: botR,
            topTrailingRadius: topR,
            style: .continuous
        ).path(in: body)
        guard e > 0.5 else { return bodyPath }

        // Concave ears. Each overlaps the straight upper wall of the body by 1pt so
        // the union leaves no anti-aliased seam. Control points sit past the
        // circular 0.552 handle for a softer, continuous entry into the top edge.
        let k: CGFloat = 0.62
        var ears = Path()
        ears.move(to: CGPoint(x: body.minX + 1, y: rect.minY))
        ears.addLine(to: CGPoint(x: body.minX + 1, y: rect.minY + e))
        ears.addLine(to: CGPoint(x: body.minX, y: rect.minY + e))
        ears.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control1: CGPoint(x: body.minX, y: rect.minY + e * (1 - k)),
            control2: CGPoint(x: body.minX - e * (1 - k), y: rect.minY)
        )
        ears.closeSubpath()

        ears.move(to: CGPoint(x: body.maxX - 1, y: rect.minY))
        ears.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        ears.addCurve(
            to: CGPoint(x: body.maxX, y: rect.minY + e),
            control1: CGPoint(x: body.maxX + e * (1 - k), y: rect.minY),
            control2: CGPoint(x: body.maxX, y: rect.minY + e * (1 - k))
        )
        ears.addLine(to: CGPoint(x: body.maxX - 1, y: rect.minY + e))
        ears.closeSubpath()

        return bodyPath.union(ears)
    }
}
