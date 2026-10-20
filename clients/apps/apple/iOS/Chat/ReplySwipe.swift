import SwiftUI
import UIKit

/// Where on screen a sideways drag means reply: the rows in view that can be replied to, in window coordinates,
/// kept per conversation pane. The router chat closes on a sideways drag too; it yields to its own pane's rows,
/// keeping the leading edge and the space between messages. A conversation still mounted under the router chat
/// reports into its own pane and never claims the router's drags. Only rows on screen report, and a row leaving
/// the screen removes itself.
@MainActor final class ReplySwipeRegions {
    static let shared = ReplySwipeRegions()
    /// Drags starting this close to the leading edge are the system's or the router chat's, never a reply.
    static let edge: CGFloat = 24
    private var frames: [ObjectIdentifier: [String: CGRect]] = [:]

    func set(_ id: String, in pane: ObjectIdentifier, _ frame: CGRect?) {
        frames[pane, default: [:]][id] = frame
        if frames[pane]?.isEmpty == true { frames[pane] = nil }
    }

    func claims(_ point: CGPoint, in pane: ObjectIdentifier?) -> Bool {
        guard let pane, point.x > Self.edge else { return false }
        return frames[pane]?.values.contains { $0.contains(point) } ?? false
    }
}

/// Messages' swipe to reply: a bubble dragged to the right follows the finger under growing resistance, uncovering a
/// reply glyph that stays where the bubble rested and sharpens as it is revealed; letting go once it is armed opens
/// the bubble's thread. A UIKit pan that declines unless the touch starts out sideways and to the right, so the
/// transcript's own scrolling (and the keyboard dismissal it drives) never waits on it; it also ignores the leading
/// edge, where the back gesture lives.
struct ReplySwipe: ViewModifier {
    let id: String
    /// The conversation pane the row belongs to, which scopes its swipe region.
    let pane: ObjectIdentifier
    let enabled: Bool
    let action: () -> Void

    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The most the bubble travels however far the finger goes, and the travel at which letting go replies.
    private static let maxTravel: CGFloat = 56
    private static let threshold: CGFloat = 40

    private var armed: Bool { offset >= Self.threshold }
    /// 0 at rest, 1 once armed.
    private var progress: CGFloat { min(1, offset / Self.threshold) }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            // Behind the bubble's resting place, fixed: the bubble slides off it rather than carrying it.
            .background(alignment: .leading) {
                CentralIcon("central-arrow-share-left-fill", size: 22)
                    .foregroundStyle(CommaTheme.textTertiary)
                    .opacity(max(0, (progress - 0.35) / 0.65))
                    .blur(radius: reduceMotion ? 0 : (1 - progress) * 4)
                    .scaleEffect(armed ? 1 : 0.7 + 0.2 * progress)
                    .animation(reduceMotion ? nil : CommaMotion.release, value: armed)
                    .padding(.leading, 6)
                    .accessibilityHidden(true)
            }
            .gesture(ReplyPan(enabled: enabled, changed: pulled, ended: released))
            // Nil while disabled, so turning the swipe back on reports the frame again although the row did not move.
            .onGeometryChange(for: CGRect?.self) { [enabled] in enabled ? $0.frame(in: .global) : nil } action: { frame in
                ReplySwipeRegions.shared.set(id, in: pane, frame)
            }
            .onDisappear { ReplySwipeRegions.shared.set(id, in: pane, nil) }
            .sensoryFeedback(.impact(weight: .light), trigger: armed) { _, now in now }
    }

    /// Follows the finger at first, then gives less and less, never passing `maxTravel`.
    private func pulled(_ translation: CGFloat) {
        let pull = max(0, translation)
        offset = Self.maxTravel * (1 - exp(-pull * 1.2 / Self.maxTravel))
    }

    private func released(_ completed: Bool) {
        if completed && armed { action() }
        withAnimation(reduceMotion ? CommaMotion.stateChange : CommaMotion.release) { offset = 0 }
    }
}

/// The pan behind `ReplySwipe`. It begins only for a rightward, mostly horizontal drag away from the leading edge.
private struct ReplyPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let changed: (CGFloat) -> Void
    let ended: (Bool) -> Void

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
        case .ended: ended(true)
        case .cancelled, .failed: ended(false)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            let location = pan.location(in: nil), translation = pan.translation(in: nil)
            return location.x - translation.x > ReplySwipeRegions.edge
                && velocity.x > 0 && abs(velocity.x) > abs(velocity.y) * 1.6
        }

        /// A sideways reply never scrolls the transcript, but it must not hold up anything else under the finger.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(other.view is UIScrollView)
        }
    }
}
