import Foundation

// The router chat, Task listing and search, transcripts, sending with tagged skills, and message attachments.
extension CommaClient {
    /// The member's router chat ("Comma") in the Workspace's Group, with its newest 24 messages.
    public func openRouter(workspace: Workspace) async throws -> Conversation {
        var result: Conversation = try await json("POST", ["groups", workspace.groupID, "assistant-chat"],
            query: [URLQueryItem(name: "message_limit", value: "24")], body: [:])
        guard result.groupID == workspace.groupID && result.kind == "user_chat" else { throw CommaError.invalidResponse }
        result = result.keepingMessageTail(24)
        return result
    }

    /// `archived` lists only archived Tasks instead of the active ones.
    public func listTasks(workspace: Workspace, cursor: String? = nil, archived: Bool = false) async throws -> Page<Conversation> {
        var query = [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "kind", value: "agent_task"),
                     URLQueryItem(name: "archive", value: archived ? "only" : "exclude")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page: Page<Conversation> = try await json("GET", ["groups", workspace.groupID, "conversations"], query: query)
        guard page.data.count <= 50, page.data.allSatisfy({ $0.groupID == workspace.groupID && $0.kind == "agent_task" }) else { throw CommaError.invalidResponse }
        return page
    }

    public func searchTasks(workspace: Workspace, query: String, limit: Int = 20) async throws -> [Conversation] {
        guard (1...50).contains(limit), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommaError.invalidInput("Enter a search query with a limit between 1 and 50.")
        }
        struct Hit: Codable, Sendable { let conversation_id: String }
        let matches: Page<Hit> = try await json("GET", ["groups", workspace.groupID, "conversations", "search"],
            query: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))])
        guard matches.data.count <= limit else { throw CommaError.responseTooLarge }
        let ids = matches.data.map(\.conversation_id)
        if ids.isEmpty { return [] }
        let summaries: Page<Conversation> = try await json("GET", ["groups", workspace.groupID, "task-summaries"],
            query: [URLQueryItem(name: "ids", value: ids.joined(separator: ","))])
        guard summaries.data.count <= limit, summaries.data.allSatisfy({ $0.groupID == workspace.groupID && $0.isTask && ids.contains($0.id) }) else { throw CommaError.invalidResponse }
        let byID = Dictionary(summaries.data.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return ids.compactMap { byID[$0] }
    }

    public func conversation(target: ConversationTarget, messageLimit: Int = 24) async throws -> Conversation {
        guard (1...100).contains(messageLimit) else { throw CommaError.invalidInput("Message limit must be between 1 and 100.") }
        var result: Conversation = try await json("GET", path(target), query: [URLQueryItem(name: "message_limit", value: String(messageLimit))])
        result = result.keepingMessageTail(messageLimit)
        try validate(result, target: target); return result
    }

    public func messageHistory(target: ConversationTarget, before: Int? = nil, limit: Int = 100) async throws -> MessagePage {
        guard (1...100).contains(limit), before == nil || before! > 0 else { throw CommaError.invalidInput("Message history bounds are invalid.") }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        let page: MessagePage = try await json("GET", path(target) + ["messages"], query: query)
        guard page.data.count <= limit else { throw CommaError.responseTooLarge }; return page
    }

    /// Allocate requestID when the pending bubble is created and retain it on retries. `skills` are the locations of
    /// the skills the text names (`Skill.mentionedLocations`); the server activates them for this message.
    public func send(target: ConversationTarget, text: String, requestID: String, attachments: [ContentBlock] = [],
                     skills: [String] = [], replyToMessageID: String? = nil) async throws -> Conversation {
        guard !requestID.isEmpty && requestID.utf8.count <= 256, attachments.count <= 8 else { throw CommaError.invalidInput("Message request or attachment count is invalid.") }
        guard skills.count <= Skill.maxMentions, skills.allSatisfy({ location in
            !location.isEmpty && location.utf8.count <= 1_024 && !location.containsLineBreak
        }) else { throw CommaError.invalidInput("Skill locations are invalid.") }
        var messageText = text
        if !attachments.isEmpty {
            let lines = try attachments.map { attachment -> String in
                guard attachment.type == "workspace_file", let name = attachment.fields["name"]?.string,
                      let path = attachment.fields["path"]?.string, path.hasPrefix("/"),
                      !name.containsLineBreak, !path.containsLineBreak else {
                    throw CommaError.invalidInput("The uploaded file reference is invalid.")
                }
                return "- \(name) (workspace file: \(path))"
            }
            messageText = (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "I've attached some files:" : text) +
                "\n\nAttached files in your workspace:\n" + lines.joined(separator: "\n")
        }
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CommaError.invalidInput("Write a message or attach a file.") }
        var body: [String: JSONValue] = ["client_request_id": .string(requestID), "message": .object(["type": .string("text"), "text": .string(messageText)])]
        if let replyToMessageID { body["reply_to_message_id"] = .string(replyToMessageID) }
        if !skills.isEmpty { body["skills"] = .array(skills.map { .object(["location": .string($0)]) }) }
        var result: Conversation = try await json("POST", path(target) + ["messages"],
            query: [URLQueryItem(name: "message_limit", value: "24")], body: body)
        result = result.keepingMessageTail(24)
        try validate(result, target: target); return result
    }

    public func uploadFile(workspace: Workspace, filename: String, contentType: String, data: Data) async throws -> ContentBlock {
        guard data.count <= 10_000_000, !filename.isEmpty, filename.utf8.count <= 1_024,
              !filename.containsLineBreak, !contentType.containsLineBreak else {
            throw CommaError.invalidInput("Files must be at most 10 MB with a valid name.")
        }
        let boundary = "Comma-" + UUID().uuidString
        let safeName = filename.replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\"", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8)
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let response = try await request("POST", ["groups", workspace.groupID, "files"], body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        let raw = try decode([String: JSONValue].self, data: response.data)
        guard let path = raw["path"]?.string, path.hasPrefix("/"), let name = raw["name"]?.string, let size = raw["size"],
              !path.containsLineBreak, !name.containsLineBreak else { throw CommaError.invalidResponse }
        return ContentBlock(type: "workspace_file", fields: ["path": .string(path), "name": .string(name), "size": size])
    }

    public func download(target: ConversationTarget, messageID: String, index: Int) async throws -> DownloadedAttachment {
        guard index >= 0 && index < 8 else { throw CommaError.invalidInput("Attachment index is invalid.") }
        let response = try await request("GET", path(target) + ["messages", messageID, "attachments", String(index)])
        guard response.data.count <= 10_000_000 else { throw CommaError.responseTooLarge }
        return DownloadedAttachment(data: response.data, contentType: response.headers["content-type"] ?? "application/octet-stream")
    }

    func path(_ target: ConversationTarget) -> [String] { ["groups", target.groupID, "conversations", target.conversationID] }
    func validate(_ conversation: Conversation, target: ConversationTarget) throws {
        guard conversation.id == target.conversationID && conversation.groupID == target.groupID else { throw CommaError.invalidResponse }
    }
}

extension String {
    /// A line break of any kind anywhere: LF, CR, VT, FF, NEL, or the Unicode line and paragraph separators, any of
    /// which can start a new line where the text is read. Swift reads "\r\n" as one Character, so the check runs
    /// on scalars; `contains("\n")` would miss it there.
    var containsLineBreak: Bool { unicodeScalars.contains { CharacterSet.newlines.contains($0) } }
}
