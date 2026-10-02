import SwiftUI
import AuthenticationServices
import CommaCore

@main
struct CommaApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: CommaStore?
    @StateObject private var activity = TaskActivityCoordinator()
    @State private var pendingURL: URL?
    @State private var pendingURLAccountID: String?
    @State private var configurationError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let store {
                    if !store.initialized {
                        ProgressView("Opening Comma…")
                    } else if store.session != nil {
                        HomeShellView(store: store, activity: activity)
                    } else {
                        PhoneLoginView(store: store)
                    }
                } else if let configurationError {
                    ContentUnavailableView("Unable to start", systemImage: "exclamationmark.triangle",
                                           description: Text(configurationError))
                } else {
                    ProgressView("Opening Comma…")
                }
            }
            .task { await configure() }
            .onChange(of: scenePhase) { _, phase in
                guard let store else { return }
                if phase == .active {
                    appDelegate.foreground()
                    Task { await store.resume() }
                }
                else if phase == .background { store.suspend() }
            }
            .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
                guard let store else { return }
                Task { await store.resume() }
            }
            .onOpenURL { url in
                pendingURL = url
                pendingURLAccountID = store?.session?.user.id
                Task { await consumeLink() }
            }
        }
    }

    private func configure() async {
        guard store == nil else { return }
        do {
            let configuration = try AppConfiguration.current()
            let client = try configuration.makeClient()
            let value = CommaStore(configuration: configuration, client: client)
            value.validateSession = AppleCredentialMonitor.validate
            store = value
            PhonePairingBridge.shared.configure(store: value)
            try appDelegate.configure(store: value)
            value.onTaskUpdated = { task, workspace in
                Task { await activity.apply(Self.projection(task, workspace: workspace)) }
            }
            value.onPhoneTaskCreated = { task, workspace in
                Task { await activity.follow(Self.projection(task, workspace: workspace)) }
            }
            value.onAuthBoundaryChanged = {
                appDelegate.authenticationBoundaryChanged()
                if value.session != nil { pendingURL = nil; pendingURLAccountID = nil }
            }
            value.onSessionChanged = { session in
                appDelegate.sessionChanged(session)
                if session == nil || (pendingURLAccountID != nil && pendingURLAccountID != session?.user.id) {
                    pendingURL = nil; pendingURLAccountID = nil
                }
                Task {
                    guard value.session?.id == session?.id else { return }
                    if let session {
                        if let subject = AppleCredentialMonitor.pendingSubject {
                            AppleCredentialMonitor.save(subject: subject, sessionID: session.id)
                        }
                        if value.workspace != nil { await configureActivity(accountID: session.user.id, store: value) }
                    } else {
                        AppleCredentialMonitor.clear()
                        await activity.stop()
                    }
                    guard value.session?.id == session?.id else { return }
                    PhonePairingBridge.shared.sessionChanged(session)
                }
            }
            value.onWorkspaceChanged = { _ in
                appDelegate.workspaceChanged()
                Task {
                    if let session = value.session { await configureActivity(accountID: session.user.id, store: value) }
                    await consumeLink()
                }
            }
            value.onAutomaticFollowingChanged = { enabled in
                Task { await activity.setAutomaticFollowing(enabled) }
            }
            await value.start()
            await consumeLink()
        } catch { configurationError = error.localizedDescription }
    }

    private func configureActivity(accountID: String, store: CommaStore) async {
        let client = store.client
        guard let environment = try? store.configuration.pushEnvironment,
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let locale = PhoneAppDelegate.notificationLocale
        await activity.configure(accountID: accountID, automaticFollowing: store.automaticallyFollowPhoneTasks, register: { registration in
            let projection = registration.projection
            let workspace = Workspace(id: projection.workspaceID, groupID: projection.groupID, name: "")
            return try await client.registerLiveActivityToken(registration.token, environment: environment,
                                                              workspace: workspace, activityID: registration.activityID,
                                                              taskID: projection.taskID, bundleID: bundleID, locale: locale).id
        }, unregister: { id in
            try await client.unregisterNotification(id: id)
        }, registerPushToStart: { token in
            guard let workspace = await store.workspace else { throw CommaError.notSignedIn }
            return try await client.registerPushToStartToken(token, environment: environment, workspace: workspace, bundleID: bundleID, locale: locale).id
        })
    }

    static func projection(_ task: Conversation, workspace: Workspace) -> TaskActivityProjection {
        TaskActivityProjection(workspaceID: workspace.id, groupID: task.groupID, taskID: task.id,
                               title: task.title, status: task.status,
                               updatedAt: Date(timeIntervalSince1970: normalizedEpoch(task.updatedAt ?? 0)))
    }

    private static func normalizedEpoch(_ value: Double) -> Double { value > 100_000_000_000 ? value / 1000 : value }

    private func consumeLink() async {
        guard let pendingURL, let store, store.session != nil, !store.workspaces.isEmpty else { return }
        self.pendingURL = nil
        pendingURLAccountID = nil
        await open(pendingURL, store: store)
    }

    private func open(_ url: URL, store: CommaStore) async {
        guard let session = store.session, ["comma", "comma-ios-dev"].contains(url.scheme), url.host == "task",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let taskID = components.queryItems?.first(where: { $0.name == "task" })?.value,
              let workspaceID = components.queryItems?.first(where: { $0.name == "workspace" })?.value,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let boundary = store.boundaryToken
        if store.workspace?.id != workspace.id { await store.chooseWorkspace(workspace) }
        guard store.isCurrent(boundary), store.session?.id == session.id,
              store.session?.user.id == session.user.id, store.workspace?.id == workspace.id else { return }
        await store.openTask(id: taskID)
        guard store.isCurrent(boundary), store.session?.id == session.id else { return }
    }
}
