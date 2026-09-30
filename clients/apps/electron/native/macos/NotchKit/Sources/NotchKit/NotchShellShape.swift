import SwiftUI

struct NotchShellShape: Shape {
    var cornerRadius: CGFloat
    var shoulderInset: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(cornerRadius, shoulderInset) }
        set {
            cornerRadius = newValue.first
            shoulderInset = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else {
            return Path()
        }

        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let inset = min(shoulderInset, rect.width / 2, rect.height / 2)
        let bezierQuarterCircle = inset * 0.552_284_749_8

        let bodyMinX = rect.minX + inset
        let bodyMaxX = rect.maxX - inset
        let top = rect.minY
        let bottom = rect.maxY

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: top))

        if inset > 0 {
            path.addCurve(
                to: CGPoint(x: bodyMaxX, y: top + inset),
                control1: CGPoint(x: rect.maxX - bezierQuarterCircle, y: top),
                control2: CGPoint(x: bodyMaxX, y: top + inset - bezierQuarterCircle)
            )
        }

        path.addLine(to: CGPoint(x: bodyMaxX, y: bottom - radius))
        path.addQuadCurve(
            to: CGPoint(x: bodyMaxX - radius, y: bottom),
            control: CGPoint(x: bodyMaxX, y: bottom)
        )
        path.addLine(to: CGPoint(x: bodyMinX + radius, y: bottom))
        path.addQuadCurve(
            to: CGPoint(x: bodyMinX, y: bottom - radius),
            control: CGPoint(x: bodyMinX, y: bottom)
        )
        path.addLine(to: CGPoint(x: bodyMinX, y: top + inset))

        if inset > 0 {
            path.addCurve(
                to: CGPoint(x: rect.minX, y: top),
                control1: CGPoint(x: bodyMinX, y: top + inset - bezierQuarterCircle),
                control2: CGPoint(x: rect.minX + bezierQuarterCircle, y: top)
            )
        }

        path.closeSubpath()

        return path
    }
}
