import SwiftUI
import CommaCore

/// One Task panel over the app, minimized to a bottom bar or leading rail. Dragging the bar or
/// header follows the finger between minimized and expanded positions. The panel is sized once to the full sheet and only translated while dragging,
/// so the drag never re-lays out SwiftUI content; release uses a velocity-carrying spring.
struct TaskDockHost: UIViewControllerRepresentable {
    let store: CommaStore
    let pane: ConversationPane
    /// Advances on every request to show a Task, including the one already open.
    let revealRequest: Int
    var placement: TaskDockPlacement = .bottom
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
        let controller = TaskDockViewController(store: store, pane: pane, revealRequest: revealRequest, placement: placement, onExpand: onExpand)
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
        controller.update(pane: pane, revealRequest: revealRequest, placement: placement)
    }
}

/// Presentation geometry only; the same Task pane survives changes between these layouts.
enum TaskDockPlacement: Equatable {
    case bottom
    case leading(width: CGFloat, gap: CGFloat = 0)

    var columnGap: CGFloat {
        if case .leading(_, let gap) = self { return gap }
        return 0
    }

    var isLeading: Bool {
        if case .leading = self { return true }
        return false
    }

    static func resolve(size: CGSize, leadingInset: CGFloat, folded: Bool, division: CGRect?) -> Self {
        let columns = ShellColumnLayout(width: size.width, folded: folded, division: division)
        guard size.width > size.height,
              size.width - columns.gap >= ShellTabs.minimumColumnWidth * 2,
              columns.leadingWidth > 0, columns.trailingWidth > 0 else { return .bottom }
        return .leading(width: columns.leadingWidth + leadingInset, gap: columns.gap)
    }
}
