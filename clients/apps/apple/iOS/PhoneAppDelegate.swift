import UIKit
import UserNotifications
import CommaCore

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private weak var store: CommaStore?
    private let system = PhoneNotificationSystem()
    private var pendingTask: (id: String, workspaceID: String, boundary: Int, accountID: String?)?
    private var lastAccountID: String?
    private var lastSessionID: String?
    private var retiredSessionIDs: [String] = []
    private var authenticationSuspended = false

    func configure(store: CommaStore) throws {
        self.store = store
        let bundleID = Bundle.main.bundleIdentifier
        guard let bundleID, !bundleID.isEmpty else { throw AppConfiguration.ConfigurationError.invalidPushEnvironment }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        store.taskNotifications = TaskNotificationController(origin: store.client.baseURL.absoluteString,
            bundleID: bundleID, environment: try store.configuration.pushEnvironment, locale: Self.notificationLocale,
            preferences: FileTaskNotificationPreferences(url: directory.appendingPathComponent("task-notifications.json")), system: system)
        UNUserNotificationCenter.current().delegate = self
        // APNs acquisition is independent of ordinary-alert consent and does not prompt.
        UIApplication.shared.registerForRemoteNotifications()
    }

    static var notificationLocale: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "zh-Hans" : "en-US"
    }

    func authenticationBoundaryChanged() {
        authenticationSuspended = true
        if store?.session != nil { pendingTask = nil }
        store?.taskNotifications?.suspendIdentity()
    }

    func sessionChanged(_ session: CommaSession?) {
        guard let store else { return }
        authenticationSuspended = false
        store.taskNotifications?.resumeIdentity()
        if let lastSessionID, lastSessionID != session?.id {
            retiredSessionIDs = Array((retiredSessionIDs + [lastSessionID]).suffix(8))
        }
        lastSessionID = session?.id
        if session == nil || (lastAccountID != nil && lastAccountID != session?.user.id) {
            pendingTask = nil
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        } else if let route = pendingTask, route.accountID != nil && route.accountID != session?.user.id {
            pendingTask = nil
        }
        lastAccountID = session?.user.id
        synchronize()
    }

    func workspaceChanged() {
        guard !authenticationSuspended else { return }
        synchronize()
        if let route = pendingTask, let store, store.session != nil, !store.workspaces.isEmpty {
            pendingTask = nil
            guard route.accountID == nil || (route.accountID == store.session?.user.id && route.boundary == store.boundaryToken) else { return }
            guard let fence = NotificationNavigationFence(store: store) else { return }
            Task { await openTask(id: route.id, workspaceID: route.workspaceID, fence: fence) }
        }
    }

    func foreground() {
        synchronize()
        store?.taskNotifications?.refresh(locale: Self.notificationLocale)
    }

    private func synchronize() {
        guard !authenticationSuspended, let store, let notifications = store.taskNotifications else { return }
        let session = store.session
        notifications.setContext(sessionID: session?.id, accountID: session?.user.id, workspace: store.workspace)
        guard let session else { return }
        let boundary = store.boundaryToken
        Task {
            guard let channel = try? await store.client.deviceNotificationChannel(),
                  store.isCurrent(boundary), !self.authenticationSuspended,
                  store.session?.id == session.id, store.session?.user.id == session.user.id else { return }
            notifications.attach(channel)
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        system.received(token)
        store?.taskNotifications?.tokenChanged()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        system.failed()
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let store, store.session != nil else { completionHandler(.noData); return }
        let boundary = store.boundaryToken
        Task {
            await store.refresh()
            guard store.isCurrent(boundary) else { completionHandler(.noData); return }
            if application.applicationState == .background { store.suspend() }
            completionHandler(.newData)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        let sessionID = info["session_id"] as? String
        let workspaceID = info["workspace_id"] as? String
        let groupID = info["group_id"] as? String
        let taskID = info["task_id"] as? String
        return await foregroundPresentation(taskID: taskID, sessionID: sessionID, workspaceID: workspaceID, groupID: groupID)
    }

    private func foregroundPresentation(taskID: String?, sessionID: String?, workspaceID: String?, groupID: String?) async -> UNNotificationPresentationOptions {
        guard !authenticationSuspended, let store, let fence = NotificationNavigationFence(store: store),
              let notifications = store.taskNotifications else { return [] }
        let client = store.client
        let allowed = await notifications.authorizeForegroundAlert(taskID: taskID, sessionID: sessionID,
            workspaceID: workspaceID, groupID: groupID, check: { target in
                // Existing authenticated Comma access checks reject deleted/revoked tasks.
                // The SDK's finite request/resource budgets also bound this lookup.
                try await client.conversation(target: target, messageLimit: 1).isTask
            })
        guard allowed, !authenticationSuspended, fence.matches(store: store) else { return [] }
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        // Only routing identifiers are read here, never a title/body or private task data.
        let info = response.notification.request.content.userInfo
        let taskID = info["task_id"] as? String
        let workspaceID = info["workspace_id"] as? String
        let sessionID = info["session_id"] as? String
        await receiveTap(id: taskID, workspaceID: workspaceID, sessionID: sessionID)
    }

    private func receiveTap(id: String?, workspaceID: String?, sessionID: String?) async {
        guard !authenticationSuspended, let id, let workspaceID, let store else { return }
        if let sessionID, retiredSessionIDs.contains(sessionID) { return }
        if let session = store.session, let sessionID, session.id != sessionID { return }
        guard store.session != nil, !store.workspaces.isEmpty else {
            pendingTask = (id, workspaceID, store.boundaryToken, store.session?.user.id)
            return
        }
        guard let fence = NotificationNavigationFence(store: store) else { return }
        await openTask(id: id, workspaceID: workspaceID, fence: fence)
    }

    private func openTask(id: String?, workspaceID: String?, fence: NotificationNavigationFence) async {
        guard !authenticationSuspended, let id, let workspaceID, let store, fence.matches(store: store),
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return }
        if store.workspace?.id != workspace.id { await store.chooseWorkspace(workspace) }
        guard !authenticationSuspended, fence.matches(store: store), store.workspace?.id == workspace.id else { return }
        // CommaClient and ConversationPane perform authenticated task/group access checks.
        await store.openTask(id: id)
        guard !authenticationSuspended, fence.matches(store: store) else { return }
    }
}

/// Captured before creating a navigation Task, not when that Task eventually runs.
/// A signed-out route gets a new fence only when intentionally resumed after login.
@MainActor struct NotificationNavigationFence {
    let boundary: Int
    let sessionID: String
    let accountID: String
    init?(store: CommaStore) {
        guard let session = store.session else { return nil }
        self.init(boundary: store.boundaryToken, sessionID: session.id, accountID: session.user.id)
    }
    init(boundary: Int, sessionID: String, accountID: String) {
        self.boundary = boundary; self.sessionID = sessionID; self.accountID = accountID
    }
    func matches(store: CommaStore) -> Bool {
        matches(boundary: store.boundaryToken, sessionID: store.session?.id, accountID: store.session?.user.id)
    }
    func matches(boundary: Int, sessionID: String?, accountID: String?) -> Bool {
        self.boundary == boundary && self.sessionID == sessionID && self.accountID == accountID
    }
}
