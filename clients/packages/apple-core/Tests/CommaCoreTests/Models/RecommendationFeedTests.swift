import Foundation
import Testing
@testable import CommaCore

@Suite("Recommendation feed decoding")
struct RecommendationFeedTests {
    @Test func promptReferencesResolveAndSourcesNameCardLogos() throws {
        let json = #"""
        {"state":"fresh","settings":{"sources":[
            {"appId":"github","appName":"GitHub","connectionId":"conn-gh","enabled":true,"kind":"composio","label":"acme"},
            {"appId":"slack","appName":"Slack","connectionId":"conn-sl","enabled":true,"kind":"composio","label":"acme","needsReconnect":true}]},
         "snapshot":{"generatedAt":1700000000000,"generation":4,"protocolVersion":1,"sourceRevision":1,"templateCatalogVersion":1,"warnings":[],
          "summary":[{"kind":"markdown","text":"Two things need you. "},{"kind":"inline-task","task":{"conversationId":"t1","label":"Fix CI"}}],
          "prompts":{"p1":{"sourceId":"conn-gh","sourceUrl":"https://github.com/o/r/pull/1","objective":"Review PR 1","context":"…","contextLabel":"PR"}},
          "cards":[
            {"id":"c1","title":"Reviews","template":"text-list@1","sourceIds":["conn-gh"],"fallbackText":"x","items":[
              {"id":"i1","parts":[{"kind":"markdown","text":"PR 1 is waiting"}],"action":{"type":"send_to_comma","label":"Ask Comma","promptId":"p1","requiresConfirmation":true}},
              {"id":"i2","parts":[{"kind":"inline-task","task":{"conversationId":"t9","label":"Reply to Ada"}}],"action":{"type":"open_url","href":"https://mail.example/1","label":"Open","requiresConfirmation":false}}]},
            {"id":"c2","title":"Later","template":"future@9","sourceIds":["conn-gh","conn-sl"],"fallbackText":"Plain text"}]}}
        """#
        let feed = try RecommendationFeed(envelope: JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        #expect(feed.summaryText == "Two things need you. Fix CI")
        #expect(feed.generation == 4 && feed.canRefresh)
        #expect(feed.sourcesNeedingReconnect.map(\.appName) == ["Slack"])
        #expect(feed.source(for: feed.cards[0])?.appID == "github")
        #expect(feed.source(for: feed.cards[1]) == nil)
        #expect(feed.cards[0].items[0].action == .prompt("Review PR 1\n\nhttps://github.com/o/r/pull/1", label: "Ask Comma", memberTask: true))
        #expect(feed.cards[0].items[1].linkedTaskID == "t9")
        #expect(feed.cards[1].items.isEmpty && feed.cards[1].fallbackText == "Plain text")
        #expect(RecommendationSource.brandKey("Google Calendar") == "googlecalendar")
    }

    @Test func memberTaskRowCarriesItsTaskAndQuotedSource() throws {
        // As the client core publishes it: a member row's link carries its objective and the source words it quotes, read.
        let json = #"""
        {"state":"fresh","settings":{"sources":[
            {"appId":"slack","appName":"Slack","connectionId":"conn-sl","enabled":true,"kind":"composio","label":"acme"}]},
         "snapshot":{"generatedAt":1700000000000,"generation":2,"protocolVersion":1,"sourceRevision":1,"templateCatalogVersion":1,"warnings":[],
          "summary":[{"kind":"markdown","text":"One thing needs you."}],
          "cards":[
            {"id":"slack","title":"Slack","template":"text-list@1","sourceIds":["conn-sl"],"fallbackText":"Slack","items":[
              {"id":"i1","parts":[{"kind":"inline-link","link":{"href":"https://acme.slack.com/archives/C1/p1","label":"PR 3986","sourceId":"conn-sl",
                "objective":"Decide whether to merge PR 3986","previewText":"Ember: <@U1|zanwei> CI is green.\n• Retry",
                "quote":[{"runs":[{"kind":"text","text":"Ember: "},{"kind":"mention","text":"@zanwei","href":"https://acme.slack.com/team/U1"},{"kind":"text","text":" CI is green."}]},
                  {"listItem":true,"runs":[{"kind":"text","text":"Retry"}]}],
                "taskPrompt":"Decide whether to merge PR 3986\n\nhttps://acme.slack.com/archives/C1/p1"}}],
               "action":{"type":"send_to_comma","label":"Decide","memberTask":true,"prompt":"Decide whether to merge PR 3986\n\nhttps://acme.slack.com/archives/C1/p1","requiresConfirmation":true}},
              {"id":"i2","parts":[{"kind":"markdown","text":"Reply to "},{"kind":"inline-link","link":{"href":"https://acme.slack.com/archives/C1/p2","label":"Ada","sourceId":"conn-sl","previewText":"Ada: is it final?","quote":[{"runs":[{"kind":"text","text":"Ada: is it final?"}]}]}}],
               "action":{"type":"send_to_comma","label":"Reply","prompt":"Reply to Ada","requiresConfirmation":true}}]}]}}
        """#
        let feed = try RecommendationFeed(envelope: JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        let row = feed.cards[0].items[0]
        #expect(row.objective == "Decide whether to merge PR 3986")
        #expect(row.quote == RecommendationQuote(lines: [
            .init(runs: [.init(text: "Ember: ", kind: .text), .init(text: "@zanwei", kind: .mention), .init(text: " CI is green.", kind: .text)]),
            .init(runs: [.init(text: "Retry", kind: .text)], listItem: true),
        ]))
        #expect(row.quote?.plainText == "Ember: @zanwei CI is green.\n• Retry")
        // A row with prose around its link is not a member task row: it shows its prose and quotes nothing.
        #expect(feed.cards[0].items[1].objective == nil && feed.cards[0].items[1].quote == nil)
    }

    @Test func summaryBodyLeavesOutTheBriefingTitle() {
        let titled = RecommendationFeed(state: "fresh", summary: [
            .text("Your work briefing\n\nHere is what I suggest you focus on: "),
            .task(label: "Fix CI", conversationID: "t1", sourceID: nil)])
        #expect(titled.summaryBody == [.text("Here is what I suggest you focus on: "),
                                       .task(label: "Fix CI", conversationID: "t1", sourceID: nil)])
        let titleOnly = RecommendationFeed(state: "fresh", summary: [
            .text("你的工作简报\n\n"), .task(label: "Fix CI", conversationID: "t1", sourceID: nil)])
        #expect(titleOnly.summaryBody == [.task(label: "Fix CI", conversationID: "t1", sourceID: nil)])
        let untitled = RecommendationFeed(state: "fresh", summary: [.text("Two things need you.")])
        #expect(untitled.summaryBody == untitled.summary)
    }

    @Test func emptyEnvelopeHasNoCards() throws {
        let feed = try RecommendationFeed(envelope: .object(["state": .string("empty"), "snapshot": .null]))
        #expect(feed.cards.isEmpty && !feed.hasSnapshot && !feed.canRefresh)
    }
}
