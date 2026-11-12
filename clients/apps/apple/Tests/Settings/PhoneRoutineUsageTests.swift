import XCTest
import CommaCore
@testable import Comma

@MainActor final class PhoneRoutineUsageTests: XCTestCase {
    func testRoutineChangesOnlyWriteTheSelectedSettingAndRejectRetiredPages() async throws {
        let harness = try StoreHarness(); PhoneRoutineUsageFixtures.configure(harness.core); await harness.start()
        let model = PhoneRoutinesSettingsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        let following = Task { await model.follow() }; defer { following.cancel() }
        try await ready { model.loaded }
        await model.setSource(try XCTUnwrap(model.sources.first), enabled: false)
        let patch = try XCTUnwrap(harness.core.calls("recommendations.updateSettings").first?["patch"] as? [String: Any])
        XCTAssertEqual(patch.count, 1)
        XCTAssertEqual((patch["sources"] as? [[String: Any]])?.first?["connectionId"] as? String, "github-1")
        XCTAssertEqual((patch["sources"] as? [[String: Any]])?.first?["enabled"] as? Bool, false)
        await model.setSchedule(enabled: false)
        let schedulePatch = try XCTUnwrap(harness.core.calls("recommendations.updateSettings").last?["patch"] as? [String: Any])
        XCTAssertNil(schedulePatch["sources"])
        XCTAssertEqual((schedulePatch["schedule"] as? [String: Any])?["minute"] as? Int, 30)
        harness.core.on("chat.resolveWorkspaceChat") { _ in ["status": "ready", "workspaceId": "w2", "groupId": "g2", "conversationId": "other"] }
        await harness.store.chooseWorkspace(.init(id: "w2", groupID: "g2", name: "Other"))
        await model.save(["autoEnableNewSources": false])
        XCTAssertEqual(harness.core.calls("recommendations.updateSettings").count, 2)
    }

    func testProactiveOwnerRefusalAndSaveFailureKeepTheVisibleSettings() async throws {
        let harness = try StoreHarness(); PhoneRoutineUsageFixtures.configure(harness.core); await harness.start()
        harness.core.serve("proactive") { _ in ["kind": "owner-only"] }
        let model = PhoneRoutinesSettingsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        let sources = Task { await model.follow() }; let proactive = Task { await model.followProactive() }
        defer { sources.cancel(); proactive.cancel() }
        try await ready { model.loaded && model.proactive.object?.string("kind") == "owner-only" }
        await model.setProactive(false)
        XCTAssertTrue(harness.core.calls("proactive.set").isEmpty)
        harness.core.on("recommendations.updateSettings") { _ in throw CoreError(code: "unavailable", message: "Try again") }
        await model.setSchedule(enabled: false)
        XCTAssertTrue(model.enabled)
        XCTAssertNotNil(model.scope.error)
    }

    func testSuggestionSendsOnlyItsPromptAndPreservesDraftAndRoutineTiles() async throws {
        let harness = try StoreHarness(); PhoneRoutineUsageFixtures.configure(harness.core); await harness.start()
        let pane = try XCTUnwrap(harness.store.router.pane)
        pane.open(); defer { pane.close() }
        try await ready { pane.state.loaded }
        XCTAssertTrue(harness.core.topics("chatSuggestions").isEmpty, "A chat kept off screen must not generate suggestions")
        pane.setSuggestionsVisible(true)
        try await ready { !pane.suggestions.isEmpty }
        pane.draftText = "Keep my draft"
        pane.attachText(ChatAttachedText(source: "Linear", text: "My staged task"))
        XCTAssertFalse(pane.acceptSuggestion())
        let attempt = try XCTUnwrap(pane.enqueueSuggestion(pane.suggestions[0]))
        await pane.deliver(attempt)
        let call = try XCTUnwrap(harness.core.calls("chatView.send").first)
        XCTAssertEqual(call["consumeDraft"] as? Bool, false)
        XCTAssertEqual(call["text"] as? String, "整理下一步")
        XCTAssertNil(call["attachedTexts"])
        XCTAssertEqual(pane.draftText, "Keep my draft")
        XCTAssertEqual(pane.draftTexts.count, 1)
        XCTAssertTrue(pane.suggestions.isEmpty)
    }

    func testSuggestionsFollowTheSettledTurnLocaleAndForegroundAndTabNeverSends() async throws {
        let harness = try StoreHarness(); PhoneRoutineUsageFixtures.configure(harness.core); await harness.start()
        let pane = try XCTUnwrap(harness.store.router.pane)
        pane.open(); pane.setSuggestionsVisible(true); defer { pane.close() }
        try await ready { pane.suggestions.count == 4 }
        pane.setSuggestionLocale("zh-Hans_SG")
        try await ready { harness.core.topics("chatSuggestions").first?["locale"] as? String == "zh-CN" && !pane.suggestions.isEmpty }
        pane.setForeground(false)
        XCTAssertTrue(pane.suggestions.isEmpty)
        pane.setForeground(true)
        try await ready { !pane.suggestions.isEmpty }
        XCTAssertTrue(pane.acceptSuggestion())
        XCTAssertEqual(pane.draftText, "整理下一步")
        XCTAssertTrue(harness.core.calls("chatView.send").isEmpty)
        harness.core.publish("chatView", PhoneRoutineUsageFixtures.chat(busy: true))
        try await ready { pane.state.reply.pending }
        XCTAssertTrue(pane.suggestions.isEmpty)
        harness.core.publish("chatView", PhoneRoutineUsageFixtures.chat("answer-2"))
        try await ready { !pane.suggestions.isEmpty }
        XCTAssertEqual(pane.draftText, "整理下一步")
    }

    func testUsageRejectsAnotherWorkspaceAndDoesNotInventUnknownCycleUsage() async throws {
        let harness = try StoreHarness(); PhoneRoutineUsageFixtures.configure(harness.core); await harness.start()
        let model = PhoneUsageModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        let following = Task { await model.follow() }; defer { following.cancel() }
        try await ready { model.status == "ready" }
        XCTAssertEqual(model.credits, 12_500_000)
        XCTAssertNotNil(model.resetsAt)
        var unknown = PhoneRoutineUsageFixtures.billing
        unknown["planUsage"] = NSNull()
        harness.core.publish("billing", unknown)
        try await ready { model.usage == nil }
        unknown["workspace"] = ["id": "w2", "name": "Other"]
        harness.core.publish("billing", unknown)
        try await ready { model.status == "unavailable" }
        XCTAssertNil(model.summary)
        await model.refresh()
        XCTAssertEqual(harness.core.calls("billing.refresh").first?["workspace"] as? String, "w1")
        XCTAssertTrue(harness.core.calls("billing.checkout").isEmpty)
    }

    private func ready(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
}
