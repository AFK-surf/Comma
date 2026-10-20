import SwiftUI
import Observation
import CommaCore

/// The Inbox on this device for the signed-in account: the read, unread and cleared marks (the core's `marks`), the
/// filter and Unread only. `providingInbox(store:)` owns it for the shell; the Inbox tab and the tab bar's unread dot
/// read it from the environment.
@MainActor @Observable
final class InboxModel {
    private(set) var marks = InboxMarks()
    var filter = InboxProjection.defaultFilter
    var unreadOnly = false
    @ObservationIgnored private var core: (any CoreAPI)?
    @ObservationIgnored private var watching: [Task<Void, Never>] = []
    @ObservationIgnored private var account: String?

    /// Follows `store`'s account's marks, with the default filter.
    func load(account next: String?, store: CommaStore) {
        guard next != account else { return }
        account = next
        for task in watching { task.cancel() }
        watching = []
        marks = InboxMarks()
        clearFilters()
        guard next != nil else { core = nil; return }
        core = store.core
        for kind in ["taskReviewSeen", "inboxUnread", "inboxDeleted"] {
            let updates = store.core.subscribe(["topic": "marks", "kind": kind]) { value -> [String: Double] in
                var out: [String: Double] = [:]
                for case let (id as String, revision as NSNumber) in ((value as? NSDictionary)?.object("marks") ?? [:]) {
                    out[id] = revision.doubleValue
                }
                return out
            }
            watching.append(Task { [weak self] in
                for await value in updates {
                    guard let self, case .value(let read) = value else { continue }
                    switch kind {
                    case "taskReviewSeen": if self.marks.seen != read { self.marks.seen = read }
                    case "inboxUnread": if self.marks.unread != read { self.marks.unread = read }
                    default: if self.marks.cleared != read { self.marks.cleared = read }
                    }
                }
            })
        }
    }

    // MARK: Reading

    /// The rows the filter and Unread only let through, newest first.
    func rows(tasks: [TaskSummary]) -> [TaskSummary] {
        InboxProjection.rows(tasks, marks: marks, filter: filter, unreadOnly: unreadOnly)
    }

    /// The rows before any filter, which the filter sheet counts.
    func listed(tasks: [TaskSummary]) -> [TaskSummary] { InboxProjection.listed(tasks, marks: marks) }

    /// The tab bar's dot: a row the Inbox can show is unread.
    func hasUnread(tasks: [TaskSummary]) -> Bool { InboxProjection.hasUnread(tasks, marks: marks) }

    func isUnread(_ task: TaskSummary) -> Bool { marks.isUnread(task) }

    func emptyState(tasks: [TaskSummary]) -> InboxEmptyState {
        InboxProjection.emptyState(tasks, marks: marks, filter: filter)
    }

    /// Unread only is what empties the list: the filter alone would show read rows.
    func hidesRead(tasks: [TaskSummary]) -> Bool {
        unreadOnly && !InboxProjection.rows(tasks, marks: marks, filter: filter).isEmpty
    }

    /// How many filters differ from the default Inbox, shown on the filter button.
    var appliedCount: Int {
        [filter.statuses != InboxProjection.defaultFilter.statuses, filter.schedules != nil, filter.origins != nil, unreadOnly]
            .filter { $0 }.count
    }

    func clearFilters() {
        filter = InboxProjection.defaultFilter
        unreadOnly = false
    }

    // MARK: Changes

    /// The member is viewing the Task at its current revision.
    func markSeen(_ task: TaskSummary) { mark("taskReviewSeen", [task]) }

    /// Clears the dot without opening the rows: drops their unread marks and records them as seen.
    func markRead(_ tasks: [TaskSummary]) {
        unmark("inboxUnread", tasks)
        mark("taskReviewSeen", tasks)
    }

    /// Keeps the dot on these rows until they are read.
    func markUnread(_ tasks: [TaskSummary]) { mark("inboxUnread", tasks) }

    /// Hides these rows until their Tasks update again. Nothing on the server changes.
    func clear(_ tasks: [TaskSummary]) { mark("inboxDeleted", tasks) }

    /// Shows rows `clear` hid, for Undo.
    func undoClear(_ tasks: [TaskSummary]) { unmark("inboxDeleted", tasks) }

    private func mark(_ kind: String, _ tasks: [TaskSummary]) {
        guard let core, !tasks.isEmpty else { return }
        let entries = tasks.map { [$0.id, InboxMarks.revision(of: $0)] as [Any] }
        Task { _ = try? await core.call("marks.mark", ["kind": kind, "entries": entries]) }
    }

    private func unmark(_ kind: String, _ tasks: [TaskSummary]) {
        guard let core, !tasks.isEmpty else { return }
        let ids = tasks.map(\.id)
        Task { _ = try? await core.call("marks.unmark", ["kind": kind, "ids": ids]) }
    }
}

extension View {
    /// Gives the tabs and the tab bar one `InboxModel`, kept on the signed-in account's Workspace. Viewing a
    /// Task, from any tab or a notification, reads it. Apply once inside the app card, beside `AppNavigation`.
    func providingInbox(store: CommaStore) -> some View { modifier(InboxProvider(store: store)) }
}

private struct InboxProvider: ViewModifier {
    let store: CommaStore
    @State private var inbox = InboxModel()

    /// The open Task and its revision: opening another Task or a newer revision records it as seen.
    private struct Viewing: Equatable {
        let id: String
        let revision: Double?
    }

    func body(content: Content) -> some View {
        let open = store.task?.summary
        content
            .environment(inbox)
            .onChange(of: store.session?.user.id, initial: true) { _, account in inbox.load(account: account, store: store) }
            .onChange(of: open.map { Viewing(id: $0.id, revision: $0.updatedAt) }, initial: true) { _, _ in
                if let open { inbox.markSeen(open) }
            }
    }
}
