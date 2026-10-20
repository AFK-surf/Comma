import Foundation
import Observation
import CommaCore

/// Session, workspace and task-list owner. Each open conversation is a `ConversationPane`:
/// the router chat stays loaded while a Task opens and closes beside it.
@MainActor @Observable
final class CommaStore {
    var initialized = false
    var session: CommaSession?
    var workspaces: [Workspace] = []
    var workspace: Workspace?
    var tasks: [Conversation] = []
    /// Tasks pinned in the Group. A failed pin read keeps the last known set.
    var pinnedTaskIDs: Set<String> = []
    /// The member's editable profile and avatar bytes, read when a view first needs them.
    var profile: UserProfile?
    var avatarData: Data?
    /// The workspace's Routines briefing, shared by every Routines surface.
    let routines = RoutinesModel()
    /// The workspace's skills, which the composer's / menu lists and sends tag.
    let skills = SkillsModel()
    /// The router chat ("Comma"), its visibility and unread replies.
    let router = RouterChatModel()
    /// The notice over the app; iPhone and iPad draw it (`ToastStage`).
    let toasts = ToastCenter()
    /// The Task shown in the bottom sheet. Opening another Task replaces it; the router chat is untouched.
    private(set) var task: ConversationPane?
    /// Advances on every request to show a Task, including the one already open, so the sheet expands.
    private(set) var taskRevealRequest = 0
    var loading = false
    var loadingMore = false
    var hasMoreTasks = false
    /// The current workspace's first page of Tasks has been read (or the read failed). Until then an empty
    /// `tasks` means not read yet, not no Tasks: a workspace restored in the background has none read.
    var tasksLoaded = false
    /// The last read of the first page of Tasks failed. With nothing read before it, the list has no Tasks to show
    /// and says it could not load them; with Tasks read, they stay and the failure is only the toast.
    var taskListFailed = false
    /// No Workspace could be listed or made, so there is neither a router chat nor a task list to wait for.
    var productFailed: Bool { workspace == nil && taskListFailed }
    private(set) var error: String?
    /// Push enrollment is optional and independent of chat, so its failure is reported in Settings.
    private(set) var pushRegistrationError: String?
    var taskNotifications: TaskNotificationController?
    var automaticallyFollowTasks = UserDefaults.standard.object(forKey: "comma.auto-follow-phone-tasks") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticallyFollowTasks, forKey: "comma.auto-follow-phone-tasks")
            onAutomaticFollowingChanged?(automaticallyFollowTasks)
        }
    }

    @ObservationIgnored let configuration: AppConfiguration
    @ObservationIgnored let client: CommaClient
    @ObservationIgnored let workspacePreferences: UserDefaults
    @ObservationIgnored var boundary = 0
    @ObservationIgnored var listStream: Task<Void, Never>?
    @ObservationIgnored var listRefresh: Task<Void, Never>?
    @ObservationIgnored var listRefreshRevision = 0
    @ObservationIgnored var nextTaskCursor: String?
    /// The product read in flight and its boundary, which a second request in that boundary joins.
    @ObservationIgnored var productLoad: (boundary: Int, task: Task<Void, any Error>)?
    @ObservationIgnored private var drafts: [ConversationTarget: String] = [:]
    @ObservationIgnored var onActivitySnapshot: ((TaskActivitySnapshot, Workspace) -> Void)?
    @ObservationIgnored var onActivityFailure: ((String) -> Void)?
    var taskActivitySnapshot: TaskActivitySnapshot?
    @ObservationIgnored var activityRequest = 0
    @ObservationIgnored var onAuthBoundaryChanged: (() -> Void)?
    @ObservationIgnored var onSessionChanged: ((CommaSession?) -> Void)?
    @ObservationIgnored var onWorkspaceChanged: ((Workspace) -> Void)?
    @ObservationIgnored var profileLoad: Task<Void, Never>?
    @ObservationIgnored var validateSession: ((CommaSession) async throws -> Bool)?
    @ObservationIgnored var onAutomaticFollowingChanged: ((Bool) -> Void)?
    /// Runs before sign-out revokes the session, while it can still authorize cleanup requests.
    @ObservationIgnored var beforeLogout: (() async -> Void)?

    init(configuration: AppConfiguration, client: CommaClient, workspacePreferences: UserDefaults = .standard) {
        self.configuration = configuration
        self.client = client
        self.workspacePreferences = workspacePreferences
    }

    /// The session boundary a pane operation captures; sign-in, sign-out and resets advance it.
    var boundaryToken: Int { boundary }
    func isCurrent(_ value: Int) -> Bool { boundary == value }

    // MARK: Workspace and conversations

    /// Loads the router chat once per workspace. Later calls keep the loaded transcript.
    func openRouter() async {
        guard let workspace, router.pane == nil || router.pane?.closed == true else { return }
        let pane = ConversationPane(kind: .router, workspace: workspace, store: self)
        router.install(pane)
        await pane.load()
    }

    /// Opens a Task in its own pane. The router chat keeps its transcript, stream and draft.
    func openTask(id: String) async {
        guard let workspace else { return }
        router.setObscured("task", true)
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
        router.setObscured("task", false)
        startListStream()
    }

    /// A notification tap: the Task sheet closes and the router chat comes forward.
    func revealRouter() {
        closeTask()
        router.requestReveal()
    }

    func dismissError() { error = nil }
    func showError(_ value: String) { error = value }
    func dismissPushRegistrationError() { pushRegistrationError = nil }
    func reportPushRegistration(_ failure: String?) { pushRegistrationError = failure }

    // MARK: Pane support

    func draft(for target: ConversationTarget) -> String? { drafts[target] }
    func saveDraft(_ text: String, for target: ConversationTarget) { drafts[target] = text }

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

    // MARK: Product

    var panes: [ConversationPane] { [router.pane, task].compactMap { $0 } }

    func selectWorkspace(_ value: Workspace, boundary current: Int) async throws {
        for pane in panes { pane.close() }
        task = nil
        router.setObscured("task", false)
        stopListStream()
        workspace = value
        rememberWorkspace(value)
        onWorkspaceChanged?(value)
        tasks = []
        tasksLoaded = false
        taskListFailed = false
        hasMoreTasks = false
        pinnedTaskIDs = []
        routines.reset()
        skills.reset()
        taskActivitySnapshot = nil
        activityRequest += 1
        nextTaskCursor = nil
        let pane = ConversationPane(kind: .router, workspace: value, store: self)
        router.install(pane)
        // The router chat and the task list are independent reads; neither waits for the other.
        async let tasksLoaded: Void = refreshTasks(boundary: current)
        await pane.load()
        let listFailure: (any Error)?
        do { try await tasksLoaded; listFailure = nil } catch { listFailure = error }
        guard boundary == current, workspace?.id == value.id else { return }
        // Live changes do not wait on the first read: a list read again after it failed still follows them.
        startListStream()
        if let listFailure { throw listFailure }
    }

    @discardableResult func resetBoundary() -> Int {
        boundary += 1
        onAuthBoundaryChanged?()
        for pane in panes { pane.invalidateSends() }
        clearProduct()
        error = nil
        return boundary
    }

    func clearProduct() {
        stopStreams()
        for pane in panes { pane.close() }
        router.reset(); task = nil
        workspaces = []; workspace = nil; tasks = []; tasksLoaded = false; taskListFailed = false
        hasMoreTasks = false; nextTaskCursor = nil; loadingMore = false
        pinnedTaskIDs = []
        routines.reset()
        skills.reset()
        profileLoad?.cancel(); profileLoad = nil
        profile = nil; avatarData = nil
        taskActivitySnapshot = nil
        activityRequest += 1
        drafts = [:]
        pushRegistrationError = nil
        toasts.clear()
    }

    func present(_ failure: any Error, boundary current: Int) {
        guard boundary == current, !(failure is CancellationError) else { return }
        error = failure.localizedDescription
        checkSessionAfter(failure)
    }
}
