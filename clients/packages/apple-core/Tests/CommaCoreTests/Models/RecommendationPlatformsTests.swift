import Foundation
import Testing
@testable import CommaCore

@Suite("Recommendation platforms")
struct RecommendationPlatformsTests {
    private static let json = #"""
    {"state":"fresh","settings":{"sources":[
        {"appId":"slack","appName":"Slack","connectionId":"conn-sl","enabled":true,"kind":"composio","label":"acme"},
        {"appId":"github","appName":"GitHub","connectionId":"conn-gh1","enabled":true,"kind":"managed_oauth","label":"zan"},
        {"appId":"github","appName":"GitHub","connectionId":"conn-gh2","enabled":true,"kind":"managed_oauth","label":"acme-org"},
        {"appId":"linear","appName":"Linear","connectionId":"conn-li","enabled":false,"kind":"composio","label":"acme"},
        {"appId":"notion","appName":"Notion","connectionId":"conn-no","enabled":true,"kind":"native_mcp_oauth","label":""}]},
     "snapshot":{"generatedAt":1700000000000,"generation":4,
      "cards":[
        {"id":"c-gh","title":"Reviews","template":"text-list@1","sourceIds":["conn-gh2"],"items":[
          {"id":"i1","parts":[{"kind":"markdown","text":"PR 1 is waiting"}],"action":{"type":"open_task_form","label":"Ask","prompt":"Review PR 1"}},
          {"id":"i2","parts":[{"kind":"inline-task","task":{"conversationId":"t-open","label":"Fix CI"}}],"action":{"type":"open_url","href":"https://ci.example/1","label":"Open"}},
          {"id":"i3","parts":[{"kind":"inline-task","task":{"conversationId":"t-done","label":"Ship"}}],"action":{"type":"open_url","href":"https://ci.example/2","label":"Open"}},
          {"id":"i4","parts":[{"kind":"inline-task","task":{"conversationId":"t-unknown","label":"Old"}}],"action":{"type":"open_url","href":"https://ci.example/3","label":"Open"}}]},
        {"id":"c-sl","title":"Messages","template":"text-list@1","sourceIds":["conn-sl"],"items":[
          {"id":"i5","parts":[{"kind":"markdown","text":"Ada asked about the launch"}],"action":{"type":"send_to_comma","label":"Ask","prompt":"Reply to Ada"}}]},
        {"id":"c-sl-2","title":"Threads","template":"future@9","sourceIds":["conn-sl"],"fallbackText":"Two threads"},
        {"id":"c-mix","title":"Today","template":"text-list@1","sourceIds":["conn-sl","conn-li"],"items":[
          {"id":"i6","parts":[{"kind":"markdown","text":"Plan the week"}],"action":{"type":"open_task_form","label":"Ask","prompt":"Plan"}}]}]}}
    """#

    private func feed() throws -> RecommendationFeed {
        try RecommendationFeed(envelope: JSONDecoder().decode(JSONValue.self, from: Data(Self.json.utf8)))
    }

    @Test func cardsLeadInServerOrderThenEnabledSourcesWithoutACard() throws {
        let platforms = try feed().platforms
        #expect(platforms.map(\.id) == ["conn-gh2", "conn-sl", "c-sl-2", "c-mix", "conn-gh1", "conn-no"])
        #expect(platforms.map(\.name) == ["GitHub", "Slack", "Slack", "Today", "GitHub", "Notion"])
        // The disabled Linear source has no card of its own and is named by the mixed card, so it never shows.
        #expect(!platforms.contains { $0.source?.appID == "linear" })
        #expect(platforms[3].source == nil && platforms[3].card?.id == "c-mix")
        #expect(platforms[4].card == nil && platforms[5].card == nil)
    }

    @Test func aRepeatedNameShowsTheConnectionLabel() throws {
        let platforms = try feed().platforms
        #expect(platforms[0].connectionLabel == "acme-org")
        #expect(platforms[4].connectionLabel == "zan")
        #expect(platforms[1].connectionLabel == "acme" && platforms[2].connectionLabel == "acme")
        #expect(platforms[3].connectionLabel == nil && platforms[5].connectionLabel == nil)
        #expect(try feed().sources.first { $0.appID == "notion" }?.label == nil)
        #expect(try feed().sources.first?.kind == "composio")
    }

    @Test func preTasksHideRowsWhoseTaskHasEndedOrIsUnknown() throws {
        let github = try feed().platforms[0]
        let tasks = ["t-open": task("t-open", status: "in_progress"), "t-done": task("t-done", status: "ready_for_review")]
        let visible = github.preTasks { PlatformRoutine.isOpen(tasks[$0]) }
        #expect(visible.map(\.id) == ["i1", "i2"])
        #expect(github.preTasks { _ in true }.count == 4)
        #expect(try feed().platforms[4].preTasks { _ in true }.isEmpty)
    }

    @Test func endedAndArchivedTasksAreNotOpen() {
        #expect(PlatformRoutine.isOpen(task("a", status: "in_progress")))
        #expect(PlatformRoutine.isOpen(task("a", status: "active")))
        for status in ["completed", "cancelled", "archived", "ready_for_review"] {
            #expect(!PlatformRoutine.isOpen(task("a", status: status)))
        }
        #expect(!PlatformRoutine.isOpen(task("a", status: "in_progress", archivedAt: 1)))
        #expect(!PlatformRoutine.isOpen(nil))
    }

    private func task(_ id: String, status: String, archivedAt: Double? = nil) -> Conversation {
        Conversation(id: id, groupID: "g", title: id, status: status, kind: "agent_task", archivedAt: archivedAt)
    }
}
