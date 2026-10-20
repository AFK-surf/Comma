import UIKit
import UserNotifications
import Combine
import AuthenticationServices
import CommaCore
@preconcurrency import ActivityKit

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    @Published private(set) var store: CommaStore?
    @Published private(set) var configurationError: String?
    /// The voice call, created with the store and living as long as the process.
    @Published private(set) var call: CallController?
    let activity: TaskActivityCoordinator
    private let makeStore: @MainActor () throws -> CommaStore
    private let notificationSetup: (@MainActor (PhoneAppDelegate, CommaStore) throws -> Void)?
    private var bootstrapTask: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?
    private(set) var activityConfigurationTask: Task<Void, Never>?
    private var appleCredentialObservation: AnyCancellable?
    let system = PhoneNotificationSystem()
    var pendingRoute: (route: NativeNotificationRoute, boundary: Int, accountID: String?)?
    private(set) var sceneActive = UIApplication.shared.applicationState == .active
    var badgeWorker: Task<Void, Never>?
    var badgeRevision = 0
    var acknowledgedMessageID: String?
    var badgeRetry: Task<Void, Never>?
    var badgeRetryCount = 0
    let setBadge: @MainActor (Int) async -> Void
    let badgePermission: @MainActor () async -> Bool

    override convenience init() {
        self.init(activity: TaskActivityCoordinator())
    }

    init(activity: TaskActivityCoordinator = TaskActivityCoordinator(),
         makeStore: @escaping @MainActor () throws -> CommaStore = {
             let configuration = try AppConfiguration.current()
             return CommaStore(configuration: configuration, runtime: try CoreRuntime.make(baseURL: configuration.baseURL))
         }, notificationSetup: (@MainActor (PhoneAppDelegate, CommaStore) throws -> Void)? = nil,
         badgePermission: @escaping @MainActor () async -> Bool = {
        await UNUserNotificationCenter.current().notificationSettings().badgeSetting == .enabled
    }, setBadge: @escaping @MainActor (Int) async -> Void = { count in
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }) {
        self.badgePermission = badgePermission
        self.setBadge = setBadge
        self.activity = activity
        self.makeStore = makeStore
        self.notificationSetup = notificationSetup
        super.init()
    }
    var lastAccountID: String?
    var lastSessionID: String?
    var retiredSessionIDs: [String] = []
    var authenticationSuspended = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        launch(state: application.applicationState)
        return true
    }

    /// ActivityKit can launch the process without creating a SwiftUI scene.
    func launch(state: UIApplication.State) {
        sceneActive = state == .active
        beginBootstrap()
    }

    func bootstrap() async {
        beginBootstrap()
        await bootstrapTask?.value
    }

    private func beginBootstrap() {
        guard bootstrapTask == nil else { return }
        do {
            let value = try makeStore()
            value.validateSession = AppleCredentialMonitor.validate
            if let notificationSetup { try notificationSetup(self, value) }
            else { try configure(store: value) }
            wireRuntime(value)
            store = value
            let call = CallController(store: value)
            value.beforeLogout = { [weak call] in await call?.signOut() }
            self.call = call
            configurationError = nil
            PhonePairingBridge.shared.configure(store: value) { [weak self] in await self?.bootstrap() }
            bootstrapTask = Task { [weak self, weak value] in
                guard let self, let value else { return }
                await value.start()
                await self.activityConfigurationTask?.value
                await self.activity.settleRegistrations()
            }
        } catch { configurationError = error.localizedDescription }
    }

    /// A scene joins the launch task and then enables the existing foreground product path.
    func startForeground() async {
        guard UIApplication.shared.applicationState == .active else { background(); return }
        foreground()
        if let foregroundTask { await foregroundTask.value; return }
        let worker = Task { [weak self] in
            guard let self else { return }
            defer { self.foregroundTask = nil }
            await self.bootstrap()
            guard self.sceneActive, let value = self.store else { return }
            PhonePairingBridge.shared.sessionChanged(value.session)
            await value.resume()
            guard self.sceneActive else { value.suspend(); return }
            self.workspaceChanged()
            self.synchronizeBadge()
            await self.activityConfigurationTask?.value
            guard self.sceneActive else { value.suspend(); return }
            await self.activity.retry()
        }
        foregroundTask = worker
        await worker.value
    }

    private func wireRuntime(_ value: CommaStore) {
        value.onActivitySnapshot = { [weak self, weak value] snapshot, workspace in
            guard let value else { return }
            let boundary = value.boundaryToken
            Task { [weak self, weak value] in
                guard let self, let value, self.sceneActive, value.isCurrent(boundary), value.workspace?.id == workspace.id,
                      value.taskActivity == snapshot else { return }
                await self.activity.apply(CommaApp.projection(snapshot, workspace: workspace))
            }
        }
        value.onActivityFailure = { [weak self] _ in self?.activity.reportRefreshFailure() }
        value.onAuthBoundaryChanged = { [weak self] in self?.authenticationBoundaryChanged() }
        value.onSessionChanged = { [weak self, weak value] session in
            guard let self, let value else { return }
            self.sessionChanged(session)
            if let session, let subject = AppleCredentialMonitor.pendingSubject {
                AppleCredentialMonitor.save(subject: subject, sessionID: session.id)
            }
            if session == nil { AppleCredentialMonitor.clear(); self.call?.sessionEnded() }
            self.scheduleActivityConfiguration(value)
            if self.sceneActive { PhonePairingBridge.shared.sessionChanged(session) }
        }
        value.onWorkspaceChanged = { [weak self, weak value] _ in
            guard let self, let value else { return }
            self.workspaceChanged()
            self.scheduleActivityConfiguration(value)
        }
        value.onAutomaticFollowingChanged = { [weak self, weak value] enabled in
            Task { [weak self, weak value] in
                guard let self, let value, value.automaticallyFollowTasks == enabled else { return }
                await self.activity.setAutomaticFollowing(enabled)
            }
        }
        appleCredentialObservation = NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)
            .sink { [weak self, weak value] _ in
                Task { @MainActor [weak self, weak value] in
                    guard let self, let value, let session = value.session else { return }
                    let boundary = value.boundaryToken
                    guard let validate = value.validateSession,
                          let valid = try? await validate(session),
                          value.isCurrent(boundary), value.session?.id == session.id else { return }
                    if !valid { await value.logout() }
                    else if self.sceneActive { await value.resume() }
                }
            }
    }

    func scheduleActivityConfiguration(_ value: CommaStore) {
        let boundary = value.boundaryToken
        let session = value.session
        let workspace = value.workspace
        activityConfigurationTask = Task { [weak self, weak value] in
            guard let self, let value, value.isCurrent(boundary), value.session?.id == session?.id,
                  value.workspace?.id == workspace?.id else { return }
            if let session, let workspace {
                await self.configureActivity(session: session, workspace: workspace, store: value, boundary: boundary)
            } else if session == nil { await self.activity.stop() }
        }
    }

    private func configureActivity(session: CommaSession, workspace: Workspace, store: CommaStore, boundary: Int) async {
        guard let environment = try? store.configuration.pushEnvironment,
              let bundleID = Bundle.main.bundleIdentifier,
              let channel = try? store.activityNotificationChannel(workspace: workspace, environment: environment,
                  bundleID: bundleID, locale: Self.notificationLocale),
              store.isCurrent(boundary), store.session?.id == session.id, store.workspace?.id == workspace.id else { return }
        await activity.configure(accountID: session.user.id, workspace: workspace, origin: store.configuration.baseURL.absoluteString,
                                 automaticFollowing: store.automaticallyFollowTasks, channel: channel)
        guard store.isCurrent(boundary), store.session?.id == session.id, store.workspace?.id == workspace.id else { return }
        if sceneActive, let snapshot = store.taskActivity {
            await activity.apply(CommaApp.projection(snapshot, workspace: workspace))
        }
    }

    func configure(store: CommaStore) throws {
        self.store = store
        let bundleID = Bundle.main.bundleIdentifier
        guard let bundleID, !bundleID.isEmpty else { throw AppConfiguration.ConfigurationError.invalidPushEnvironment }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        store.taskNotifications = TaskNotificationController(origin: store.configuration.baseURL.absoluteString,
            bundleID: bundleID, environment: try store.configuration.pushEnvironment, locale: Self.notificationLocale,
            preferences: FileTaskNotificationPreferences(url: directory.appendingPathComponent("task-notifications.json")), system: system)
        store.router.onVisibilityChanged = { [weak self] in self?.synchronizeBadge() }
        UNUserNotificationCenter.current().delegate = self
        // APNs acquisition is independent of ordinary-alert consent and does not prompt.
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Also permits app integration tests to keep the OS adapter outside the HTTP/read boundary.
    func attach(store: CommaStore) {
        self.store = store
        store.router.onVisibilityChanged = { [weak self] in self?.synchronizeBadge() }
    }

    static var notificationLocale: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "zh-Hans" : "en-US"
    }

    func foreground() {
        sceneActive = true
        badgeRetryCount = 0
        synchronize()
        store?.taskNotifications?.refresh(locale: Self.notificationLocale)
        synchronizeBadge()
    }

    func background() { sceneActive = false; badgeRevision += 1; store?.suspend() }

    func applicationDidEnterBackground(_ application: UIApplication) { background() }
}
