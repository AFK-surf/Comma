import CommaCore
import Foundation

/// The task list (the core's `tasks` topic, which follows the Workspace in focus) and the changes a member makes to a
/// Task from it.
extension CommaStore {
    /// Follows the task list of `workspace`: its Tasks and pages, as the core keeps and reads them.
    func followTasks(_ workspace: Workspace) {
        taskList?.cancel()
        let current = boundary
        let updates = core.subscribe(["topic": "tasks", "workspace": workspace.id], read: TaskList.init)
        taskList = Task { [weak self] in
            for await value in updates {
                guard let self, self.boundary == current, case .value(let list) = value else { continue }
                self.install(list)
            }
        }
    }

    func install(_ list: TaskList?) {
        guard let list else { return }
        lastTaskList = list
        if workspaces != list.workspaces {
            workspaces = list.workspaces
            // The Workspace shown takes the name the list knows for it.
            if let shown = workspace, let named = list.workspaces.first(where: { $0.id == shown.id }), named.name != shown.name {
                workspace = Workspace(id: shown.id, groupID: shown.groupID, name: named.name)
            }
        }
        // A list of another Workspace (the focus moving) shows nothing of this one.
        guard let workspace, list.workspaceID == nil || list.workspaceID == workspace.id else { return }
        let next = list.items.filter { $0.isTask && $0.groupID == workspace.groupID }
        if tasks != next { tasks = next }
        hasMoreTasks = list.hasMore
        tasksLoaded = list.read
        // Home and the Inbox say in place that the list could not load; the toast says it once, not at each retry.
        let failed = list.failed && next.isEmpty
        if failed, !taskListFailed { error = String(localized: "Couldn’t load tasks") }
        taskListFailed = failed
        if list.read { Task { await refreshTaskActivity() } }
    }

    /// Follows the pins of the Workspace shown (the core's `taskPins`).
    func followPins(_ workspace: Workspace) {
        pinWatch?.cancel()
        let current = boundary
        let updates = core.subscribe(["topic": "taskPins", "group": workspace.groupID]) { value in
            Set((value as? NSDictionary)?.strings("ids") ?? [])
        }
        pinWatch = Task { [weak self] in
            for await value in updates {
                guard let self, self.boundary == current, self.workspace?.id == workspace.id, case .value(let ids) = value else { continue }
                if self.pinnedTaskIDs != ids { self.pinnedTaskIDs = ids }
            }
        }
    }

    /// Follows the order the Group's Tasks are listed in (the core's `taskOrder`).
    func followTaskOrder(_ workspace: Workspace) {
        orderWatch?.cancel()
        let current = boundary
        let updates = core.subscribe(["topic": "taskOrder", "group": workspace.groupID]) { value in
            ((value as? NSDictionary)?["sections"] as? [NSDictionary] ?? []).flatMap { $0.strings("ids") }
        }
        orderWatch = Task { [weak self] in
            for await value in updates {
                guard let self, self.boundary == current, self.workspace?.id == workspace.id, case .value(let ids) = value else { continue }
                if self.taskBoardOrder != ids { self.taskBoardOrder = ids }
            }
        }
    }

    func refreshTaskList() async {
        guard let workspace else { return }
        do { _ = try await core.call("tasks.refresh", ["workspace": workspace.id]) }
        catch { present(error, boundary: boundary) }
    }

    func loadMoreTasks() async {
        guard let workspace, hasMoreTasks, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do { _ = try await core.call("tasks.more", ["workspace": workspace.id]) }
        catch { present(error, boundary: boundary) }
    }

    /// The Workspace's Tasks the server finds for `query`: each as the list has it, else by its title until
    /// `followSummaries` reads it. A query too short to search finds nothing.
    func searchTasks(_ query: String) async throws -> [TaskSummary] {
        guard let workspace else { return [] }
        let answer = try await core.object("search.tasks", ["query": query, "group": workspace.groupID,
                                                             "prefer": workspace.id])
        if answer.string("status") == "error" {
            throw CoreError(code: "search_failed", message: String(localized: "Comma could not search your tasks."))
        }
        let listed = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return answer.objects("results").compactMap { result in
            guard let id = result.string("conversation_id") else { return nil }
            return listed[id] ?? TaskSummary(placeholder: id, title: result.text("title") ?? "")
        }
    }

