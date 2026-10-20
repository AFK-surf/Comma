import Foundation
import CommaCore

/// Choosing and restoring the Workspace, foreground and background, and the task-list event stream.
extension CommaStore {
    // MARK: Workspace and conversations

    func chooseWorkspace(_ value: Workspace) async {
        let current = boundary
        loading = true
        defer { if boundary == current, workspace?.id == value.id { loading = false } }
        do {
            try await selectWorkspace(value, boundary: current)
        } catch { present(error, boundary: current) }
    }

    func resume() async {
        guard initialized else { await start(); return }
        // A background restore can fail before publishing a Session. Foreground
        // retries its existing Keychain authority instead of requiring a new login.
        guard let session else {
            if error != nil { await start() }
            return
        }
        let current = boundary
        if let validateSession {
            do {
                let valid = try await validateSession(session)
                guard boundary == current, self.session?.id == session.id else { return }
                if !valid { await invalidateLocalSession(); return }
            } catch { present(error, boundary: current); return }
        }
        guard boundary == current, self.session?.id == session.id else { return }
        if workspace == nil {
            do { try await loadProduct(boundary: boundary) }
            catch { present(error, boundary: boundary) }
        } else if router.pane == nil, let workspace {
            do { try await selectWorkspace(workspace, boundary: current) }
            catch { present(error, boundary: current) }
        } else { await refresh(); startStreams() }
    }

    func suspend() {
        stopStreams()
    }

    // MARK: Product

    /// A push launch restores only existing authority and its bounded Workspace scope.
    /// It creates no Workspace, chat pane, read acknowledgment or event stream.
    func restoreBackgroundWorkspace(boundary current: Int, preferredWorkspaceID: String?) async throws {
        let available = try await client.listWorkspaces()
        guard boundary == current, session != nil else { return }
        workspaces = available
        if let selected = preferredWorkspace(in: available, hint: preferredWorkspaceID) {
            workspace = selected
            rememberWorkspace(selected)
            onWorkspaceChanged?(selected)
        }
    }

    private var workspacePreferenceKey: String? {
        session.map { "comma.selected-workspace." + client.baseURL.absoluteString + "." + $0.user.id }
    }

    private func preferredWorkspace(in available: [Workspace], hint: String? = nil) -> Workspace? {
        if let key = workspacePreferenceKey, let saved = workspacePreferences.string(forKey: key),
           let authorized = available.first(where: { $0.id == saved }) { return authorized }
        if let hint, let authorized = available.first(where: { $0.id == hint }) { return authorized }
        return available.first
    }

    func rememberWorkspace(_ workspace: Workspace) {
        if let key = workspacePreferenceKey { workspacePreferences.set(workspace.id, forKey: key) }
    }

    /// Reads the Workspaces, making one if there is none, and selects one. A second request while this runs (Try Again
    /// tapped twice, pull to refresh, a push) joins it rather than reading again, which would close the chat the
    /// first read opened and read every list twice.
    func loadProduct(boundary current: Int) async throws {
        if let load = productLoad, load.boundary == current { return try await load.task.value }
        let task = Task { try await readProduct(boundary: current) }
        productLoad = (current, task)
        defer { if productLoad?.task == task { productLoad = nil } }
        try await task.value
    }

    private func readProduct(boundary current: Int) async throws {
        var available: [Workspace]
        do {
            available = try await client.listWorkspaces()
            guard boundary == current else { return }
            if available.isEmpty {
                let bootstrap = try await client.bootstrapWorkspace()
                available = [bootstrap.workspace]
            }
        } catch {
            // Without a Workspace there is no task list to wait for: it says it could not load, the toast says why.
            if boundary == current { tasksLoaded = true; taskListFailed = true }
            throw error
        }
        guard boundary == current else { return }
        workspaces = available
        if let selected = preferredWorkspace(in: available) { try await selectWorkspace(selected, boundary: current) }
    }

    // MARK: Streams

    func startStreams() {
        for pane in panes { pane.startStream() }
        startListStream()
    }

    func stopStreams() {
        for pane in panes { pane.stopStream() }
        stopListStream()
    }

    /// Task-list invalidations for the group. An open Task's own feed carries them instead, because the
    /// client keeps one connection per event path.
    func startListStream() {
        stopListStream()
        guard let workspace, session != nil, task == nil else { return }
        let current = boundary
        listStream = Task { [weak self] in
            var retry = 0
            while !Task.isCancelled {
                guard let self, self.boundary == current, self.session != nil, self.task == nil else { return }
                do {
                    let events = await self.client.taskEvents(workspace: workspace)
                    defer { events.cancel() }
                    for try await event in events {
                        guard self.boundary == current, !Task.isCancelled else { return }
                        retry = 0
                        if ["conversation_list_invalidated", "conversation_list_resync_required"].contains(event.type) {
                            self.scheduleTaskListRefresh()
                        }
                    }
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    guard self.boundary == current, !Task.isCancelled else { return }
                    retry = min(retry + 1, 4)
                    try? await Task.sleep(for: .seconds(min(15, 1 << retry)))
                }
            }
        }
    }

    func stopListStream() {
        listStream?.cancel(); listStream = nil
        listRefresh?.cancel(); listRefresh = nil
    }
}
