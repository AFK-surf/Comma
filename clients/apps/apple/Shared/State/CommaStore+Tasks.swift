import Foundation
import CommaCore

/// The task list: reads, paging and Activity, and the changes a member makes to a Task.
extension CommaStore {
    // MARK: Workspace and conversations

    func refresh() async {
        guard session != nil else { await start(); return }
        // No Workspace was read yet, so there is no list to refresh: read the product from the start.
        guard workspace != nil else { await resume(); return }
        let current = boundary
        do { try await refreshTasks(boundary: current) } catch { present(error, boundary: current) }
        await router.pane?.refresh()
        // The list was just read; the open Task's own read must not schedule a second one.
        await task?.refresh(updatingTaskList: false)
    }

    func refreshTaskList() async {
        let current = boundary
        do { try await refreshTasks(boundary: current) } catch { present(error, boundary: current) }
    }

    func loadMoreTasks() async {
        guard let workspace, let cursor = nextTaskCursor, !loadingMore else { return }
        let current = boundary
        loadingMore = true
        defer { if boundary == current { loadingMore = false } }
        do {
            let page = try await client.listTasks(workspace: workspace, cursor: cursor)
            guard boundary == current, self.workspace?.id == workspace.id else { return }
            var known = Set(tasks.map(\.id))
            tasks += page.data.filter { $0.isTask && known.insert($0.id).inserted }
            nextTaskCursor = page.nextCursor
            hasMoreTasks = page.hasMore == true
        } catch { present(error, boundary: current) }
    }

    // MARK: Task actions

    func searchTasks(_ query: String) async throws -> [Conversation] {
        guard let workspace else { return [] }
        return try await client.searchTasks(workspace: workspace, query: query)
    }

    func archivedTasks(cursor: String? = nil) async throws -> Page<Conversation> {
        guard let workspace else { return Page(data: []) }
        return try await client.listTasks(workspace: workspace, cursor: cursor, archived: true)
    }

    func target(for taskID: String) -> ConversationTarget? {
        workspace.map { ConversationTarget(workspaceID: $0.id, groupID: $0.groupID, conversationID: taskID) }
    }

    /// Renames a Task from the list or its open sheet. Returns false and reports the error when refused.
    @discardableResult
    func renameTask(id: String, title: String) async -> Bool {
        guard let target = target(for: id) else { return false }
        let current = boundary
        do {
            let updated = try await client.renameTask(target: target, title: title)
            guard boundary == current else { return false }
            adopt(updated)
            return true
        } catch { present(error, boundary: current); return false }
    }

    /// Archives or restores a Task. The server checks `updated_at`, so a stale copy is refused and re-read.
    @discardableResult
    func setTaskArchived(_ task: Conversation, archived: Bool) async -> Bool {
        guard let target = target(for: task.id) else { return false }
        let current = boundary
        do {
            guard let version = task.archiveVersion else { throw CommaError.invalidInput("Refresh this task before archiving it.") }
            let updated = try await client.setTaskArchived(target: target, archived: archived, version: version)
            guard boundary == current else { return false }
            if archived, self.task?.taskID == task.id { closeTask() } else { adopt(updated) }
            if archived { pinnedTaskIDs.remove(task.id) }
            scheduleTaskListRefresh()
            return true
        } catch {
            present(error, boundary: current)
            scheduleTaskListRefresh()
            return false
        }
    }

    /// Marks a Task in review as done by accepting its result, as the desktop's Done does. Only a Task waiting
    /// for review with a review version and no schedule can be accepted (`canAcceptReview`).
    @discardableResult
    func acceptTaskReview(_ task: Conversation) async -> Bool {
        guard task.canAcceptReview, let version = task.reviewVersion, let target = target(for: task.id) else { return false }
        let current = boundary
        do {
            let updated = try await client.acceptTask(target: target, reviewVersion: version)
            guard boundary == current else { return false }
            adopt(updated)
            scheduleTaskListRefresh()
            return true
        } catch {
            present(error, boundary: current)
            scheduleTaskListRefresh()
            return false
        }
    }

    func setTaskPinned(id: String, pinned: Bool) async {
        guard let target = target(for: id) else { return }
        let current = boundary
        let previous = pinnedTaskIDs
        if pinned { pinnedTaskIDs.insert(id) } else { pinnedTaskIDs.remove(id) }
        do {
            try await client.setTaskPinned(target: target, pinned: pinned)
        } catch {
            guard boundary == current else { return }
            pinnedTaskIDs = previous
            present(error, boundary: current)
        }
    }

    /// A Task the server returned after a change: the open sheet and the list both take it.
    private func adopt(_ detail: Conversation) {
        if task?.taskID == detail.id { task?.adopt(detail) }
        if let index = tasks.firstIndex(where: { $0.id == detail.id }) {
            if detail.isArchived { tasks.remove(at: index) } else { tasks[index] = detail }
        }
    }

    // MARK: Pane support

    func taskUpdated(_ detail: Conversation) {
        scheduleTaskListRefresh()
    }

    func scheduleTaskListRefresh() {
        listRefreshRevision += 1
        // An invalidation received during a read makes that Activity response stale.
        activityRequest += 1
        guard listRefresh == nil else { return }
        let current = boundary
        listRefresh = Task { [weak self] in
            guard let self else { return }
            var revision: Int
            repeat {
                // One batch per selected Workspace, at most five starts a second.
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, self.boundary == current else { return }
                revision = self.listRefreshRevision
                do { try await self.refreshTasks(boundary: current) }
                catch { if !Task.isCancelled { self.present(error, boundary: current) } }
                guard !Task.isCancelled, self.boundary == current else { return }
            } while revision != self.listRefreshRevision
            self.listRefresh = nil
        }
    }

    func settleTaskListRefresh() async {
        while let refresh = listRefresh { await refresh.value }
    }

    // MARK: Product

    func refreshTasks(boundary current: Int) async throws {
        guard let workspace else { return }
        async let pins = client.pinnedTasks(workspace: workspace)
        let page: Page<Conversation>
        do { page = try await client.listTasks(workspace: workspace) } catch {
            // A failed first read ends the placeholders; the list says it could not load, the toast says why.
            if boundary == current, self.workspace?.id == workspace.id { tasksLoaded = true; taskListFailed = true }
            throw error
        }
        let pinned = try? await pins
        guard boundary == current, self.workspace?.id == workspace.id else { return }
        if let pinned { pinnedTaskIDs = Set(pinned.map(\.conversation.id)) }
        let next = page.data.filter(\.isTask)
        tasks = next
        tasksLoaded = true
        taskListFailed = false
        nextTaskCursor = page.nextCursor
        hasMoreTasks = page.hasMore == true
        await refreshTaskActivity(boundary: current)
    }

    /// Uses the same bounded owner projection as background APNs. Requests are fenced by issue order,
    /// because removing the newest Task can legitimately lower the aggregate timestamp.
    func refreshTaskActivity() async { await refreshTaskActivity(boundary: boundary) }

    private func refreshTaskActivity(boundary current: Int) async {
        guard let workspace, session != nil else { return }
        activityRequest += 1
        let request = activityRequest
        do {
            let snapshot = try await client.taskActivity(workspace: workspace)
            guard boundary == current, self.workspace?.id == workspace.id, request == activityRequest else { return }
            taskActivitySnapshot = snapshot
            onActivitySnapshot?(snapshot, workspace)
        } catch {
            guard boundary == current, self.workspace?.id == workspace.id, request == activityRequest else { return }
            onActivityFailure?(error.localizedDescription)
        }
    }
}
