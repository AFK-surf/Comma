import CommaCore
import Foundation
import Observation

/**
 * The phone's account, Workspace and task list, as the client core shows them. The core runs the session, the
 * Workspace's chat, the task list and the account's settings; the store reads their topics into what the screens draw
 * and passes on what the person does as the core's calls. Each open conversation is a `ConversationPane` (the
 * core's `chatView`): the Router chat stays open while a Task opens and closes beside it.
 */
@MainActor @Observable
final class CommaStore {
    /// The core said what the session is: the shell or the login can show.
    var initialized = false
    /// The signed-in session, or the kept account's while the core checks it (shown offline too).
    var session: CommaSession?
    /// The sign-in under way, as the core keeps it (any screen continues it).
    var signIn: SignInAttempt?
    /// Why the core cannot tell what the session is (it could not read this iPhone's credential store, or reach the
    /// server): the login says so and offers to try again.
    var sessionProblem: SignInProblem?
    /// Seconds the server asked to wait before another code, counted down from when they were said.
    var resendAt: Date?
    var workspaces: [Workspace] = []
    var workspace: Workspace?
    var tasks: [TaskSummary] = []
    /// Tasks pinned in the Group, as the core's task list says.
    var pinnedTaskIDs: Set<String> = []
    /// The Group's Tasks in the order every client lists them (the core's `taskOrder` sections, one after another):
    /// the statuses in their order, each one's cards as the board has them.
    var taskBoardOrder: [String] = []
    /// The member's editable profile and avatar bytes.
    var profile: UserProfile?
    /// The profile was read (or could not be): the email may stand in for a missing name.
    var profileRead = false
    var avatarData: Data?
    /// The workspace's Routines briefing, shared by every Routines surface.
    let routines = RoutinesModel()
    /// The workspace's skills, which the composer's / menu lists and sends tag.
    let skills = SkillsModel()
    /// The workspace's models, which the router chat's @ menu offers to start a Task with.
    let mentionModels = MentionModelsModel()
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
    /// The Workspace's task list has been read (or the read failed). Until then an empty `tasks` means not read yet.
    var tasksLoaded = false
    /// The task list could not be read and the device kept none.
    var taskListFailed = false
    /// No Workspace could be found or made, so there is neither a router chat nor a task list to wait for.
    var productFailed = false
    var error: String?
    /// Push enrollment is optional and independent of chat, so its failure is reported in Settings.
    private(set) var pushRegistrationError: String?
    var taskNotifications: TaskNotificationController?
    var automaticallyFollowTasks = UserDefaults.standard.object(forKey: "comma.auto-follow-phone-tasks") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticallyFollowTasks, forKey: "comma.auto-follow-phone-tasks")
            onAutomaticFollowingChanged?(automaticallyFollowTasks)
        }
    }
    /// The Tasks the Live Activity follows, as the core last read them.
    var taskActivity: [TaskActivityTask]?

    @ObservationIgnored let configuration: AppConfiguration
    /// The client core: the process's (`CoreRuntime`), or a test's.
    @ObservationIgnored let core: any CoreAPI
    /// Where the core keeps the bearer, whose account shows while the core checks it.
    @ObservationIgnored let custody: SessionCustody
    @ObservationIgnored let apple: AppleSignInSheet
    @ObservationIgnored let workspacePreferences: UserDefaults
    /// Advances with each change of the account shown, so work for the one before writes nothing.
    @ObservationIgnored var boundary = 0
    @ObservationIgnored var lifecycle: SessionSnapshot?
    @ObservationIgnored var resolving: Task<Void, Never>?
    @ObservationIgnored var taskList: Task<Void, Never>?
    @ObservationIgnored var pinWatch: Task<Void, Never>?
    @ObservationIgnored var orderWatch: Task<Void, Never>?
    /// The task list as the core last said it, which a Workspace shown later reads.
    @ObservationIgnored var lastTaskList: TaskList?
    /// The account and session whose Workspace was looked for.
    @ObservationIgnored var connected: String?
    @ObservationIgnored var profileWatch: Task<Void, Never>?
    @ObservationIgnored var activityRequest = 0
    @ObservationIgnored var onActivitySnapshot: (([TaskActivityTask], Workspace) -> Void)?
    @ObservationIgnored var onActivityFailure: ((String) -> Void)?
    @ObservationIgnored var onAuthBoundaryChanged: (() -> Void)?
    @ObservationIgnored var onSessionChanged: ((CommaSession?) -> Void)?
    @ObservationIgnored var onWorkspaceChanged: ((Workspace) -> Void)?
    @ObservationIgnored var validateSession: ((CommaSession) async throws -> Bool)?
    @ObservationIgnored var onAutomaticFollowingChanged: ((Bool) -> Void)?
    /// Runs before sign-out revokes the session, while it can still authorize cleanup requests.
    @ObservationIgnored var beforeLogout: (() async -> Void)?
    @ObservationIgnored private var started = false
    /// The app is in the foreground: a conversation opened now follows its stream (a background launch opens none).
    @ObservationIgnored private(set) var foreground = true

    init(configuration: AppConfiguration, core: any CoreAPI, custody: SessionCustody, apple: AppleSignInSheet,
         workspacePreferences: UserDefaults = .standard) {
        self.configuration = configuration
        self.core = core
        self.custody = custody
        self.apple = apple
        self.workspacePreferences = workspacePreferences
    }

    convenience init(configuration: AppConfiguration, runtime: CoreRuntime, workspacePreferences: UserDefaults = .standard) {
        self.init(configuration: configuration, core: runtime.core, custody: runtime.custody, apple: runtime.apple,
                  workspacePreferences: workspacePreferences)
    }

    /// The session boundary a pane operation captures; sign-in, sign-out and account changes advance it.
    var boundaryToken: Int { boundary }
    func isCurrent(_ value: Int) -> Bool { boundary == value }

    /// The member's name as the profile, else the session, has it; nil while neither has one.
    var memberName: String? {
        [profile?.name, session?.user.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// The member's email as the profile, else the session, has it.
    var memberEmail: String { profile?.email ?? session?.user.email ?? "" }

    /// Starts following the core's session. Safe to call again.
    func start() async {
        guard !started else { return }
        started = true
        let updates = core.subscribe(["topic": "session"], read: SessionSnapshot.init)
        Task { [weak self] in
            for await value in updates {
                guard let self, case .value(let snapshot) = value else { continue }
                self.observe(snapshot)
            }
        }
        // While the app shows the connection's recovery, the core finds the session out again by itself.
        let recovery = core.subscribe(["topic": "sessionRecovery"]) { _ in 0 }
        Task { for await _ in recovery {} }
    }

    // MARK: Conversations

    /// Opens a Task in its own pane. The router chat keeps its transcript and draft.
    func openTask(id: String) async {
        guard let workspace else { return }
        router.setObscured("task", true)
        taskRevealRequest += 1
        if task?.taskID == id, task?.closed == false { return }
        task?.close()
        let pane = ConversationPane(kind: .task(id), workspace: workspace, conversationID: id, store: self)
        task = pane
        pane.open()
    }

    /// Latest known state of a Task: its task-list entry.
    func taskSummary(id: String) -> TaskSummary? { tasks.first { $0.id == id } }

    func closeTask() {
        task?.close()
        task = nil
        router.setObscured("task", false)
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

    func present(_ failure: any Error, boundary current: Int) {
        guard boundary == current, !(failure is CancellationError) else { return }
        if let error = failure as? CoreError, error.code == "cancelled" { return }
        error = failure.localizedDescription
    }

    // MARK: Pane support

    var panes: [ConversationPane] { [router.pane, task].compactMap { $0 } }

    /// The app went to the background: the conversations let their streams go (the core keeps what it read).
    func suspend() {
        foreground = false
        for pane in panes { pane.setForeground(false) }
    }

    /// The app came back: the core checks the session again, and the conversations follow their streams again.
    func resume() async {
        foreground = true
        guard initialized else { return }
        for pane in panes { pane.setForeground(true) }
        if lifecycle?.phase == "signed_in" {
            _ = try? await core.call("session.reconcile", ["reason": "focus"])
        } else if lifecycle?.phase == "indeterminate" {
            _ = try? await core.call("session.recover")
        }
    }

    /// Everything of the account shown goes: a sign-out, or another account.
    func clearProduct() {
        resolving?.cancel(); resolving = nil
        taskList?.cancel(); taskList = nil
        lastTaskList = nil
        pinWatch?.cancel(); pinWatch = nil
        orderWatch?.cancel(); orderWatch = nil
        profileWatch?.cancel(); profileWatch = nil
        for pane in panes { pane.close() }
        router.reset(); task = nil
        workspaces = []; workspace = nil; tasks = []; tasksLoaded = false; taskListFailed = false; productFailed = false
        hasMoreTasks = false; loadingMore = false
        pinnedTaskIDs = []; taskBoardOrder = []
        routines.reset()
        skills.reset()
        mentionModels.reset()
        profile = nil; profileRead = false; avatarData = nil
        taskActivity = nil
        activityRequest += 1
        pushRegistrationError = nil
        toasts.clear()
    }
}

/// A sign-in under way in the core: its ref fences every call that continues it.
struct SignInAttempt: Equatable, Sendable {
    /// The core's attempt ref, as JSON text.
    let ref: String
    let challengeID: String?
    /// The emailed code links an Apple ID to an existing account.
    let linkingApple: Bool
    let email: String?
    let expired: Bool
}

/// The Tasks a Live Activity follows, as the core reads them.
struct TaskActivityTask: Equatable, Sendable {
    let id: String
    let title: String
    let status: String
    let updatedAt: Double?
}
