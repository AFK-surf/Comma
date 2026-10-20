import UIKit

/// A finger holding the router chat: a downward drag on its header, or a drag toward the trailing edge that starts
/// in the leading third of the screen and not on a message, which that drag answers instead, like going back. The
/// chat moves along the path it zooms on, shrinking toward its button with the edge facing the finger (the top, or
/// the leading edge) under the finger. Let go far or fast enough and it carries on into the button at the finger's
/// speed; otherwise it springs back open along the same path.
struct RouterHold {
    enum Axis { case down, trailing }

    let axis: Axis
    /// Where the chat was when the finger took hold, its corners already the card's.
    let start: RouterZoomFrame
    /// The router button, where the path ends.
    let closed: RouterZoomFrame
    /// How far the edge facing the finger travels from `start` to the button.
    let reach: CGFloat
    /// When the finger last moved. A finger that rests before letting go has no speed left, though the pan still
    /// reports the speed of its last movement.
    var moved = CACurrentMediaTime()

    init(axis: Axis, start: RouterZoomFrame, closed: RouterZoomFrame, trailing: CGFloat) {
        self.axis = axis
        self.start = start.rounded
        self.closed = closed
        let travel = switch axis {
        case .down: closed.rect.minY - start.rect.minY
        case .trailing: trailing > 0 ? closed.rect.minX - start.rect.minX : start.rect.maxX - closed.rect.maxX
        }
        reach = max(1, travel)
    }

    /// How far `translation` carries the chat toward closing; negative the other way.
    func pull(_ translation: CGPoint, trailing: CGFloat) -> CGFloat {
        axis == .down ? translation.y : translation.x * trailing
    }

    /// How far along the path `translation` puts the chat, from 0 where the finger took hold to 1 in the button.
    func progress(_ translation: CGPoint, trailing: CGFloat) -> CGFloat {
        min(1, max(0, pull(translation, trailing: trailing) / reach))
    }

    func frame(at progress: CGFloat) -> RouterZoomFrame { .between(start, closed, progress) }
}

extension RouterLayerController: UIGestureRecognizerDelegate {
    func installDrag() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    /// The navigation bar's band: there a drag down closes; below it, vertical drags belong to the transcript.
    private var headerZone: CGFloat { view.safeAreaInsets.top + 52 }
    /// 1 when the trailing edge is on the right, -1 when it is on the left.
    private var trailing: CGFloat { view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1 }

    /// Whether `point` lies in the leading third of the screen, where a drag toward the trailing edge closes. A
    /// sideways drag further in belongs to what is under it.
    private func inLeadingZone(_ point: CGPoint) -> Bool {
        let reach = view.bounds.width / 3
        return trailing > 0 ? point.x <= view.bounds.minX + reach : point.x >= view.bounds.maxX - reach
    }

    /// Which way `pan` closes the chat, or nil when it belongs to what is under it.
    private func axis(of pan: UIPanGestureRecognizer) -> RouterHold.Axis? {
        let velocity = pan.velocity(in: view)
        let location = pan.location(in: view), translation = pan.translation(in: view)
        let origin = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
        if origin.y <= headerZone, velocity.y > 0, velocity.y >= abs(velocity.x) { return .down }
        // A sideways drag on a message is a reply (`ReplySwipe`); from the leading third, between messages, it closes.
        let routerPane = hosting.rootView.content.store.router.pane.map(ObjectIdentifier.init)
        if inLeadingZone(origin), velocity.x * trailing > 0, abs(velocity.x) > abs(velocity.y), !scrollsSideways(at: origin),
           !ReplySwipeRegions.shared.claims(view.convert(origin, to: nil), in: routerPane) { return .trailing }
        return nil
    }

    /// A sideways scroller under the finger, like a wide code block, keeps sideways drags.
    private func scrollsSideways(at point: CGPoint) -> Bool {
        var candidate = view.hitTest(point, with: nil)
        while let current = candidate, current !== view {
            if let scroller = current as? UIScrollView, scroller.isScrollEnabled,
               scroller.contentSize.width > scroller.bounds.width + 1 { return true }
            candidate = current.superview
        }
        return false
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { open }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
        return axis(of: pan) != nil
    }

    /// The toolbar's tap recognizers must not block the drag; a tap fails on its own once the finger moves.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(other.view is UIScrollView)
    }

    /// Scrolling waits for the drag to decline, so a sideways drag never scrolls the transcript too.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other === (other.view as? UIScrollView)?.panGestureRecognizer
    }

    @objc private func handleDrag(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            guard let axis = axis(of: pan) else { return }
            view.endEditing(true)
            // The chat is held from here, without the few points the drag took to start; grabbed mid-zoom, it
            // stops where it is on screen.
            pan.setTranslation(.zero, in: view)
            hold = RouterHold(axis: axis, start: stopZoom(), closed: closedFrame, trailing: trailing)
        case .changed:
            guard var current = hold else { return }
            current.moved = CACurrentMediaTime()
            hold = current
            place(current.frame(at: current.progress(pan.translation(in: view), trailing: trailing)))
        case .ended, .cancelled, .failed:
            guard let hold else { return }
            self.hold = nil
            let resting = CACurrentMediaTime() - hold.moved > 0.05
            let speed = resting ? 0 : hold.pull(pan.velocity(in: view), trailing: trailing) / hold.reach
            let progress = hold.progress(pan.translation(in: view), trailing: trailing)
            // Where a flick would carry the chat, with UIScrollView's normal deceleration rate.
            let projected = progress + speed * 0.998 / (1 - 0.998) / 1000
            let closes = pan.state == .ended && projected > 0.3
            // The spring takes the finger's speed as a fraction of the distance left to go.
            let remaining = closes ? 1 - progress : progress
            move(open: !closes, velocity: remaining > 0.01 ? (closes ? speed : -speed) / remaining : 0)
            if closes { navigation.closeRouter() }
        default:
            break
        }
    }
}

/// Passes touches through while the router chat is closed, and closes it on the VoiceOver escape gesture.
final class RouterContainerView: UIView {
    weak var controller: RouterLayerController?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard controller?.open == true else { return nil }
        return super.hitTest(point, with: event)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard let controller, controller.open else { return false }
        controller.close()
        return true
    }
}
