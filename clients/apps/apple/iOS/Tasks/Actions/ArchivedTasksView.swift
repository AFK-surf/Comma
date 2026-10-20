import SwiftUI
import CommaCore

/// Archived Tasks (the core's `archivedTasks`, 50 at a time). Rows match the Home list and show the status each Task
/// was archived from; swiping or the context menu restores one to the task list.
struct ArchivedTasksView: View {
    let store: CommaStore
    let openTask: (TaskSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [TaskSummary] = []
    @State private var hasMore = false
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var renaming: TaskSummary?
    @State private var sharing: TaskSummary?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    InlineError(message: error, retry: { call("archivedTasks.refresh") })
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .commaListRow()
                }
                ForEach(tasks) { task in
                    TaskListRow(task: task, pinned: false) { dismiss(); openTask(task) }
                        .swipeActions {
                            Button { Task { await restore(task) } } label: {
                                Label { Text("Restore") } icon: { SwipeIcon.image(TaskActionMenuItems.restoreIcon) }
                            }
                            .tint(CommaTheme.brandSolid)
                        }
                        .contextMenu {
                            TaskActionMenuItems(store: store, task: task, rename: { renaming = task },
                                                share: { sharing = task }, archiveChanged: { remove(task) })
                        }
                        .commaListRow(.task)
                }
                if !loaded || hasMore { footer }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 44)
            .scrollContentBackground(.hidden)
            .background(CommaTheme.bgPrimary)
            .overlay { if loaded, !hasMore, tasks.isEmpty, error == nil { empty } }
            .refreshable { _ = try? await store.core.call("archivedTasks.refresh", workspace) }
            .pageTitle("Archived tasks")
            .sheetCloseButton(id: "closeArchivedTasks") { dismiss() }
            .taskActionSheets(store: store, renaming: $renaming, sharing: $sharing)
        }
        .tint(CommaTheme.brandSolid)
        .task { await follow() }
    }

    /// The first load's spinner, then the next page's: while this row stays on screen, the next page is read.
    private var footer: some View {
        ProgressView().frame(maxWidth: .infinity, minHeight: 44).padding(.vertical, 8)
            .commaListRow()
            // Keyed by the read as well, so a page that came back empty but has more reads on at once.
            .task(id: "\(tasks.count) \(loaded) \(loading)") { if loaded, !loading { call("archivedTasks.more") } }
    }

    private var workspace: [String: Any] { store.workspace.map { ["workspace": $0.id] } ?? [:] }

    private func call(_ name: String) { Task { _ = try? await store.core.call(name, workspace) } }

    /// Follows the list while the page shows it.
    private func follow() async {
        var topic: [String: Any] = ["topic": "archivedTasks"]
        if let workspace = store.workspace { topic["workspace"] = workspace.id }
        for await value in store.core.subscribe(topic, read: { value in CoreJSON(value: value) }) {
            guard case .value(let next) = value, let json = next.object else { continue }
            withAnimation(CommaMotion.stateChange) { tasks = json.objects("tasks").compactMap(TaskSummary.init(summary:)) }
            hasMore = json.bool("hasMore")
            loading = json.bool("loading")
            error = json.string("error")
            loaded = !loading || !tasks.isEmpty
        }
    }

    private var empty: some View {
        EmptyState(Text("No archived tasks"), icon: "icon-archive", description: Text("Tasks you archive appear here."))
    }

    private func restore(_ task: TaskSummary) async {
        if await store.setTaskArchived(task, archived: false) { remove(task) }
    }

    private func remove(_ task: TaskSummary) {
        withAnimation(CommaMotion.stateChange) { tasks.removeAll { $0.id == task.id } }
    }
}