    /// The summaries of `ids` in the Workspace's Group, as they are read and whenever they change.
    func followSummaries(_ ids: [String]) -> AsyncStream<[TaskSummary]> {
        guard let workspace, !ids.isEmpty else { return AsyncStream { $0.finish() } }
        let updates = core.subscribe(["topic": "taskSummaries", "group": workspace.groupID, "ids": ids.joined(separator: ",")]) {
            value in (value as? NSDictionary)?.objects("summaries").compactMap(TaskSummary.init(summary:)) ?? []
        }
        return AsyncStream { continuation in
            let task = Task {
                for await update in updates { if case .value(let found) = update { continuation.yield(found) } }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Renames a Task from the list or its open sheet. Returns false and reports the error when refused.
    @discardableResult
    func renameTask(id: String, title: String) async -> Bool {
        await change(id, "tasks.rename", ["title": title])
    }

    /// Archives or restores a Task at the version the member saw; a stale one is refused and read again.
    @discardableResult
    func setTaskArchived(_ task: TaskSummary, archived: Bool) async -> Bool {
        guard let version = task.archiveVersion else { return false }
        let current = boundary
        do {
            let answer = try await core.call("tasks.archive", ["group": task.groupID, "conversation": task.id,
                                                               "action": archived ? "archive" : "unarchive", "version": version])
            guard boundary == current else { return false }
            if archived, self.task?.taskID == task.id { closeTask() }
            return (answer.value as? NSNumber)?.boolValue ?? false
        } catch {
            present(error, boundary: current)
            return false
        }
    }

    /// Marks a Task in review as done by accepting its result, as the desktop's Done does.
    @discardableResult
    func acceptTaskReview(_ task: TaskSummary) async -> Bool {
        guard let version = task.reviewVersion, task.canAcceptReview else { return false }
        return await change(task.id, "tasks.accept", ["reviewVersion": version])
    }

    func setTaskPinned(id: String, pinned: Bool) async {
        _ = await change(id, "tasks.pin", ["pinned": pinned])
    }

    /// One change of a Task of the Workspace shown, by the core's call `name`; false and the error reported when refused.
    private func change(_ id: String, _ name: String, _ params: [String: Any]) async -> Bool {
        guard let workspace else { return false }
        let current = boundary
        var all = params
        all["group"] = workspace.groupID
        all["conversation"] = id
        do {
            _ = try await core.call(name, all)
            return boundary == current
        } catch {
            present(error, boundary: current)
            return false
        }
    }

    // MARK: Activity

    /// The Tasks the Live Activity follows, as the server picks them; told to the Live Activity.
    func refreshTaskActivity() async {
        guard let workspace, session != nil else { return }
        activityRequest += 1
        let request = activityRequest, current = boundary
        do {
            let answer = try await core.object("notifications.taskActivity", ["group": workspace.groupID])
            guard boundary == current, self.workspace?.id == workspace.id, request == activityRequest else { return }
            let next = answer.objects("tasks").compactMap { task -> TaskActivityTask? in
                guard let id = task.string("id") else { return nil }
                return TaskActivityTask(id: id, title: task.text("title") ?? "", status: task.text("status") ?? "",
                                        updatedAt: task.double("updatedAt"))
            }
            taskActivity = next
            onActivitySnapshot?(next, workspace)
        } catch {
            guard boundary == current, self.workspace?.id == workspace.id, request == activityRequest else { return }
            onActivityFailure?(error.localizedDescription)
        }
    }
}

/// The core's `tasks` value, as much of it as the phone reads.
struct TaskList: Sendable {
    let items: [TaskSummary]
    let workspaces: [Workspace]
    let workspaceID: String?
    let hasMore: Bool
    /// Read from the server this run, or failed to be: the list says what it has.
    let read: Bool
    let failed: Bool

    init?(_ value: Any?) {
        guard let json = value as? NSDictionary else { return nil }
        items = json.objects("items").compactMap { TaskSummary($0) }
        workspaces = json.objects("workspaces").compactMap { item in
            guard let id = item.string("id"), let group = item.string("group_id") else { return nil }
            return Workspace(id: id, groupID: group, name: item.text("name") ?? "")
        }
        workspaceID = json.string("activeWorkspaceId")
        hasMore = json.bool("hasMore")
        let source = json.string("source")
        // Kept on the device (`cache`) with an error code: the last read failed, and the list shows what is kept.
        failed = source == "error" || source == "unavailable" || json.string("errorCode") != nil
        read = source == "live-sync" || failed
    }
}

/// The Router chat's unread replies, and whether a conversation is a Task: what a notification checks before it shows.
extension CommaStore {
    func routerUnread(group: String) async throws -> RouterNotificationSnapshot {
        Self.unread(try await core.object("notifications.routerUnread", ["group": group]))
    }

    /// Marks the Router chat read up to `messageID`, the reply shown: its unread replies after.
    func readRouter(group: String, messageID: String) async throws -> RouterNotificationSnapshot {
        Self.unread(try await core.object("notifications.readRouter", ["group": group, "messageId": messageID]))
    }

    private static func unread(_ answer: NSDictionary) -> RouterNotificationSnapshot {
        RouterNotificationSnapshot(conversationID: answer.string("conversationId"), unreadCount: answer.int("unreadCount") ?? 0,
                                   latestMessageID: answer.string("latestMessageId"), latestSequence: answer.int("latestSeq") ?? 0)
    }

    /// Whether `conversation` of `group` is a Task this account may open.
    func isTask(_ conversation: String, group: String) async throws -> Bool {
        let answer = try await core.call("chat.prepare", ["groupId": group, "conversationId": conversation])
        return answer.object?.object("conversation")?.string("kind") == "agent_task"
    }
}

extension CommaStore {
    /// A Task's summary as the server has it now (the core's `taskSummaries`, read when not known).
    func summary(of id: String) async -> TaskSummary? {
        guard let workspace else { return nil }
        return await core.first(["topic": "taskSummaries", "group": workspace.groupID, "ids": id]) { value in
            (value as? NSDictionary)?.objects("summaries").lazy.compactMap(TaskSummary.init(summary:)).first { $0.id == id }
        }
    }
}
