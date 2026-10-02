import Foundation
import Observation
import CommaCore

/// Session, workspace and task-list owner. Each open conversation is a `ConversationPane`:
/// Home stays loaded while a Task opens and closes beside it.
@MainActor @Observable
final class CommaStore {
    private(set) var initialized = false
    private(set) var session: CommaSession?
    private(set) var workspaces: [Workspace] = []
    private(set) var workspace: Workspace?
    private(set) var tasks: [Conversation] = []
    /// Tasks pinned in the Group. A failed pin read keeps the last known set.
    private(set) var pinnedTaskIDs: Set<String> = []
    /// The member's editable profile and avatar bytes, read when a view first needs them.
    private(set) var profile: UserProfile?
    private(set) var avatarData: Data?
    /// The workspace's Routines briefing, shared by every Routines surface.
    let routines = RoutinesModel()
    private(set) var home: ConversationPane?
    /// The Task shown in the bottom sheet. Opening another Task replaces it; Home is untouched.
    private(set) var task: ConversationPane?
    /// Advances on every request to show a Task, including the one already open, so the sheet expands.
    private(set) var taskRevealRequest = 0
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var hasMoreTasks = false
    private(set) var error: String?
    /// Push enrollment is optional and independent of chat, so its failure is reported in Settings.
    private(set) var pushRegistrationError: String?
    var taskNotifications: TaskNotificationController?
    var automaticallyFollowPhoneTasks = UserDefaults.standard.object(forKey: "comma.auto-follow-phone-tasks") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticallyFollowPhoneTasks, forKey: "comma.auto-follow-phone-tasks")
            onAutomaticFollowingChanged?(automaticallyFollowPhoneTasks)
        }
    }

    @ObservationIgnored let configuration: AppConfiguration
    @ObservationIgnored let client: CommaClient
    @ObservationIgnored private var boundary = 0
    @ObservationIgnored private var listStream: Task<Void, Never>?
    @ObservationIgnored private var listRefresh: Task<Void, Never>?
    @ObservationIgnored private var nextTaskCursor: String?
    @ObservationIgnored private var drafts: [ConversationTarget: String] = [:]
    @ObservationIgnored var onTaskUpdated: ((Conversation, Workspace) -> Void)?
    @ObservationIgnored var onPhoneTaskCreated: ((Conversation, Workspace) -> Void)?
    @ObservationIgnored var onAuthBoundaryChanged: (() -> Void)?
    @ObservationIgnored var onSessionChanged: ((CommaSession?) -> Void)?
    @ObservationIgnored var onWorkspaceChanged: ((Workspace) -> Void)?
    @ObservationIgnored private var taskBaseline: Set<String>?
    @ObservationIgnored private var profileLoad: Task<Void, Never>?
    @ObservationIgnored private var taskFollowSince = Date().timeIntervalSince1970
    @ObservationIgnored var validateSession: ((CommaSession) async throws -> Bool)?
    @ObservationIgnored var onAutomaticFollowingChanged: ((Bool) -> Void)?

    init(configuration: AppConfiguration, client: CommaClient) {
        self.configuration = configuration
        self.client = client
    }

    /// The session boundary a pane operation captures; sign-in, sign-out and resets advance it.
    var boundaryToken: Int { boundary }
    func isCurrent(_ value: Int) -> Bool { boundary == value }

    // MARK: Session

    func start() async {
        let current = boundary
        loading = true
        defer { if boundary == current { loading = false; initialized = true } }
        do {
            // The Apple credential check is its own round trip to Apple; run it beside the session check,
            // keyed by the Keychain session. Both must pass before the session is used, as before.
            let stored = try? await client.storedSession()
            let appleCheck = Task { @MainActor [weak self] () throws -> Bool in
                guard let stored, let validate = self?.validateSession else { return true }
                return try await validate(stored)
            }
            let restored = try await client.restoreSession()
            var authorized = try await appleCheck.value
            guard boundary == current else { return }
            // restoreSession refuses a different session, so this only covers an absent Keychain entry.
            if let restored, restored.id != stored?.id, let validateSession {
                authorized = try await validateSession(restored)
            }
            if restored != nil, !authorized {
                try await client.clearLocalSession()
                throw CommaError.invalidInput("Apple authorization was revoked. Sign in again.")
            }
            guard boundary == current else { return }
            session = restored
            onSessionChanged?(restored)
            // The shell shows now; Home and the task list load inside it with their own indicators.
            initialized = true
            if restored != nil { try await loadProduct(boundary: current) }
        } catch { present(error, boundary: current) }
    }

    func requestEmailCode(email: String) async throws -> EmailChallenge {
        try await client.requestEmailLogin(email: email)
    }

    /// Returns false when the code was rejected, so the login screen can show its error feedback.
    @discardableResult
    func verifyEmail(challengeID: String, code: String, appleLink: Bool = false) async -> Bool {
        let current = resetBoundary()
        loading = true
        defer { if boundary == current { loading = false } }
        let result: CommaSession
        do {
            result = appleLink
                ? try await client.verifyAppleLink(challengeID: challengeID, code: code)
                : try await client.verifyEmailLogin(challengeID: challengeID, code: code)
        } catch {
            present(error, boundary: current)
            return false
        }
        guard boundary == current else { return true }
        session = result
        onSessionChanged?(result)
        do { try await loadProduct(boundary: current) } catch { present(error, boundary: current) }
        return true
    }

    func signedIn(_ result: CommaSession) async {
        guard await client.session?.id == result.id else { return }
        let current = resetBoundary()
        session = result
        onSessionChanged?(result)
        loading = true
        defer { if boundary == current { loading = false } }
        do { try await loadProduct(boundary: current) }
        catch { present(error, boundary: current) }
    }

    func logout() async {
        boundary += 1
        onAuthBoundaryChanged?()
        for pane in panes { pane.invalidateSends() }
        let current = boundary
        stopStreams()
        loading = true
        defer { if boundary == current { loading = false } }
        do {
            try await client.logout()
            guard boundary == current else { return }
            clearProduct()
            session = nil
            onSessionChanged?(nil)
        } catch {
            present(error, boundary: current)
            if boundary == current { onSessionChanged?(session); startStreams() }
        }
    }

    func invalidateLocalSession() async {
        let current = resetBoundary()
        do { try await client.clearLocalSession() } catch { present(error, boundary: current) }
        guard boundary == current else { return }
        session = nil
        onSessionChanged?(nil)
    }

    // MARK: Workspace and conversations

    func chooseWorkspace(_ value: Workspace) async {
        let current = boundary
        loading = true
        defer { if boundary == current, workspace?.id == value.id { loading = false } }
        do {
            try await selectWorkspace(value, boundary: current)
        } catch { present(error, boundary: current) }
    }

    /// Loads Home once per workspace. Later calls keep the loaded transcript.
    func openHome() async {
        guard let workspace, home == nil || home?.closed == true else { return }
        let pane = ConversationPane(kind: .home, workspace: workspace, store: self)
        home = pane
        await pane.load()
    }

    /// Opens a Task in its own pane. Home keeps its transcript, stream and draft.
    func openTask(id: String) async {
        guard let workspace else { return }
        taskRevealRequest += 1
        if task?.taskID == id, task?.closed == false { return }
        task?.close()
        stopListStream()
        let pane = ConversationPane(kind: .task(id), workspace: workspace, store: self)
        task = pane
        await pane.load()
    }

    /// Latest known state of a Task: the open Task's own detail, else its task-list entry.
    func taskSummary(id: String) -> Conversation? {
        if task?.taskID == id, let detail = task?.conversation { return detail }
        return tasks.first { $0.id == id }
    }

    func closeTask() {
        task?.close()
        task = nil
        startListStream()
    }

    func refresh() async {
        guard session != nil else { await start(); return }
        let current = boundary
        do { try await refreshTasks(boundary: current) } catch { present(error, boundary: current) }
        await home?.refresh()
        await task?.refresh()
    }

    func refreshTaskList() async {
        let current = boundary
        do { try await refreshTasks(boundary: current) } catch { present(error, boundary: current) }
    }

    func resume() async {
        guard initialized, let session else { return }
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
        } else { await refresh(); startStreams() }
    }

    func suspend() {
        stopStreams()
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

    // MARK: Profile

    /// Reads the profile and avatar once per session; later calls reuse them.
    func loadProfile() async {
        guard session != nil else { return }
        if let profileLoad { return await profileLoad.value }
        let current = boundary
        let load = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.client.profile()
                guard self.boundary == current else { return }
                await self.install(profile: value, boundary: current)
            } catch {
                // The avatar is decoration: without it the initials show.
                guard self.boundary == current else { return }
                self.profileLoad = nil
            }
        }
        profileLoad = load
        await load.value
    }

    func updateProfile(name: String) async throws {
        let current = boundary
        let value = try await client.updateProfile(name: name)
        guard boundary == current else { return }
        await install(profile: value, boundary: current)
    }

    func uploadAvatar(_ data: Data, contentType: String) async throws {
        let current = boundary
        let value = try await client.uploadAvatar(data: data, contentType: contentType)
        guard boundary == current else { return }
        if value.avatarID != nil { avatarData = data }
        profile = value
    }

    func removeAvatar() async throws {
        let current = boundary
        let value = try await client.deleteAvatar()
        guard boundary == current else { return }
        profile = value
        avatarData = nil
    }

    private func install(profile value: UserProfile, boundary current: Int) async {
        let changedAvatar = value.avatarID != profile?.avatarID
        profile = value
        guard changedAvatar else { return }
        avatarData = nil
        guard let id = value.avatarID, let data = try? await client.avatar(id: id), boundary == current, profile?.avatarID == id else { return }
        avatarData = data
    }

    func dismissError() { error = nil }
    func showError(_ value: String) { error = value }
    func dismissPushRegistrationError() { pushRegistrationError = nil }
    func reportPushRegistration(_ failure: String?) { pushRegistrationError = failure }

    // MARK: Pane support

    func draft(for target: ConversationTarget) -> String? { drafts[target] }
    func saveDraft(_ text: String, for target: ConversationTarget) { drafts[target] = text }

    func taskUpdated(_ detail: Conversation) {
        if let workspace { onTaskUpdated?(detail, workspace) }
    }

    /// A pane failure can mean the session ended elsewhere; then the whole product resets.
    func checkSessionAfter(_ failure: any Error) {
        let current = boundary
        Task { [weak self] in
            guard let self, self.boundary == current, self.session != nil,
                  await self.client.session == nil else { return }
            self.resetBoundary()
            self.session = nil
            self.error = failure.localizedDescription
            self.onSessionChanged?(nil)
        }
    }

    func scheduleTaskListRefresh() {
        guard listRefresh == nil else { return }
        let current = boundary
        listRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.boundary == current else { return }
            do { try await self.refreshTasks(boundary: current) } catch { self.present(error, boundary: current) }
            if self.boundary == current { self.listRefresh = nil }
        }
    }

    // MARK: Product

    private var panes: [ConversationPane] { [home, task].compactMap { $0 } }

    private func loadProduct(boundary current: Int) async throws {
        var available = try await client.listWorkspaces()
        guard boundary == current else { return }
        if available.isEmpty {
            let bootstrap = try await client.bootstrapWorkspace()
            available = [bootstrap.workspace]
        }
        guard boundary == current else { return }
        workspaces = available
        if let first = available.first { try await selectWorkspace(first, boundary: current) }
    }

    private func selectWorkspace(_ value: Workspace, boundary current: Int) async throws {
        for pane in panes { pane.close() }
        task = nil
        stopListStream()
        workspace = value
        onWorkspaceChanged?(value)
        tasks = []
        pinnedTaskIDs = []
        routines.reset()
        taskBaseline = nil
        taskFollowSince = Date().timeIntervalSince1970
        nextTaskCursor = nil
        let pane = ConversationPane(kind: .home, workspace: value, store: self)
        home = pane
        // Home and the task list are independent reads; neither waits for the other.
        async let tasksLoaded: Void = refreshTasks(boundary: current)
        await pane.load()
        try await tasksLoaded
        guard boundary == current, workspace?.id == value.id else { return }
        startListStream()
    }

    private func refreshTasks(boundary current: Int) async throws {
        guard let workspace else { return }
        async let pins = client.pinnedTasks(workspace: workspace)
        let page = try await client.listTasks(workspace: workspace)
        let pinned = try? await pins
        guard boundary == current, self.workspace?.id == workspace.id else { return }
        if let pinned { pinnedTaskIDs = Set(pinned.map(\.conversation.id)) }
        let next = page.data.filter(\.isTask)
        if let baseline = taskBaseline, automaticallyFollowPhoneTasks {
            let created = next.filter {
                !baseline.contains($0.id) && Self.epoch($0.createdAt ?? 0) >= taskFollowSince && $0.origin == "comma" && $0.clientPlatform == "ios" &&
                ($0.bucket == .inProgress || $0.bucket == .backlog || $0.bucket == .needsReview)
            }.max { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }
            if let created { onPhoneTaskCreated?(created, workspace) }
        }
        taskBaseline = (taskBaseline ?? []).union(next.map(\.id))
        tasks = next
        nextTaskCursor = page.nextCursor
        hasMoreTasks = page.hasMore == true
        for task in tasks { onTaskUpdated?(task, workspace) }
    }

    private static func epoch(_ value: Double) -> Double { value > 100_000_000_000 ? value / 1000 : value }

    // MARK: Streams

    private func startStreams() {
        for pane in panes { pane.startStream() }
        startListStream()
    }

    private func stopStreams() {
        for pane in panes { pane.stopStream() }
        stopListStream()
    }

    /// Task-list invalidations for the group. An open Task's own feed carries them instead, because the
    /// client keeps one connection per event path.
    private func startListStream() {
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

    private func stopListStream() {
        listStream?.cancel(); listStream = nil
        listRefresh?.cancel(); listRefresh = nil
    }

    @discardableResult private func resetBoundary() -> Int {
        boundary += 1
        onAuthBoundaryChanged?()
        for pane in panes { pane.invalidateSends() }
        clearProduct()
        error = nil
        return boundary
    }

    private func clearProduct() {
        stopStreams()
        for pane in panes { pane.close() }
        home = nil; task = nil
        workspaces = []; workspace = nil; tasks = []
        pinnedTaskIDs = []
        routines.reset()
        profileLoad?.cancel(); profileLoad = nil
        profile = nil; avatarData = nil
        taskBaseline = nil
        drafts = [:]
        pushRegistrationError = nil
    }

    private func present(_ failure: any Error, boundary current: Int) {
        guard boundary == current, !(failure is CancellationError) else { return }
        error = failure.localizedDescription
        checkSessionAfter(failure)
    }
}

struct PendingSend: Identifiable {
    enum Status { case sending, accepted, failed }
    let id = UUID().uuidString
    let target: ConversationTarget
    let text: String
    let attachments: [ContentBlock]
    var status: Status = .sending
}
