import SwiftUI
import CommaCore

/// The open Task as one UIKit panel over the app. Minimized, only its bar (close, title, status) shows
/// at the bottom edge; dragging the bar or the expanded sheet's header follows the finger between the
/// bar and a full sheet. The panel is sized once to the full sheet and only translated while dragging,
/// so the drag never re-lays out SwiftUI content; release uses a velocity-carrying spring.
struct TaskDockHost: UIViewControllerRepresentable {
    let store: CommaStore
    let pane: ConversationPane
    /// Advances on every request to show a Task, including the one already open.
    let revealRequest: Int
    let onExpand: () -> Void
    /// Fires once the opening sheet has finished rising (or the user has taken hold of it), so the app
    /// behind can make room for the bar while the sheet still covers it.
    var onSettled: () -> Void = {}
    /// Fires when the close button starts sliding the sheet away, so the app behind can take back the
    /// bar's room underneath it.
    var onDismissing: () -> Void = {}
    /// Fires when the sheet comes to rest minimized (true) or starts to rise (false).
    var onCovered: (Bool) -> Void = { _ in }

    func makeUIViewController(context: Context) -> TaskDockViewController {
        let controller = TaskDockViewController(store: store, pane: pane, revealRequest: revealRequest, onExpand: onExpand)
        controller.onSettled = onSettled
        controller.onDismissing = onDismissing
        controller.onCovered = onCovered
        return controller
    }

    func updateUIViewController(_ controller: TaskDockViewController, context: Context) {
        controller.onExpand = onExpand
        controller.onSettled = onSettled
        controller.onDismissing = onDismissing
        controller.onCovered = onCovered
        controller.update(pane: pane, revealRequest: revealRequest)
    }
}
