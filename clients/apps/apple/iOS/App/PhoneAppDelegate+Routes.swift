import UIKit
import UserNotifications
import CommaCore

// Notification scope, APNs callbacks, and tap routing that defers until a scene and Workspace are ready.
extension PhoneAppDelegate {
    func authenticationBoundaryChanged() {
        authenticationSuspended = true
        if store?.session != nil { pendingRoute = nil }
        store?.taskNotifications?.suspendIdentity()
        acknowledgedMessageID = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        synchronizeBadge()
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
            pendingRoute = nil
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        } else if let route = pendingRoute, route.accountID != nil && route.accountID != session?.user.id {
            pendingRoute = nil
        }
        lastAccountID = session?.user.id
        synchronize()
        synchronizeBadge()
    }

    func workspaceChanged() {
        guard !authenticationSuspended else { return }
        acknowledgedMessageID = nil
        synchronize()
        synchronizeBadge()
        if sceneActive, let pending = pendingRoute, let store, store.session != nil, !store.workspaces.isEmpty {
            pendingRoute = nil
            guard pending.accountID == nil || (pending.accountID == store.session?.user.id && pending.boundary == store.boundaryToken),
                  let fence = NotificationNavigationFence(store: store) else { return }
            Task { await open(pending.route, fence: fence) }
        }
    }

    func synchronize() {
        guard sceneActive, !authenticationSuspended, let store, let notifications = store.taskNotifications else { return }
        let session = store.session
        notifications.setContext(sessionID: session?.id, accountID: session?.user.id, workspace: store.workspace)
        guard let session else { return }
        let boundary = store.boundaryToken
        Task {
            guard let channel = try? store.deviceNotificationChannel(),
                  store.isCurrent(boundary), !self.authenticationSuspended,
                  store.session?.id == session.id, store.session?.user.id == session.user.id else { return }
            notifications.attach(channel)
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        system.received(token)
        store?.reportPushRegistration(nil)
        store?.taskNotifications?.tokenChanged()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        system.failed()
        store?.reportPushRegistration(error.localizedDescription)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            await bootstrap()
            guard let store, store.session != nil else { completionHandler(.noData); return }
            let boundary = store.boundaryToken
            if application.applicationState == .active { await store.refresh() }
            else {
                scheduleActivityConfiguration(store)
                await activityConfigurationTask?.value
                await activity.settleRegistrations()
            }
            guard store.isCurrent(boundary) else { completionHandler(.noData); return }
            if application.applicationState == .background { store.suspend() }
            completionHandler(.newData)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let route = NativeNotificationRoute(notification.request.content.userInfo) else { return [] }
        return await foregroundPresentation(route)
    }

    func foregroundPresentation(_ route: NativeNotificationRoute) async -> UNNotificationPresentationOptions {
        guard sceneActive, !authenticationSuspended, let store, let fence = NotificationNavigationFence(store: store),
              let notifications = store.taskNotifications,
              notifications.allowsForegroundAlert(sessionID: route.sessionID, workspaceID: route.workspaceID, groupID: route.groupID) else { return [] }
        let allowed: Bool
        do {
            switch route.destination {
            case .task(let taskID):
                allowed = try await store.isTask(taskID, group: route.groupID)
            case .router(let conversationID, _):
                allowed = try await store.routerUnread(group: route.groupID).conversationID == conversationID
            }
        } catch { return [] }
        guard allowed, sceneActive, !authenticationSuspended, fence.matches(store: store),
              notifications.allowsForegroundAlert(sessionID: route.sessionID, workspaceID: route.workspaceID, groupID: route.groupID) else { return [] }
        if case .router = route.destination {
            synchronizeBadge()
            if store.router.isVisible, store.router.pane?.conversationID == route.destination.conversationID {
                store.router.pane?.refresh()
                guard fence.matches(store: store), sceneActive else { return [] }
                // The viewport callback acknowledges only the committed Message actually shown.
                synchronizeBadge()
                return []
            }
        }
        return [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let route = NativeNotificationRoute(response.notification.request.content.userInfo) else { return }
        await receiveTap(route)
    }

    func receiveTap(_ route: NativeNotificationRoute) async {
        guard !authenticationSuspended, let store, !retiredSessionIDs.contains(route.sessionID) else { return }
        if let session = store.session, session.id != route.sessionID { return }
        guard sceneActive, store.session != nil, !store.workspaces.isEmpty else {
            pendingRoute = (route, store.boundaryToken, store.session?.user.id)
            return
        }
        guard let fence = NotificationNavigationFence(store: store) else { return }
        await open(route, fence: fence)
    }

    private func open(_ route: NativeNotificationRoute, fence: NotificationNavigationFence) async {
        guard !authenticationSuspended, let store, fence.matches(store: store), store.session?.id == route.sessionID,
              let workspace = store.workspaces.first(where: { $0.id == route.workspaceID && $0.groupID == route.groupID }) else { return }
        guard sceneActive else { deferRoute(route, fence: fence); store.suspend(); return }
        if store.workspace?.id != workspace.id { await store.chooseWorkspace(workspace) }
        guard !authenticationSuspended, fence.matches(store: store), store.workspace?.id == workspace.id else { return }
        guard sceneActive else { deferRoute(route, fence: fence); store.suspend(); return }
        switch route.destination {
        case .task(let id):
            await store.openTask(id: id)
            guard sceneActive else { deferRoute(route, fence: fence); store.suspend(); return }
        case .router(let conversationID, _):
            guard let snapshot = try? await store.routerUnread(group: workspace.groupID),
                  !authenticationSuspended, fence.matches(store: store), snapshot.conversationID == conversationID else { return }
            guard sceneActive else { deferRoute(route, fence: fence); store.suspend(); return }
            store.revealRouter()
            await store.openRouter()
            guard sceneActive else { deferRoute(route, fence: fence); store.suspend(); return }
            store.router.pane?.refresh()
            guard sceneActive else { deferRoute(route, fence: fence); store.suspend(); return }
            synchronizeBadge()
        }
    }

    private func deferRoute(_ route: NativeNotificationRoute, fence: NotificationNavigationFence) {
        guard !authenticationSuspended, let store, fence.matches(store: store) else { return }
        pendingRoute = (route, store.boundaryToken, store.session?.user.id)
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

/// APNs payloads carry routing correlation only. Every presentation/navigation rechecks authority.
struct NativeNotificationRoute: Sendable, Equatable {
    enum Destination: Sendable, Equatable {
        case task(String)
        case router(conversationID: String, messageID: String)
        var conversationID: String { switch self { case .task(let id): id; case .router(let id, _): id } }
    }
    let sessionID: String
    let workspaceID: String
    let groupID: String
    let destination: Destination
    init?(_ info: [AnyHashable: Any]) {
        func identifier(_ key: String) -> String? {
            guard let value = info[key] as? String, !value.isEmpty, value.utf8.count <= 256 else { return nil }
            return value
        }
        guard let sessionID = identifier("session_id"), let workspaceID = identifier("workspace_id"),
              let groupID = identifier("group_id") else { return nil }
        if info["type"] as? String == "router_message" {
            guard let conversationID = identifier("conversation_id"), let messageID = identifier("message_id") else { return nil }
            destination = .router(conversationID: conversationID, messageID: messageID)
        } else {
            guard let taskID = identifier("task_id") else { return nil }
            destination = .task(taskID)
        }
        self.sessionID = sessionID; self.workspaceID = workspaceID; self.groupID = groupID
    }
}
