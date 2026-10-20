import Foundation

/// One canonical record of a Worker's session ledger. `content` keeps the provider's JSON shape.
public struct WorkerHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let content: JSONValue?
    public let inputText: String?
    public let createdAt: JSONValue?
    public let timestampMs: Double?
    public let execution: Execution?

    public struct Execution: Codable, Equatable, Sendable {
        public let id: String?
        public let lane: String?
        public let startedAtMs: Double?
        enum CodingKeys: String, CodingKey { case id, lane, startedAtMs = "started_at_ms" }
    }
    enum CodingKeys: String, CodingKey {
        case id, kind, content, inputText = "input_text", createdAt = "created_at", timestampMs = "timestamp_ms", execution
    }
    public init(id: String, kind: String, content: JSONValue?, inputText: String? = nil,
                createdAt: JSONValue? = nil, timestampMs: Double? = nil, execution: Execution? = nil) {
        self.id = id; self.kind = kind; self.content = content; self.inputText = inputText
        self.createdAt = createdAt; self.timestampMs = timestampMs; self.execution = execution
    }

    /// Ledger order: numeric ids compare by value, others lexically, as on the desktop.
    static func orderKey(_ id: String) -> String {
        id.count <= 20 && id.allSatisfy(\.isASCII) && id.allSatisfy(\.isNumber)
            ? String(repeating: "0", count: 32 - id.count) + id : id
    }

    /// When the step started, in seconds since 1970.
    public var startedAt: Date? {
        if let ms = execution?.startedAtMs ?? timestampMs { return Date(timeIntervalSince1970: ms / 1000) }
        switch createdAt {
        case .number(let value): return Date(wireTimestamp: value)
        case .string(let value): return try? Date(value, strategy: .iso8601)
        default: return nil
        }
    }
}

/// One `GET …/participants/:id/history` page. `nextBefore` pages towards older records.
public struct WorkerHistoryPage: Codable, Sendable {
    public let conversationID: String
    public let participantID: String
    public let records: [WorkerHistoryRecord]
    public let hasMore: Bool
    public let nextBefore: String?
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id", participantID = "participant_id", records
        case hasMore = "has_more", nextBefore = "next_before"
    }
}

/// A Worker step as the phone shows it: what the Worker read, said, or ran, and how a tool call ended. A step the
/// Worker took to run tools keeps those calls as its `calls`, so each call shows under the thinking that started it.
public struct WorkerHistoryItem: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case input, model, thinking, call, running, success, failure, cancelled, result }
    public let id: String
    public var kind: Kind
    public var tool: String?
    /// What the step said, or what a call set out to do.
    public var summary: String
    public var startedAt: Date?
    /// A call's command line, when its arguments carry one besides the summary.
    public var command: String?
    /// What a call returned, or why it failed or stopped.
    public var outcome: String?
    public var calls: [WorkerHistoryItem] = []
}

public enum WorkerHistory {
    /// Merges pages by record id in ledger order; a later copy of a record replaces the earlier one.
    public static func merge(_ current: [WorkerHistoryRecord], _ incoming: [WorkerHistoryRecord]) -> [WorkerHistoryRecord] {
        var byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for record in incoming { byID[record.id] = record }
        return byID.values.sorted { WorkerHistoryRecord.orderKey($0.id) < WorkerHistoryRecord.orderKey($1.id) }
    }

    /// Projects records into readable steps. Tool calls belong to the step that started them: the assistant record's
    /// own thinking, else the thinking or tool step right before them, else a step of their own. Tool lifecycle
    /// records join their call only by explicit call id; context, system and runtime bookkeeping records are not shown.
    public static func items(_ records: [WorkerHistoryRecord]) -> [WorkerHistoryItem] {
        var items: [WorkerHistoryItem] = []
        /// Where each call sits: its step's index and its place among that step's calls.
        var calls: [String: (step: Int, call: Int)] = [:]
        for record in records {
            let content = object(record.content)
            switch record.kind {
            case "user":
                let summary = text(record.inputText.map(JSONValue.string) ?? content["content"] ?? record.content)
                if !summary.isEmpty { items.append(.init(id: record.id, kind: .input, summary: summary, startedAt: record.startedAt)) }
            case "assistant":
                let prose = text(content["content"] ?? record.content)
                let toolCalls = toolCalls(content["tool_calls"])
                let reasoning = text(content["reasoning"] ?? content["reasoning_content"])
                if !prose.isEmpty {
                    items.append(.init(id: record.id, kind: .model, summary: prose, startedAt: record.startedAt))
                } else if !reasoning.isEmpty {
                    items.append(.init(id: record.id, kind: .thinking, summary: reasoning, startedAt: record.startedAt))
                }
                guard !toolCalls.isEmpty else { continue }
                if items.last.map({ $0.kind != .thinking && $0.kind != .call }) ?? true {
                    items.append(.init(id: record.id, kind: .call, summary: "", startedAt: record.startedAt))
                }
                let step = items.count - 1
                for call in toolCalls {
                    if !call.id.isEmpty, let at = calls[call.id] {
                        items[at.step].calls[at.call].tool = items[at.step].calls[at.call].tool ?? call.name
                        continue
                    }
                    let summary = argumentSummary(call.args), command = text(call.args["command"])
                    if !call.id.isEmpty { calls[call.id] = (step, items[step].calls.count) }
                    items[step].calls.append(.init(id: "tool:" + (call.id.isEmpty ? record.id + call.name : call.id), kind: .call,
                                                   tool: call.name, summary: summary, startedAt: record.startedAt,
                                                   command: command.isEmpty || command == summary ? nil : command))
                }
            case "summary", "system", "developer", "runtime", "runtime.event":
                continue
            default:
                guard let item = toolItem(record) else { continue }
                if let callID = item.callID, let at = calls[callID] {
                    var call = items[at.step].calls[at.call]
                    // A late receipt never turns a finished call back into a running one.
                    if item.item.kind == .running, call.kind != .call, call.kind != .running { continue }
                    call.kind = item.item.kind
                    call.tool = item.item.tool ?? call.tool
                    if let outcome = item.item.outcome, item.item.kind != .running || call.outcome == nil { call.outcome = outcome }
                    items[at.step].calls[at.call] = call
                } else {
                    // A result whose call is not on the page joins the step before it, as a call would.
                    if items.last.map({ $0.kind != .thinking && $0.kind != .call }) ?? true {
                        items.append(.init(id: "step:" + record.id, kind: .call, summary: "", startedAt: record.startedAt))
                    }
                    if let callID = item.callID { calls[callID] = (items.count - 1, items[items.count - 1].calls.count) }
                    items[items.count - 1].calls.append(item.item)
                }
            }
        }
        return items
    }

