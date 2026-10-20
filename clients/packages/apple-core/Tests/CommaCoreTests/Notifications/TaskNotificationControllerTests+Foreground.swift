import Foundation
import Testing
@testable import CommaCore

extension TaskNotificationControllerTests {
    @Test func foregroundAlertRequiresMatchingAcknowledgedSessionAndSupportedScope() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        #expect(h.controller.allowsForegroundAlert(sessionID: "s1", workspaceID: "w1", groupID: "g1"))
        #expect(!h.controller.allowsForegroundAlert(sessionID: nil, workspaceID: "w1", groupID: "g1"))
        #expect(!h.controller.allowsForegroundAlert(sessionID: "s2", workspaceID: "w1", groupID: "g1"))
        #expect(!h.controller.allowsForegroundAlert(sessionID: "s1", workspaceID: "w2", groupID: "g1"))
        #expect(!h.controller.allowsForegroundAlert(sessionID: "s1", workspaceID: "w1", groupID: "other-group"))
        h.system.current = .init(authorization: .denied)
        h.controller.refresh(); await h.controller.settle()
        #expect(!h.controller.allowsForegroundAlert(sessionID: "s1", workspaceID: "w1", groupID: "g1"))
    }

    @Test func foregroundMissingOrUnauthorizedTaskNeverPresents() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        let missing = await h.controller.authorizeForegroundAlert(taskID: nil, sessionID: "s1", workspaceID: "w1", groupID: "g1", check: { _ in
            Issue.record("Missing task IDs must not start a private read"); return true
        })
        #expect(!missing)
        let denied = await h.controller.authorizeForegroundAlert(taskID: "task", sessionID: "s1", workspaceID: "w1", groupID: "g1", check: { _ in
            throw CommaError.http(status: 403, code: "forbidden", retryAfter: nil)
        })
        #expect(!denied)
        let accessible = await h.controller.authorizeForegroundAlert(taskID: "task", sessionID: "s1", workspaceID: "w1", groupID: "g1", check: { target in
            target.groupID == "g1" && target.workspaceID == "w1" && target.conversationID == "task"
        })
        #expect(accessible)
    }

    @Test func foregroundRechecksAuthAndScopeAfterAwaitedTaskAccess() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        await h.mutations.pause("read:task")
        let mutations = h.mutations
        let checking = Task {
            await h.controller.authorizeForegroundAlert(taskID: "task", sessionID: "s1", workspaceID: "w1", groupID: "g1", check: { _ in
                try await mutations.perform("read:task"); return true
            })
        }
        await h.mutations.waitForPause()
        h.controller.suspendIdentity()
        await h.mutations.release()
        #expect(await checking.value == false)
        await h.controller.settle()
    }
}
