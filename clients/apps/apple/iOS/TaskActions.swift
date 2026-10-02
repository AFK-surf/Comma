import SwiftUI
import UIKit
import CommaCore

/// The Task actions offered from a list row's context menu and from the open Task's header menu.
struct TaskActionMenuItems: View {
    let store: CommaStore
    let task: Conversation
    let rename: () -> Void
    let share: () -> Void

    var body: some View {
        let pinned = store.pinnedTaskIDs.contains(task.id)
        Button("Rename", systemImage: "pencil", action: rename)
        if !task.isArchived {
            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                Task { await store.setTaskPinned(id: task.id, pinned: !pinned) }
            }
        }
        Button("Share", systemImage: "square.and.arrow.up", action: share)
        Divider()
        if task.isArchived {
            Button("Restore", systemImage: "tray.and.arrow.up") {
                Task { await store.setTaskArchived(task, archived: false) }
            }
        } else {
            Button("Archive", systemImage: "archivebox") {
                Task { await store.setTaskArchived(task, archived: true) }
            }
        }
    }
}

extension View {
    /// The rename prompt and share sheet that `TaskActionMenuItems` opens.
    func taskActionSheets(store: CommaStore, renaming: Binding<Conversation?>, sharing: Binding<Conversation?>) -> some View {
        modifier(TaskActionSheets(store: store, renaming: renaming, sharing: sharing))
    }
}

private struct TaskActionSheets: ViewModifier {
    let store: CommaStore
    @Binding var renaming: Conversation?
    @Binding var sharing: Conversation?
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
            .sheet(item: $sharing) { task in
                if let target = store.target(for: task.id) {
                    TaskShareSheet(store: store, target: target, title: task.title)
                }
            }
    }
}

/// The owner's controls for a Task's public link: create, copy or send, update to the latest message,
/// replace, and stop sharing. Anyone with the link can read the shared messages.
struct TaskShareSheet: View {
    let store: CommaStore
    let target: ConversationTarget
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var share: TaskShare?
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingReset = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(title).font(.headline).lineLimit(2)
                } footer: {
                    Text("Anyone with the link can read this task’s messages up to when it was shared. They can’t send messages or see your workspace.")
                }
                if !loaded {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                } else if let share, let url = URL(string: share.url) {
                    Section("Link") {
                        Text(share.url).font(.callout.monospaced()).textSelection(.enabled).lineLimit(3)
                        ShareLink(item: url) { Label("Send link", systemImage: "square.and.arrow.up") }
                        Button(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.url = url
                            copied = true
                        }
                    }
                    Section {
                        LabeledContent("Messages", value: share.messageCount.formatted())
                        if share.artifactCount > 0 { LabeledContent("Files", value: share.artifactCount.formatted()) }
                        LabeledContent("Shared", value: Date(timeIntervalSince1970: Self.seconds(share.sharedAt)).formatted(.relative(presentation: .named)))
                        if share.hasNewerMessages {
                            Button("Include newer messages", systemImage: "arrow.clockwise") { run { try await store.client.publishTaskShare(target: target) } }
                        }
                    } footer: {
                        if share.hasNewerMessages { Text("Messages sent after the link was shared aren’t visible to readers until you include them.") }
                    }
                    Section {
                        Button("Replace link", systemImage: "arrow.triangle.2.circlepath") { confirmingReset = true }
                        Button("Stop sharing", systemImage: "xmark.circle", role: .destructive) {
                            run { try await store.client.revokeTaskShare(target: target); return nil }
                        }
                    } footer: {
                        Text("Replacing the link stops the current link from working.")
                    }
                } else {
                    Section {
                        Button("Create link", systemImage: "link") { run { try await store.client.publishTaskShare(target: target) } }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(CommaTheme.errorPrimary) }
                }
            }
            .disabled(busy)
            .navigationTitle("Share task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Replace the link?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Replace link", role: .destructive) { run { try await store.client.resetTaskShare(target: target) } }
            } message: {
                Text("People with the current link will no longer be able to open it.")
            }
        }
        .tint(CommaTheme.brandSolid)
        .task { await load() }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        do { share = try await store.client.taskShare(target: target) } catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func run(_ operation: @escaping () async throws -> TaskShare?) {
        guard !busy else { return }
        busy = true; error = nil; copied = false
        Task {
            defer { busy = false }
            do {
                share = try await operation()
                store.scheduleTaskListRefresh()
            } catch { self.error = error.localizedDescription }
        }
    }

    static func seconds(_ value: Double) -> Double { value > 100_000_000_000 ? value / 1000 : value }
}

/// Archived Tasks, read on demand. Restoring one returns it to the task list.
struct ArchivedTasksView: View {
    let store: CommaStore
    let openTask: (Conversation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [Conversation] = []
    @State private var cursor: String?
    @State private var hasMore = false
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var renaming: Conversation?
    @State private var sharing: Conversation?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(CommaTheme.errorPrimary)
                }
                if loaded, tasks.isEmpty, error == nil {
                    Text("No archived tasks").foregroundStyle(CommaTheme.textQuaternary)
                        .frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
                ForEach(tasks) { task in
                    Button { dismiss(); openTask(task) } label: { TaskListRow(task: task) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Restore", systemImage: "tray.and.arrow.up") { Task { await restore(task) } }
                                .tint(CommaTheme.brandSolid)
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { renaming = task }
                            Button("Share", systemImage: "square.and.arrow.up") { sharing = task }
                            Button("Restore", systemImage: "tray.and.arrow.up") { Task { await restore(task) } }
                        }
                        .onAppear { if task.id == tasks.last?.id, hasMore { Task { await load(more: true) } } }
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
            }
            .listStyle(.plain)
            .refreshable { await load(more: false) }
            .navigationTitle("Archived tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .taskActionSheets(store: store, renaming: $renaming, sharing: $sharing)
        }
        .tint(CommaTheme.brandSolid)
        .task { await load(more: false) }
    }

    private func load(more: Bool) async {
        guard !loading, !more || cursor != nil else { return }
        loading = true
        defer { loading = false; loaded = true }
        do {
            let page = try await store.archivedTasks(cursor: more ? cursor : nil)
            var known = more ? Set(tasks.map(\.id)) : []
            tasks = (more ? tasks : []) + page.data.filter { known.insert($0.id).inserted }
            cursor = page.nextCursor
            hasMore = page.hasMore == true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func restore(_ task: Conversation) async {
        if await store.setTaskArchived(task, archived: false) {
            tasks.removeAll { $0.id == task.id }
        }
    }
}