    private static func toolItem(_ record: WorkerHistoryRecord) -> (callID: String?, item: WorkerHistoryItem)? {
        let content = object(record.content)
        var data = content
        for (key, value) in object(decoded(content["content"] ?? record.content)) { data[key] = value }
        for (key, value) in object(content["event"]) { data[key] = value }
        let result = object(decoded(data["result"]))
        let payload = object(decoded(result["content"] ?? data["content"]))
        let eventType = text(data["type"]).isEmpty ? record.kind : text(data["type"])
        let status = [data["status"], data["state"], result["status"], payload["status"]].lazy.map(text).first { !$0.isEmpty } ?? ""
        let failed = [data, result, payload].contains {
            $0["is_error"]?.bool == true || $0["error"]?.bool == true || !text($0["error_message"]).isEmpty
                || !($0["error"]?.string ?? "").isEmpty
        }
        let isTool = record.kind == "tool" || record.kind.hasPrefix("session.async_tool_call_") || record.execution?.lane == "tool"
            || eventType.hasPrefix("tool_call_")
        if record.kind.hasPrefix("session."), !isTool { return nil }
        let callID = [data["tool_call_id"], result["id"]].lazy.map(text).first { !$0.isEmpty } ?? (isTool ? record.execution?.id : nil)
        let tool = [data["tool_name"], result["name"], data["name"]].lazy.map(text).first { !$0.isEmpty }
        let kind: WorkerHistoryItem.Kind
        if failed || eventType.hasSuffix("error") || eventType.hasSuffix("failed") || ["failed", "error"].contains(status) {
            kind = .failure
        } else if eventType.hasSuffix("cancelled") || ["cancelled", "canceled"].contains(status) {
            kind = .cancelled
        } else if (eventType.contains("tool") && (eventType.hasSuffix("started") || eventType.hasSuffix("progress")))
                    || ["running", "pending", "in_progress", "waiting"].contains(status) {
            kind = .running
        } else if (eventType.contains("tool") && eventType.hasSuffix("completed")) || ["completed", "success", "succeeded"].contains(status) {
            kind = .success
        } else if isTool {
            kind = .result
        } else {
            return nil
        }
        let outcome: String
        switch kind {
        case .failure:
            outcome = [data["error_message"], result["error_message"], payload["error_message"], data["error"], result["error"],
                       data["message"]].lazy.map(text).first { !$0.isEmpty } ?? ""
        case .cancelled: outcome = text(data["cancel_reason"] ?? data["message"])
        case .running: outcome = text(data["progress"])
        default: outcome = text(data["output"] ?? result["content"] ?? data["result"])
        }
        return (callID?.isEmpty == false ? callID : nil,
                WorkerHistoryItem(id: record.id, kind: kind, tool: tool, summary: "", startedAt: record.startedAt,
                                  outcome: outcome.isEmpty ? nil : outcome))
    }

    private struct ToolCall { let id: String; let name: String; let args: [String: JSONValue] }

    private static func toolCalls(_ value: JSONValue?) -> [ToolCall] {
        (value?.array ?? []).map { entry in
            let call = object(entry)
            let function = object(call["function"])
            let args = object(decoded(call["args"] ?? call["arguments"] ?? function["arguments"]))
            let name = text(call["name"] ?? function["name"])
            if name == "call" { return ToolCall(id: text(call["id"]), name: text(args["tool"]).isEmpty ? name : text(args["tool"]), args: object(args["params"])) }
            return ToolCall(id: text(call["id"]), name: name, args: args)
        }
    }

    private static func argumentSummary(_ args: [String: JSONValue]) -> String {
        ["description", "content", "query", "command", "path", "url", "title"].lazy.map { text(args[$0]) }.first { !$0.isEmpty } ?? ""
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue] { value?.object ?? [:] }

    /// Tool arguments and results sometimes arrive as JSON text.
    private static func decoded(_ value: JSONValue?) -> JSONValue? {
        guard let string = value?.string, let first = string.first, first == "{" || first == "[",
              let parsed = try? decoder.decode(JSONValue.self, from: Data(string.utf8)) else { return value }
        return parsed
    }

    /// One decoder for every embedded payload, rather than one per record.
    private static let decoder = JSONDecoder()

    static let summaryLimit = 600

    private static func text(_ value: JSONValue?) -> String {
        let raw: String
        switch value {
        case .string(let value): raw = value
        case .array(let blocks): raw = blocks.prefix(8).compactMap { $0.object?["text"]?.string }.joined(separator: "\n")
        default: raw = ""
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > summaryLimit ? String(trimmed.prefix(summaryLimit)) + "…" : trimmed
    }
}
