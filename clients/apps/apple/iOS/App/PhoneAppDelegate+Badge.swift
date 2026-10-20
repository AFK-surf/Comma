import Foundation
import CommaCore

// App icon badge: the serial Router-unread sync and its bounded 503 retry.
extension PhoneAppDelegate {
    func settleBadge() async {
        await store?.router.settleScrollNotice()
        while let worker = badgeWorker { await worker.value }
    }

    /// The serial worker reads the current scope each time. A stale response never writes a badge
    /// or acknowledges a Message after the router chat's visibility, account or Workspace changed.
    func synchronizeBadge() {
        badgeRevision += 1
        guard badgeWorker == nil else { return }
        badgeWorker = Task { [weak self] in
            guard let self else { return }
            var revision: Int
            repeat {
                revision = self.badgeRevision
                await self.updateBadge(revision: revision)
            } while revision != self.badgeRevision
            self.badgeWorker = nil
        }
    }

    private func updateBadge(revision: Int) async {
        if authenticationSuspended || store?.session == nil { await setBadge(0); return }
        guard sceneActive, !authenticationSuspended, let store, let workspace = store.workspace,
              let fence = NotificationNavigationFence(store: store) else { return }
        do {
            var snapshot = try await store.routerUnread(group: workspace.groupID)
            guard revision == badgeRevision, sceneActive, !authenticationSuspended,
                  fence.matches(store: store), store.workspace?.id == workspace.id else { return }
            if store.router.isVisible, store.router.pane?.conversationID == snapshot.conversationID,
               let messageID = store.router.displayedReplyID, messageID != acknowledgedMessageID {
                snapshot = try await store.readRouter(group: workspace.groupID, messageID: messageID)
                guard revision == badgeRevision, sceneActive, !authenticationSuspended,
                      fence.matches(store: store), store.workspace?.id == workspace.id else { return }
                acknowledgedMessageID = messageID
            }
            store.router.reportUnread(snapshot.unreadCount)
            let badgeAllowed = await badgePermission()
            guard revision == badgeRevision, sceneActive, fence.matches(store: store), store.workspace?.id == workspace.id else { return }
            await setBadge(badgeAllowed && store.taskNotifications?.intent == true ? snapshot.unreadCount : 0)
            badgeRetryCount = 0
        } catch let error as CoreError where error.status == 503 {
            // The server is still projecting Router replies. Retry a few times while this
            // scope stays current instead of waiting for the next visibility change.
            scheduleBadgeRetry(after: 1, revision: revision)
        } catch { /* Keep the last acknowledged badge and retry on visibility/foreground. */ }
    }

    private func scheduleBadgeRetry(after seconds: Double, revision: Int) {
        guard badgeRetryCount < 5 else { return }
        badgeRetryCount += 1
        // The newest failed revision owns the retry; an older pending one would fail its fence.
        badgeRetry?.cancel()
        badgeRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(max(seconds, 1), 10)))
            guard let self, !Task.isCancelled else { return }
            self.badgeRetry = nil
            guard revision == self.badgeRevision, self.sceneActive else { return }
            self.synchronizeBadge()
        }
    }
}
