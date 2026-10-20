import SwiftUI
import UIKit
import CommaCore

/// What the Inbox's rows, swipes, menus and toolbar do. Clearing and archiving hide rows, so each offers
/// Undo through `offer`.
@MainActor
struct InboxActions {
    let store: CommaStore
    let inbox: InboxModel
    let offer: (InboxUndo) -> Void

    /// Opens the Task in the dock and reads the row, as opening it on the desktop does.
    func open(_ task: TaskSummary) {
        inbox.markRead([task])
        Task { await store.openTask(id: task.id) }
    }

    func toggleRead(_ task: TaskSummary) {
        if inbox.isUnread(task) { inbox.markRead([task]) } else { inbox.markUnread([task]) }
    }

    /// Hides rows until their Tasks update again; nothing on the server changes.
    func clear(_ tasks: [TaskSummary]) {
        guard !tasks.isEmpty else { return }
        inbox.clear(tasks)
        offer(InboxUndo(change: .cleared(tasks)))
    }

    /// An archive that already succeeded, such as from the shared Task menu.
    func archived(_ task: TaskSummary) { offer(InboxUndo(change: .archived(task))) }

    func undo(_ change: InboxUndo.Change) async {
        switch change {
        case .cleared(let tasks):
            inbox.undoClear(tasks)
        case .archived(let task):
            // Restoring needs the archived copy's version, which the Task's summary has.
            // Already restored elsewhere: nothing to take back.
            guard let archived = await store.summary(of: task.id), archived.isArchived else { return }
            await store.setTaskArchived(archived, archived: false)
        }
    }
}

extension View {
    /// An Inbox row's swipes and context menu. Leading: read or unread. Trailing: clear (the full swipe) and,
    /// for a Task in review, Mark as done. Archive stays in the menu. VoiceOver offers the swipes as actions.
    func inboxRowActions(_ task: TaskSummary, unread: Bool, actions: InboxActions,
                         rename: @escaping () -> Void, share: @escaping () -> Void) -> some View {
        swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { actions.toggleRead(task) } label: {
                Label { Text(unread ? "Read" : "Unread") } icon: { SwipeIcon.image("inbox-mark-unread") }
            }
            .tint(CommaTheme.brandSolid)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            ClearSwipe { actions.clear([task]) }
            MarkDoneSwipe(store: actions.store, task: task)
        }
        .contextMenu {
            Button { actions.toggleRead(task) } label: {
                Label(unread ? "Mark as read" : "Mark as unread", image: "inbox-mark-unread")
            }
            Button { actions.clear([task]) } label: { Label("Clear", image: "inbox-clear") }
            Divider()
            TaskActionMenuItems(store: actions.store, task: task, rename: rename, share: share,
                                archiveChanged: { actions.archived(task) })
        }
    }
}

/// The Clear swipe: a light fill with dark ink, the quiet action beside Mark as done. The system draws swipe
/// titles in white, so the glyph and title are drawn into the image (`SwipeIcon.titled`). At accessibility text
/// sizes the system sets every title under its capsule instead, in its own colour, so only the glyph is inked
/// and Clear stacks the way Mark as done does.
private struct ClearSwipe: View {
    let clear: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: clear) {
            if typeSize.isAccessibilitySize {
                Label { Text("Clear") } icon: { glyph }
            } else {
                Label { Text(verbatim: SwipeIcon.hairTitle) } icon: {
                    SwipeIcon.titled("inbox-clear", title: String(localized: "Clear"), ink: ink)
                }
            }
        }
        .tint(CommaTheme.borderPrimary)
        .accessibilityLabel("Clear")
    }

    /// The 16pt glyph alone, in `ink`.
    private var glyph: Image {
        let side: CGFloat = 16
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIImage(named: "inbox-clear")?.withTintColor(ink, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return Image(uiImage: drawn.withRenderingMode(.alwaysOriginal))
    }

    private var ink: UIColor {
        UIColor(CommaTheme.textPrimary).resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
    }
}
