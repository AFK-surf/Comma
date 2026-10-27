import SwiftUI
import CommaCore

/// The task section's rows inside Home's list: placeholders while the first page loads, the Tasks with their
/// menu and Archive swipe, an empty state or the list's failure to load, and a footer that reads further pages.
struct HomeTaskRows: View {
    let store: CommaStore
    let query: HomeTaskQuery
    let rows: [TaskSummary]
    /// While pages move (`HomeTaskPager`), the rows wait unseen under the pages drawn over them.
    let pager: HomeTaskPager
    /// The room below the section title (`HomeTaskPager.emptyHeight`), where an empty or failed list centres its state.
    let emptyHeight: CGFloat
    @Binding var renaming: TaskSummary?
    @Binding var sharing: TaskSummary?
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        // Further pages are still being read for a short list, so it is not empty yet.
        let filling = store.hasMoreTasks && (store.loadingMore || query.needsMore(visible: rows.count, hasMore: true))
        if !store.tasksLoaded {
            TaskSkeletonRows()
        } else if store.taskListFailed, store.tasks.isEmpty {
            TaskListFailedState(store: store, minHeight: emptyHeight)
                .opacity(hidden ? 0 : 1)
        } else if rows.isEmpty, !filling {
            HomeTaskEmptyState(reason: emptyReason, messageComma: { navigation.openRouter(focus: true) },
                               clearFilters: query.clearFilters,
                               lookFurther: store.hasMoreTasks ? { Task { await store.loadMoreTasks() } } : nil,
                               minHeight: emptyHeight)
                .opacity(hidden ? 0 : 1)
        }
        ForEach(rows) { task in
            TaskListRow(task: task, pinned: store.pinnedTaskIDs.contains(task.id)) {
                Task { await store.openTask(id: task.id) }
            }
            .contextMenu {
                TaskActionMenuItems(store: store, task: task, rename: { renaming = task }, share: { sharing = task })
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !task.unsupported.contains("archive") {
                    Button { Task { await store.setTaskArchived(task, archived: true) } } label: {
                        Label { Text("Archive") } icon: { SwipeIcon.image(TaskActionMenuItems.archiveIcon) }
                    }
                    // A swipe action does not draw itself disabled, so a refused Archive dims its fill.
                    .tint(CommaTheme.brandSolid.opacity(task.archiveRefusal == nil ? 1 : 0.4))
                    .archiveAvailability(of: task)
                }
                MarkDoneSwipe(store: store, task: task)
            }
            .commaListRow(.task)
            .opacity(hidden ? 0 : 1)
        }
        // An empty list reads on by hand from its empty state, which says the pages read so far hold nothing.
        if store.hasMoreTasks, filling || !rows.isEmpty {
            footer(filling: filling)
        }
    }

    private var hidden: Bool { pager.moving }

    private var emptyReason: HomeTaskEmptyState.Reason {
        if store.tasks.isEmpty { return .noTasks }
        return query.appliedCount > 0 ? .filtered : .status(query.selectedBucket)
    }

    /// A spinner while pages are read. It reads the next page whenever it is on screen and the list needs one:
    /// at the end of a full list, or to fill a short one within the filter's budget. Past that budget the
    /// member reads on with Load more, a grey capsule like the empty states' actions.
    private func footer(filling: Bool) -> some View {
        Group {
            if filling {
                ProgressView()
            } else {
                Button("Load more") { Task { await store.loadMoreTasks() } }
                    .buttonStyle(CommaButtonStyle(hierarchy: .secondary, compact: true))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.vertical, 8)
        .opacity(hidden ? 0 : 1)
        .commaListRow()
        .task(id: PageTrigger(filter: query.filter, loading: store.loadingMore, count: store.tasks.count)) {
            guard !store.loadingMore, query.claimPage(visible: rows.count, hasMore: store.hasMoreTasks) else { return }
            // Not tied to this row: scrolling the footer away must not cancel a page already asked for.
            Task { await store.loadMoreTasks() }
        }
    }

    /// The footer checks again when the filter changes, a read ends or the list grows.
    private struct PageTrigger: Equatable {
        let filter: TaskListFilter
        let loading: Bool
        let count: Int
    }
}
