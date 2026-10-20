import SwiftUI
import UIKit
import CommaCore

// MARK: Interaction

extension TaskDockViewController {
    /// The strip-above-the-sheet tap only sees touches outside the panel, so it never competes with the
    /// header's buttons or the card's own controls.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard recognizer === outsideTap else { return true }
        return state.detailsOpen && !panel.frame.contains(touch.location(in: view))
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
        // The open details own every touch until they close.
        if state.detailsOpen { return false }
        // The grabber and header own the drag; the transcript keeps its own scrolling.
        let location = pan.location(in: panel)
        let velocity = pan.velocity(in: panel)
        return location.y <= Self.barHeight && abs(velocity.y) >= abs(velocity.x)
    }

    /// SwiftUI's own recognizers in the header (the title tap, the close button) must not block the drag;
    /// a tap still fails on its own once the finger moves.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(other.view is UIScrollView)
    }

    @objc func handlePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            cancelDismissal()
            settle()
            stopAtPresentation()
            state.covered = false
            dragStart = progress
            if progress <= 0.5, pan.velocity(in: view).y < 0 { onExpand() }
            view.endEditing(true)
        case .changed:
            let raw = dragStart - pan.translation(in: view).y / travel
            // Rubber-band past either end, like a sheet at its detent limits.
            apply(raw > 1 ? 1 + (raw - 1) * 0.12 : raw < 0 ? raw * 0.12 : raw)
        case .ended, .cancelled, .failed:
            let velocity = -pan.velocity(in: view).y / travel
            // Where a flick would carry the sheet, with UIScrollView's normal deceleration rate, as the
            // router chat decides; the spring then carries on at the finger's speed.
            let projected = progress + velocity * 0.998 / (1 - 0.998) / 1000
            animate(to: projected > 0.5 ? 1 : 0, velocity: velocity)
        default:
            break
        }
    }

    /// Closing slides the sheet off the bottom while the dim behind it fades in place; the Task is
    /// removed only once the sheet is gone, so nothing behind it moves with it. `archiving` leaves the same
    /// way and archives once the sheet is gone; taking the sheet back mid-close keeps the Task unarchived.
    func dismiss(archiving task: TaskSummary? = nil) {
        guard !dismissing else { return }
        dismissing = true
        view.endEditing(true)
        state.detailsOpen = false
        stopAtPresentation()
        let offscreen = -(Self.barHeight + safeBottom + 24) / travel
        let spring = UISpringTimingParameters(mass: 1, stiffness: 320, damping: 34, initialVelocity: .zero)
        let closing = UIViewPropertyAnimator(duration: 0, timingParameters: spring)
        closing.addAnimations { self.apply(offscreen) }
        closing.addCompletion { [weak self] position in
            guard let self, position == .end, self.dismissing else { return }
            self.animator = nil
            guard let task else { return self.store.closeTask() }
            let store = self.store
            Task {
                // Success closes the Task; a refused archive closes it too, and the list behind shows why.
                if await !store.setTaskArchived(task, archived: true), store.task?.taskID == task.id { store.closeTask() }
            }
        }
        closing.startAnimation()
        // Held as the current animation, so a reveal or a drag can take the sheet back mid-close.
        animator = closing
        onDismissing()
    }

    func toggle() {
        if progress <= 0.5 { onExpand() }
        animate(to: progress > 0.5 ? 0 : 1, velocity: 0)
    }

    func animate(to target: CGFloat, velocity: CGFloat) {
        // The spring's speed is relative to the distance left from where the panel is drawn, not from where
        // an interrupted spring was heading.
        stopAtPresentation()
        cancelDismissal()
        let distance = target - progress
        let relative = abs(distance) > 0.001 ? max(-20, min(20, velocity / distance)) : 0
        // Close to the system sheet spring; the finger's speed carries into the settle.
        let spring = UISpringTimingParameters(mass: 1, stiffness: 320, damping: 34,
                                              initialVelocity: CGVector(dx: 0, dy: relative))
        let animator = UIViewPropertyAnimator(duration: 0, timingParameters: spring)
        animator.addAnimations { self.apply(target) }
        // The transcript wakes as soon as it may show, and rests only once the bar has covered it.
        if target > 0 { state.covered = false }
        animator.addCompletion { [weak self] position in
            guard let self else { return }
            self.animator = nil
            if position == .end, target <= 0 { self.state.covered = true }
            self.settle()
        }
        animator.startAnimation()
        self.animator = animator
        if target < 0.5 {
            view.endEditing(true)
            state.detailsOpen = false
        }
    }

    /// Stops a running spring where it currently draws the panel, so whatever follows starts from there.
    private func stopAtPresentation() {
        defer { self.animator = nil }
        guard let animator, animator.isRunning else { return }
        animator.stopAnimation(true)
        let drawn = panel.layer.presentation()?.affineTransform().ty ?? panel.transform.ty
        apply(1 - drawn / travel)
    }

    @objc func handleOutsideTap(_ tap: UITapGestureRecognizer) {
        guard state.detailsOpen, !panel.frame.contains(tap.location(in: view)) else { return }
        state.detailsOpen = false
    }

    /// Expanded, the header opens the Task details; minimized, it raises the sheet as before.
    func headerTapped() {
        guard progress > 0.5 else { return toggle() }
        view.endEditing(true)
        state.detailsOpen.toggle()
    }

    /// A reveal or a drag during the close keeps the Task: the close is called off and the app behind
    /// makes room for the bar again once the sheet settles.
    private func cancelDismissal() {
        guard dismissing else { return }
        dismissing = false
        settled = false
    }

    private func settle() {
        guard !settled else { return }
        settled = true
        onSettled()
    }

    /// Touches outside the panel reach the app while minimized; expanded, the sheet takes them all.
    fileprivate func owns(_ point: CGPoint) -> Bool {
        progress > 0.5 || panel.frame.contains(point)
    }
}

// MARK: Keyboard

extension TaskDockViewController {
    func updateInsets() {
        let inset = max(keyboardOverlap, safeBottom)
        if state.bottomInset != inset { state.bottomInset = inset }
        if state.sideInset != safeSides { state.sideInset = safeSides }
    }

    /// Only the transcript's bottom inset follows the keyboard. SwiftUI lays the conversation out once at the
    /// new inset on its own update and moves it on the keyboard's curve; nothing is laid out in this call.
    @objc func keyboardWillChange(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = view.window else { return }
        let overlap = max(0, window.bounds.maxY - window.convert(end, from: nil).minY)
        guard abs(overlap - keyboardOverlap) > 0.5 else { return }
        keyboardOverlap = overlap
        withAnimation(Self.keyboardAnimation(note)) { updateInsets() }
    }

    /// The keyboard's own motion, for SwiftUI. UIKit builds curve 7 as a spring of mass 3, stiffness 1000 and
    /// damping 500 (critically damped, response 0.34) whatever the notification's duration; a zero duration
    /// means the keyboard jumps, and so does the transcript.
    private static func keyboardAnimation(_ note: Notification) -> Animation? {
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 7
        guard duration > 0 else { return nil }
        return curve == 7 ? .spring(Spring(mass: 3, stiffness: 1000, damping: 500)) : .easeInOut(duration: duration)
    }
}

/// A full-screen container that only keeps the touches the dock wants.
final class PassthroughView: UIView {
    weak var dock: TaskDockViewController?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let dock, dock.owns(point) else { return nil }
        return super.hitTest(point, with: event) ?? self
    }
}

/// Hosts the chrome and passes through touches the chrome does not claim.
final class ChromeLayerView: UIView {
    var accepts: (CGPoint) -> Bool = { _ in true }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard accepts(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}
