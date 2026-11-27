import SwiftUI
import UIKit

/// Messages' drag to show times, for where messages came from: dragging the transcript to the left moves the person's
/// own messages with the finger, one to one until the strip beside them is open and rubber-banded past it, and
/// uncovers, beside each that came in from a chat platform, that platform's logo, which grows in as it is uncovered.
/// The agent's messages stay where they are. Letting go springs the rows back from the finger's speed.
enum SourceReveal {
    /// The strip the drag opens beside the person's messages.
    static let maxTravel: CGFloat = 56
    static let logoSize: CGFloat = 22
    /// Apple's rubber-band constant.
    private static let rubber: CGFloat = 0.55

    /// One to one with the finger until the strip is open, then the further past, the less it follows.
    static func travel(_ translation: CGFloat) -> CGFloat {
        let pull = max(0, -translation)
        guard pull > maxTravel else { return pull }
        let over = pull - maxTravel
        return maxTravel + over * maxTravel * rubber / (maxTravel + rubber * over)
    }

    /// The spring that takes the rows home, critically damped, starting at the finger's speed (`velocity`, points per
    /// second, positive to the right) so there is no seam between the drag and the return.
    static func release(from travel: CGFloat, velocity: CGFloat) -> Animation {
        let relative = travel > 0.5 ? Double(velocity / travel) : 0
        return .interpolatingSpring(Spring(response: 0.35, dampingRatio: 1), initialVelocity: relative)
    }

    /// The logo shipped for `platform`, or nil for a platform without one.
    static func logo(_ platform: String?) -> UIImage? {
        guard let platform, !platform.isEmpty else { return nil }
        return UIImage(named: "provider-" + platform)
    }
}

/// A person's row moved by the drag, with its platform logo in the strip it uncovers. The agent's rows pass `moves`
/// false and stay.
struct SourceRevealRow: ViewModifier {
    let moves: Bool
    /// The platform a person's message came in from; nil for every other row.
    let platform: String?
    let travel: CGFloat

    /// 0 at rest, 1 once the strip is open.
    private var progress: CGFloat { min(1, travel / SourceReveal.maxTravel) }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                if moves, let image = SourceReveal.logo(platform) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: SourceReveal.logoSize, height: SourceReveal.logoSize)
                        .clipShape(Circle())
                        // Grows in from half its size, visible only above half, as it is uncovered.
                        .scaleEffect(0.5 + 0.5 * progress)
                        .opacity(progress)
                        // Centred in the strip just past the row's trailing edge: off screen at rest. An offset, not an
                        // alignment guide: the overlay drew the logo over the bubble's end with the guide.
                        .offset(x: (SourceReveal.maxTravel + SourceReveal.logoSize) / 2)
                        .accessibilityHidden(true)
                }
            }
            .offset(x: moves ? -travel : 0)
    }
}

/// The pan behind the drag. It begins only for a leftward, mostly horizontal drag, so the transcript's scrolling, the
/// swipe to reply (rightward) and the router chat's close (rightward) keep theirs.
struct SourceRevealPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let changed: (CGFloat) -> Void
    /// The finger's horizontal speed as it let go, in points per second; 0 when the drag was cancelled.
    let ended: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) { pan.isEnabled = enabled }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .changed: changed(pan.translation(in: pan.view).x)
        case .ended: ended(pan.velocity(in: pan.view).x)
        case .cancelled, .failed: ended(0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.6
        }

        /// The drag never scrolls the transcript or runs alongside another pan, but it must not hold up taps.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(other.view is UIScrollView) && !(other is UIPanGestureRecognizer)
        }
    }
}
