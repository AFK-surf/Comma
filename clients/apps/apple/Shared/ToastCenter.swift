import Foundation
import Observation

/// A short notice over the app, as the desktop's toast: what happened, its kind, and at most one thing to do about
/// it. It reports what went wrong with something the member did, or with work going on in the background, while the
/// page keeps its content. A page that has nothing to show for a failure says so in place instead.
struct Toast: Identifiable {
    enum Intent { case info, success, warning, error }

    struct Action {
        let title: String
        let perform: () -> Void
    }

    /// The same id shown again updates the toast in place rather than raising another.
    let id: String
    let intent: Intent
    let message: String
    var action: Action?
    /// A failure of what the member just did, which the toast answers with the error haptic. Background failures
    /// arrive silently.
    var answersMember = false
    /// Runs when the toast leaves without its action being taken: it timed out or was swiped away. A toast another
    /// replaces is not dismissed; it waits and comes back.
    var dismissed: (() -> Void)?
}

/// The one toast the app shows at a time. A toast with a new id goes over the one showing, which waits under it and
/// comes back once the newer one leaves, so two failures at once both reach the member; the same id updates in place.
@MainActor @Observable
final class ToastCenter {
    private(set) var current: Toast?
    /// Advances with every show, so a toast shown again starts its time on screen over.
    private(set) var revision = 0
    /// The toasts newer ones went over, the latest last.
    @ObservationIgnored private var waiting: [Toast] = []

    func show(_ toast: Toast) {
        waiting.removeAll { $0.id == toast.id }
        if let current, current.id != toast.id {
            // Its haptic answered the member when it first showed; coming back, it arrives silently.
            var held = current
            held.answersMember = false
            waiting.append(held)
        }
        current = toast
        revision += 1
    }

    /// Takes the toast with `id` away, or whichever is showing.
    func dismiss(_ id: String? = nil) {
        guard let current, id == nil || current.id == id else { return }
        self.current = nil
        current.dismissed?()
        resume()
    }

    /// Takes the toast with `id` away, showing or waiting, because what it reported is over (the failure cleared, its
    /// surface left the screen); it does not count as dismissed.
    func withdraw(_ id: String) {
        waiting.removeAll { $0.id == id }
        guard current?.id == id else { return }
        current = nil
        resume()
    }

    /// Takes away whatever shows or waits without counting it as dismissed: what it reported belonged to a product that
    /// is gone.
    func clear() {
        waiting = []
        current = nil
    }

    /// Takes the toast away and runs its action.
    func perform() {
        guard let current else { return }
        self.current = nil
        current.action?.perform()
        resume()
    }

    /// Brings back the toast the one leaving went over, if nothing else took its place meanwhile.
    private func resume() {
        guard current == nil, let next = waiting.popLast() else { return }
        current = next
        revision += 1
    }
}
