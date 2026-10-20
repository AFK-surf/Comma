import SwiftUI
import CommaCore

/// Six grey rows laid out exactly like Task rows while the first page of Tasks loads.
struct TaskSkeletonRows: View {
    private static let rows = (0..<6).map { index in
        TaskSummary(placeholder: "placeholder-\(index)",
                    title: index.isMultiple(of: 2) ? "Summarizing the latest updates and writing them up"
                                                   : "Reviewing open changes")
    }

    var body: some View {
        ForEach(Self.rows) { task in
            TaskRowLabel(task: task, pinned: false)
                .redacted(reason: .placeholder)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading tasks")
                .accessibilityHidden(task.id != Self.rows[0].id)
                .commaListRow(.task)
        }
    }
}

/// A task list that could not be read and has no Tasks to show: it says so where the Tasks would be, with the way to
/// read it again. The toast that came with the failure says why, and leaves; this stays until a read succeeds.
struct TaskListFailedState: View {
    let store: CommaStore
    /// The room to centre in; Home gives the space below its section title.
    var minHeight: CGFloat = 0

    var body: some View {
        EmptyState(Text("Couldn’t load tasks"), icon: "central-exclamation-triangle",
                   description: Text("Check your connection, then try again.")) {
            Button("Try Again") {
                // Cleared first, so a read that fails the same way says so again.
                store.dismissError()
                Task { await store.refresh() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .accessibilityIdentifier("taskListFailed")
        .commaListRow()
    }
}

/// What the task section says without rows: no Tasks at all, none in the chosen status, or none that
/// match the filters. Each offers the way out it has, at the size of a section rather than a page.
struct HomeTaskEmptyState: View {
    enum Reason { case noTasks, status(TaskBucket?), filtered }

    let reason: Reason
    let messageComma: () -> Void
    let clearFilters: () -> Void
    /// Set when the pages read so far hold nothing here but more remain: the state says so, and reads on by hand.
    var lookFurther: (() -> Void)?
    /// The room below the section title, where the state centres, as the desktop's Home does.
    var minHeight: CGFloat = 0

    var body: some View {
        Group {
            switch reason {
            case .noTasks:
                // The desktop's empty task list glyph.
                EmptyState(Text("No tasks"), icon: "central-planning",
                           description: Text("Tasks appear here when you ask Comma to work on something.")) {
                    Button("Message Comma", action: messageComma)
                }
            case .status:
                // A section of Home, not a page: one quiet line, as the desktop's text-sm. The switcher below
                // already shows the status's glyph.
                VStack(spacing: 14) {
                    (lookFurther == nil ? Text("No tasks in this status") : Text("No recent tasks in this status"))
                        .font(.footnote).foregroundStyle(CommaTheme.textQuaternary)
                        .multilineTextAlignment(.center)
                    if let lookFurther { lookFurtherButton(lookFurther) }
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
            case .filtered:
                EmptyState(lookFurther == nil ? Text("No tasks match these filters") : Text("No recent tasks match these filters"),
                           icon: "icon-filter") {
                    if let lookFurther { Button("Look Further Back", action: lookFurther) }
                    Button("Clear Filters", action: clearFilters)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .commaListRow()
    }

    private func lookFurtherButton(_ action: @escaping () -> Void) -> some View {
        Button("Look Further Back", action: action)
            .buttonStyle(CommaButtonStyle(hierarchy: .secondary))
    }
}
