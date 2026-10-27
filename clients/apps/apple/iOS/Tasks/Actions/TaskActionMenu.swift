import SwiftUI
import CommaCore

/// The Task actions offered from a list row's context menu and from the open Task's header menu, with the
/// desktop's glyphs for the same actions. One the core says a Task cannot take (`TaskSummary.unsupported`) is not offered.
struct TaskActionMenuItems: View {
    let store: CommaStore
    let task: TaskSummary
    let rename: () -> Void
    let share: () -> Void
    /// Runs once Archive or Restore succeeds, so a list of archived Tasks can drop the row.
    var archiveChanged: () -> Void = {}
    /// Archives through the caller instead: the open Task's sheet leaves the way its close does, then archives.
    var archive: (() -> Void)?

    /// Archive, Restore and Mark as done look the same in menus and in the rows' swipe actions.
    static let archiveIcon = "icon-archive"
    static let restoreIcon = "central-arrow-out-of-box"
    static let doneIcon = "central-circle-check"

    var body: some View {
        let pinned = store.pinnedTaskIDs.contains(task.id)
        // The desktop's Done: accepting the result of a Task in review.
        if task.canAcceptReview {
            Button { Task { await store.acceptTaskReview(task) } } label: { Label("Mark as done", image: Self.doneIcon) }
            Divider()
        }
        Button(action: rename) { Label("Rename", image: "central-edit-big") }
        if !task.isArchived, !task.unsupported.contains("pin") {
            Button {
                Task { await store.setTaskPinned(id: task.id, pinned: !pinned) }
            } label: {
                if pinned { Label("Unpin", image: "central-unpin") } else { Label("Pin", image: "central-pin") }
            }
        }
        // The desktop shares a Task as a link.
        if !task.unsupported.contains("share") {
            Button(action: share) { Label("Share", image: "central-chain-link-4") }
        }
        if !task.unsupported.contains("archive") {
            Divider()
            if task.isArchived {
                Button { setArchived(false) } label: { Label("Restore", image: Self.restoreIcon) }
            } else {
                Button { if let archive { archive() } else { setArchived(true) } } label: {
                    Label("Archive", image: Self.archiveIcon)
                }
                    .archiveAvailability(of: task)
            }
        }
    }

    private func setArchived(_ archived: Bool) {
        Task { if await store.setTaskArchived(task, archived: archived) { archiveChanged() } }
    }
}

/// The Mark as done swipe for a Task in review, the same in every list that offers it (Home, the Inbox).
struct MarkDoneSwipe: View {
    let store: CommaStore
    let task: TaskSummary

    var body: some View {
        if task.canAcceptReview {
            Button { Task { await store.acceptTaskReview(task) } } label: {
                Label { Text("Mark as done") } icon: { SwipeIcon.image(TaskActionMenuItems.doneIcon) }
            }
            .tint(CommaTheme.successPrimary)
        }
    }
}

extension View {
    /// The rename prompt and share sheet that `TaskActionMenuItems` opens.
    func taskActionSheets(store: CommaStore, renaming: Binding<TaskSummary?>, sharing: Binding<TaskSummary?>) -> some View {
        modifier(TaskActionSheets(store: store, renaming: renaming, sharing: sharing))
    }
}

private struct TaskActionSheets: ViewModifier {
    let store: CommaStore
    @Binding var renaming: TaskSummary?
    @Binding var sharing: TaskSummary?
    @State private var title = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename task", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $title)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    guard let task = renaming else { return }
                    let next = title
                    renaming = nil
                    Task { await store.renameTask(id: task.id, title: next) }
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .onChange(of: renaming?.id) { _, _ in title = renaming?.title ?? "" }
            .sheet(item: $sharing) { task in TaskShareSheet(store: store, task: task) }
    }
}
