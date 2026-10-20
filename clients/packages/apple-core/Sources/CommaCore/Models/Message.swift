import Foundation

// Message content, transient assistant drafts and paged message history.

public struct ContentBlock: Codable, Equatable, Sendable {
    public let type: String
    public let fields: [String: JSONValue]
    public var text: String? { fields["text"]?.string }
    public init(type: String, fields: [String: JSONValue] = [:]) { self.type = type; self.fields = fields }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let value = try c.decode([String: JSONValue].self)
        guard let type = value["type"]?.string, !type.isEmpty else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Content block requires a type")
        }
        self.type = type; self.fields = value.filter { $0.key != "type" }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(fields.merging(["type": .string(type)]) { _, expected in expected })
    }
}

/// The server exposes provider-owned chat content separately from private agent input.
public struct PlatformMessage: Codable, Equatable, Sendable {
    public let provider: String
    public let role: String
    public let content: [ContentBlock]
    public init(provider: String, role: String, content: [ContentBlock]) {
        self.provider = provider; self.role = role; self.content = content
    }
}

public struct Message: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let actorType: String
    public let content: [ContentBlock]
    public let clientRequestID: String?
    public let replyToMessageID: String?
    public let threadRootMessageID: String?
    public let agentID: String?
    public let userID: String?
    public let roleLabel: String?
    public let createdAt: Double?
    public let metadata: [String: JSONValue]?
    public let agentInput: JSONValue?
    public let platformMessage: PlatformMessage?
    public var displayContent: [ContentBlock] { platformMessage?.content ?? content }
    public var rawText: String { content.compactMap(\.text).joined(separator: "\n") }
    public var text: String { Self.publicText(displayContent.compactMap(\.text).joined(separator: "\n")) }
    public var isUser: Bool { platformMessage?.role == "user" || actorType == "user" }
    public var isRouterReply: Bool {
        guard isVisible else { return false }
        if let platformMessage {
            return actorType == "system" && metadata?["event_type"]?.string == "provider.message"
                && platformMessage.role == "assistant" && !platformMessage.content.isEmpty
        }
        return ["agent", "assistant"].contains(actorType) && !text.isEmpty
    }
    public var isVisible: Bool {
        if platformMessage != nil { return true }
        if rawText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[[comma-context]]") { return false }
        if actorType == "system", agentInput != nil { return false }
        if actorType == "system" && kind == "app_event" {
            let event = metadata?["event_type"]?.string ?? ""
            // `mail.*` events record a Home mail interaction's state change and have no content.
            if event.hasPrefix("mail.") || ["provider.output", "provider.status", "message.redelivery"].contains(event) { return false }
        }
        return true
    }
    enum CodingKeys: String, CodingKey {
        case id = "message_id", kind, actorType = "actor_type", content, clientRequestID = "client_request_id"
        case replyToMessageID = "reply_to_message_id", threadRootMessageID = "thread_root_message_id"
        case agentID = "agent_id", userID = "user_id", roleLabel = "role_label"
        case createdAt = "created_at", metadata, agentInput = "agent_input", platformMessage = "platform_message"
    }
    public init(id: String, kind: String, actorType: String, content: [ContentBlock], clientRequestID: String? = nil,
                replyToMessageID: String? = nil, threadRootMessageID: String? = nil, agentID: String? = nil,
                userID: String? = nil, roleLabel: String? = nil, createdAt: Double? = nil,
                metadata: [String: JSONValue]? = nil, agentInput: JSONValue? = nil, platformMessage: PlatformMessage? = nil) {
        self.id = id; self.kind = kind; self.actorType = actorType; self.content = content
        self.clientRequestID = clientRequestID; self.replyToMessageID = replyToMessageID
        self.threadRootMessageID = threadRootMessageID; self.agentID = agentID; self.userID = userID; self.roleLabel = roleLabel
        self.createdAt = createdAt; self.metadata = metadata; self.agentInput = agentInput; self.platformMessage = platformMessage
    }
    /// The text a member may see: everything before the protocol tail, without private `comma:` fences.
    /// Runs for every row on every transcript pass, so text without either marker skips the split and the regex;
    /// neither can match where the marker's bytes are absent, so the result is the same.
    public static func publicText(_ text: String) -> String {
        guard text.containsMarker(protocolMarker) || text.containsMarker(fenceMarker) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prefix = text.components(separatedBy: protocolMarker).first ?? ""
        let range = NSRange(prefix.startIndex..., in: prefix)
        return privateFence.stringByReplacingMatches(in: prefix, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let protocolMarker = "[[comma-protocol]]"
    private static let fenceMarker = "```comma:"
    /// The pattern `replacingOccurrences(of:options: .regularExpression)` compiled on every call before.
    private static let privateFence = try! NSRegularExpression(pattern: "```comma:[\\s\\S]*?(?:```|$)")
}

extension String {
    /// Byte search for an ASCII marker over the string's UTF-8 storage: no bridging, no grapheme breaking.
    /// The fast path of the per-row transcript projections (`Message.publicText`, `ControlCommand.displayText`).
    func containsMarker(_ marker: String) -> Bool {
        var text = self, marker = marker
        text.makeContiguousUTF8(); marker.makeContiguousUTF8()  // No-ops for native strings.
        let found = text.utf8.withContiguousStorageIfAvailable { haystack in
            marker.utf8.withContiguousStorageIfAvailable { needle in
                memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
            } ?? false
        }
        return found ?? false
    }
}

public struct AssistantDraft: Codable, Equatable, Identifiable, Sendable {
    public let conversationID: String
    public let draftID: String
    public let responseKey: String
    public let sourceMessageIDs: [String]
    public let revision: Int
    public let text: String
    public var displayText: String { Message.publicText(text) }
    public var id: String { responseKey + ":" + sourceMessageIDs.joined(separator: ",") }
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id", draftID = "draft_id", responseKey = "response_key"
        case sourceMessageIDs = "source_message_ids", revision, text
    }
    public init(conversationID: String, draftID: String, responseKey: String, sourceMessageIDs: [String], revision: Int, text: String) {
        self.conversationID = conversationID; self.draftID = draftID; self.responseKey = responseKey
        self.sourceMessageIDs = sourceMessageIDs; self.revision = revision; self.text = text
    }
}

public struct SequenceSpan: Codable, Equatable, Sendable { public let first: Int; public let last: Int }
public struct MessagePage: Codable, Sendable {
    public let data: [Message]
    public let covered: SequenceSpan?
    public let bounds: SequenceSpan?
    public let hasOlder: Bool
    public let hasNewer: Bool
    enum CodingKeys: String, CodingKey { case data, covered, bounds, hasOlder = "has_older", hasNewer = "has_newer" }
}
public struct DownloadedAttachment: Sendable {
    public let data: Data
    public let contentType: String
    public init(data: Data, contentType: String) { self.data = data; self.contentType = contentType }
}
