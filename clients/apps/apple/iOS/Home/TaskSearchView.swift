import SwiftUI
import CommaCore

/// Task search over the tabs, opened from its button beside the Inbox tab, which leaves the selected tab as it is.
/// The search field comes up at once with the system's own motion: on iPhone from iOS 26 the field and its close
/// button sit above the keyboard, as the system places a search there; elsewhere, at the top of the page.
///
/// Search closes the moment its field stops searching: the layer goes at once, the field with it, and the keyboard goes
/// down on its own over the tabs. Kept a moment longer, the field would ride the keyboard down to the layer's bottom
/// edge, over the tab bar, and fading the layer would not hide it, as the field's glass ignores the layer's opacity.
struct TaskSearchLayer: View {
    let store: CommaStore
    let close: () -> Void
    @State private var text = ""
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TaskSearchResults(store: store, text: text) { focused = false }
                .containerBackground(.clear, for: .navigation)
                .modifier(TaskSearchField(text: $text, searching: $searching, focused: $focused))
        }
        .accessibilityAction(.escape) { searching = false }
        // A turn after the layer appears, so the field rises on the system's animation rather than arriving up.
        .onAppear { DispatchQueue.main.async { searching = true } }
        .onChange(of: searching) { _, open in
            if !open { close() }
        }
    }
}

/// The system's search field for `TaskSearchLayer`. On iPhone from iOS 26 it sits above the keyboard with its close
/// button while presented, and is the system's search button at the bottom otherwise. Elsewhere it is in the page's
/// bar: an iPad puts a toolbar search in the navigation bar, which this page would hide.
private struct TaskSearchField: ViewModifier {
    @Binding var text: String
    @Binding var searching: Bool
    var focused: FocusState<Bool>.Binding
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), sizeClass == .compact {
            content
                .toolbarVisibility(.hidden, for: .navigationBar)
                .searchable(text: $text, isPresented: $searching, placement: .toolbar, prompt: Text("Search tasks"))
                .searchToolbarBehavior(.minimize)
                .searchFocused(focused)
        } else if sizeClass == .compact {
            drawer(content)
        } else {
            // A search in the bar of a wide page has no Cancel beside it, and hides the bar's items while it is up:
            // the page keeps its bar, and the bar's cross is the way back.
            drawer(content)
                .searchPresentationToolbarBehavior(.avoidHidingContent)
                .sheetCloseButton(id: "closeTaskSearch") { searching = false }
        }
    }

    private func drawer(_ content: Content) -> some View {
        content
            .searchable(text: $text, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text("Search tasks"))
            .searchFocused(focused)
            .pageTitle("Search")
    }
}

/// The Tasks whose titles or messages match `text`, as the core's `search.tasks` finds them once typing pauses for
/// 300 ms; typing again cancels the search in flight. `dismissKeyboard` puts the keyboard away as a Task opens over the
/// results; the query stays for the way back.
private struct TaskSearchResults: View {
    let store: CommaStore
    let text: String
    let dismissKeyboard: () -> Void
    @State private var results: [TaskSummary]?
    @State private var error: String?
    /// Advances on Try Again, which searches the same query again.
    @State private var attempt = 0
    @State private var renaming: TaskSummary?
    @State private var sharing: TaskSummary?

    var body: some View {
        List {
            // A row action that fails (rename, archive) is the app's toast, over the results.
            if !query.isEmpty, let results {
                ForEach(results) { task in
                    TaskListRow(task: task, pinned: store.pinnedTaskIDs.contains(task.id)) {
                        dismissKeyboard()
                        Task { await store.openTask(id: task.id) }
                    }
                    .contextMenu {
                        TaskActionMenuItems(store: store, task: task, rename: { renaming = task }, share: { sharing = task })
                    }
                    .commaListRow(.task)
                }
            }
        }
        // What shows instead of rows, centred in the room above the keyboard.
        .overlay { placeholder }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(CommaTheme.bgPrimary)
        .scrollDismissesKeyboard(.immediately)
        .task(id: SearchRequest(query: query, attempt: attempt)) { await search() }
        .task(id: results?.map(\.id)) { await followSummaries() }
        .taskActionSheets(store: store, renaming: $renaming, sharing: $sharing)
    }

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Before a query, the prompt; then the spinner, no match, or the search that failed with the way to search again.
    /// Earlier results stay as rows while the next search runs.
    @ViewBuilder private var placeholder: some View {
        if query.isEmpty {
            Text("Search task titles").font(.footnote).foregroundStyle(CommaTheme.textQuaternary)
        } else if let results {
            if results.isEmpty { EmptyState(Text("No matching tasks"), icon: "icon-search") }
        } else if let error {
            EmptyState(Text("Couldn’t search tasks"), icon: "central-exclamation-triangle", description: Text(error)) {
                // The spinner answers the tap while the search runs again.
                Button("Try Again") { self.error = nil; attempt += 1 }
            }
        } else {
            ProgressView()
        }
    }

    private struct SearchRequest: Equatable {
        let query: String
        let attempt: Int
    }

    /// The found Tasks' statuses and labels, which a search result alone does not carry.
    private func followSummaries() async {
        guard let ids = results?.map(\.id) else { return }
        for await found in store.followSummaries(ids) {
            let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard let current = results, current.map(\.id) == ids else { return }
            results = current.map { byID[$0.id] ?? $0 }
        }
    }

    /// One bounded server search per settled query. Earlier results stay on screen until the next arrive.
    private func search() async {
        let query = query
        guard !query.isEmpty else { results = nil; error = nil; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let found = try await store.searchTasks(query)
            guard !Task.isCancelled else { return }
            results = found
            error = nil
        } catch {
            guard !Task.isCancelled, (error as? CommaError) != .cancelled else { return }
            results = nil
            self.error = error.localizedDescription
        }
    }
}
