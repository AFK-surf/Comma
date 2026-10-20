import Foundation
import Testing
@testable import CommaCore

@Suite("Worker history projection")
struct WorkerHistoryProjectionTests {
    @Test func toolResultsJoinTheirCallOnlyByCallID() throws {
        let records: [WorkerHistoryRecord] = try JSONDecoder().decode([WorkerHistoryRecord].self, from: Data(#"""
        [
          {"id":"1","kind":"user","content":"Find the report","input_text":"Find the report"},
          {"id":"2","kind":"assistant","content":{"content":"","tool_calls":[
            {"id":"c1","function":{"name":"env.exec","arguments":"{\"command\":\"ls\",\"description\":\"List files\"}"}},
            {"id":"c2","name":"web.search","args":{"query":"report"}}]}},
          {"id":"3","kind":"tool","content":{"tool_call_id":"c1","status":"completed","output":"report.pdf"}},
          {"id":"4","kind":"tool","content":{"tool_call_id":"c2","is_error":true,"error_message":"Rate limited"}},
          {"id":"5","kind":"tool","content":{"tool_call_id":"c1","status":"running","progress":"late receipt"}},
          {"id":"6","kind":"system","content":"Inbound message source: telegram"},
          {"id":"7","kind":"assistant","content":{"content":"Found report.pdf"}}
        ]
        """#.utf8))
        let items = WorkerHistory.items(records)
        #expect(items.map(\.kind) == [.input, .call, .model])
        let calls = items[1].calls
        #expect(calls.map(\.kind) == [.success, .failure])
        #expect(calls[0].tool == "env.exec" && calls[0].summary == "List files" && calls[0].command == "ls")
        #expect(calls[0].outcome == "report.pdf")
        #expect(calls[1].tool == "web.search" && calls[1].summary == "report" && calls[1].outcome == "Rate limited")
        #expect(items[2].summary == "Found report.pdf")
    }

    @Test func toolCallsShowUnderTheThinkingThatStartedThem() throws {
        let records: [WorkerHistoryRecord] = try JSONDecoder().decode([WorkerHistoryRecord].self, from: Data(#"""
        [
          {"id":"1","kind":"assistant","content":{"reasoning":"Read the sheet first."}},
          {"id":"2","kind":"assistant","content":{"tool_calls":[{"id":"c1","name":"env.exec","args":{"command":"cat a.csv"}}]}},
          {"id":"3","kind":"tool","content":{"tool_call_id":"c1","status":"completed"}},
          {"id":"4","kind":"assistant","content":{"reasoning":"Then the mapping.","tool_calls":[
            {"id":"c2","name":"env.exec","args":{"command":"cat b.csv"}}]}},
          {"id":"5","kind":"tool","content":{"tool_call_id":"c9","status":"completed","output":"orphan"}}
        ]
        """#.utf8))
        let items = WorkerHistory.items(records)
        #expect(items.map(\.kind) == [.thinking, .thinking])
        #expect(items[0].calls.map(\.summary) == ["cat a.csv"] && items[0].calls[0].kind == .success)
        #expect(items[0].calls[0].command == nil)
        #expect(items[1].summary == "Then the mapping." && items[1].calls.map(\.id) == ["tool:c2", "5"])
        #expect(items[1].calls[1].outcome == "orphan")
    }

    @Test func pagesMergeInLedgerOrderByNumericID() {
        let older = [WorkerHistoryRecord(id: "9", kind: "user", content: .string("a")), WorkerHistoryRecord(id: "10", kind: "user", content: .string("b"))]
        let newer = [WorkerHistoryRecord(id: "10", kind: "user", content: .string("b2")), WorkerHistoryRecord(id: "100", kind: "user", content: .string("c"))]
        let merged = WorkerHistory.merge(newer, older)
        #expect(merged.map(\.id) == ["9", "10", "100"])
        #expect(merged[1].content == .string("b"))
    }
}
