import Foundation
import Testing
@testable import CommaCore

extension TaskNotificationControllerTests {
    @Test func failedPreferenceWriteRetainsDisableOperationForRetry() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        h.preferences.fail = true
        h.controller.intent = false
        #expect(h.controller.status == .disableFailed)
        #expect(h.controller.record?.retirementRequested == true)
        #expect(h.controller.intent)
        h.preferences.fail = false
        h.controller.retry(); await h.controller.settle()
        #expect(h.controller.status == .off)
        #expect(await h.mutations.events.filter { $0.hasPrefix("post:") }.count == 1)
    }

    @Test func dedicatedPreferenceFileSeparatesAccountsAndRestoresAcknowledgedSessionScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notifications.json")
        let first = FileTaskNotificationPreferences(url: url)
        let on = TaskNotificationRecord(intent: true, retirementRequested: true, registrationID: "r1", workspaceID: "w1", groupID: "g1", registrationSessionID: "s1")
        try first.save(on, key: "origin|phone|a1")
        try first.save(TaskNotificationRecord(intent: false), key: "origin|phone|a2")
        let restored = FileTaskNotificationPreferences(url: url)
        #expect(try restored.load(key: "origin|phone|a1") == on)
        #expect(try restored.load(key: "origin|phone|a2")?.intent == false)
        #expect(try restored.load(key: "another-origin|phone|a1") == nil)
        try restored.remove(key: "origin|phone|a1")
        #expect(try restored.load(key: "origin|phone|a2")?.intent == false)
    }

    @Test func pendingDisableKeepsConfirmedOnUntilDeletionAcknowledges() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        await h.mutations.pause("delete:s1")
        h.controller.intent = false
        await h.mutations.waitForPause()
        #expect(h.controller.status == .disabling)
        #expect(h.controller.intent, "A pending DELETE must not expose confirmed OFF")
        #expect(!h.controller.canToggle)
        #expect(!h.controller.canPresent)
        await h.mutations.release(); await h.controller.settle()
        #expect(!h.controller.intent)
        #expect(h.controller.status == .off)
    }
}
