import Foundation

// Task review, archive, pins, sharing, Worker history and the Group label catalog.
extension CommaClient {
    public func acceptTask(target: ConversationTarget, reviewVersion: Int) async throws -> Conversation {
        guard reviewVersion > 0 else { throw CommaError.invalidInput("Refresh this task before accepting its review.") }
        var result: Conversation = try await json("POST", path(target) + ["accept"],
            query: [URLQueryItem(name: "message_limit", value: "24")], body: ["review_version": .number(Double(reviewVersion))])
        result = result.keepingMessageTail(24)
        try validate(result, target: target); return result
    }

    /// Ends the Task by hand. `expectedUpdatedAt` is the version the member saw; a stale copy is refused.
    public func setTaskStatus(target: ConversationTarget, status: ManualTaskStatus, expectedUpdatedAt: Int) async throws -> Conversation {
        guard expectedUpdatedAt > 0 else { throw CommaError.invalidInput("Refresh this task before changing its status.") }
        var result: Conversation = try await json("POST", path(target) + ["status"],
            query: [URLQueryItem(name: "message_limit", value: "24")],
            body: ["status": .string(status.rawValue), "expected_updated_at": .number(Double(expectedUpdatedAt))])
        result = result.keepingMessageTail(24)
        try validate(result, target: target); return result
    }

    public func cancelTask(target: ConversationTarget) async throws -> Conversation {
        let result: Conversation = try await json("POST", path(target) + ["cancel"], body: [:])
        try validate(result, target: target); return result
    }

    /// Replaces the Task's labels with ids from the Group catalog.
    public func setTaskLabels(target: ConversationTarget, labelIDs: [String]) async throws -> Conversation {
        var result: Conversation = try await json("PATCH", path(target), body: ["labels": .array(labelIDs.map(JSONValue.string))])
        result = result.keepingMessageTail(24)
        try validate(result, target: target); return result
    }

    public func taskLabels(groupID: String) async throws -> TaskLabelCatalog {
        try await json("GET", ["groups", groupID, "task-labels"])
    }

    public func renameTask(target: ConversationTarget, title: String) async throws -> Conversation {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { throw CommaError.invalidInput("Enter a task title of at most 200 characters.") }
        var result: Conversation = try await json("PATCH", path(target), body: ["title": .string(trimmed)])
        result = result.keepingMessageTail(24)
        try validate(result, target: target); return result
    }

    /// `version` is the Task's `updated_at`; the server refuses the change when the Task moved on since.
    public func setTaskArchived(target: ConversationTarget, archived: Bool, version: Int) async throws -> Conversation {
        guard version > 0 else { throw CommaError.invalidInput("Refresh this task before archiving it.") }
        var result: Conversation = try await json("POST", path(target) + [archived ? "archive" : "unarchive"],
                                                  body: ["expected_updated_at": .number(Double(version))])
        result = result.keepingMessageTail(24)
        try validate(result, target: target); return result
    }

    public func pinnedTasks(workspace: Workspace) async throws -> [PinnedTask] {
        let page: Page<PinnedTask> = try await json("GET", ["groups", workspace.groupID, "conversation-pins"])
        guard page.data.count <= 100, page.data.allSatisfy({ $0.conversation.groupID == workspace.groupID }) else { throw CommaError.invalidResponse }
        return page.data
    }

    public func setTaskPinned(target: ConversationTarget, pinned: Bool) async throws {
        if pinned {
            let pin: PinnedTask = try await json("PUT", path(target) + ["pin"], body: [:])
            guard pin.conversation.id == target.conversationID else { throw CommaError.invalidResponse }
        } else {
            _ = try await request("DELETE", path(target) + ["pin"])
        }
    }

    /// The Task's active share link, or nil when it is not shared.
    public func taskShare(target: ConversationTarget) async throws -> TaskShare? {
        do { return try await json("GET", path(target) + ["share"]) }
        catch CommaError.http(let status, _, _) where status == 404 { return nil }
    }

    /// Shares the Task, or moves its existing link's cutoff to the latest message.
    public func publishTaskShare(target: ConversationTarget) async throws -> TaskShare {
        try await json("PUT", path(target) + ["share"], body: [:])
    }

    /// Replaces the link; the previous URL stops working.
    public func resetTaskShare(target: ConversationTarget) async throws -> TaskShare {
        try await json("POST", path(target) + ["share", "reset"], body: [:])
    }

    public func revokeTaskShare(target: ConversationTarget) async throws {
        _ = try await request("DELETE", path(target) + ["share"])
    }

    /// One page of a Worker's session ledger, newest first page when `before` is nil.
    public func workerHistory(target: ConversationTarget, participantID: String, before: String? = nil, limit: Int = 50) async throws -> WorkerHistoryPage {
        guard (1...50).contains(limit), !participantID.isEmpty else { throw CommaError.invalidInput("Worker history bounds are invalid.") }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        let page: WorkerHistoryPage = try await json("GET", path(target) + ["participants", participantID, "history"], query: query)
        guard page.conversationID == target.conversationID, page.participantID == participantID, page.records.count <= limit,
              !page.hasMore || (page.nextBefore != nil && page.nextBefore != before && !page.records.isEmpty) else {
            throw CommaError.invalidResponse
        }
        return page
    }

    public func createTaskLabel(groupID: String, name: String, color: String, description: String? = nil) async throws -> TaskLabelCatalog {
        var body: [String: JSONValue] = ["name": .string(name), "color": .string(color)]
        if let description { body["description"] = .string(description) }
        return try await json("POST", ["groups", groupID, "task-labels"], body: body)
    }

    public func updateTaskLabel(groupID: String, labelID: String, name: String, color: String, description: String? = nil) async throws -> TaskLabelCatalog {
        var body: [String: JSONValue] = ["name": .string(name), "color": .string(color)]
        if let description { body["description"] = .string(description) }
        return try await json("PATCH", ["groups", groupID, "task-labels", labelID], body: body)
    }

    public func deleteTaskLabel(groupID: String, labelID: String) async throws -> TaskLabelCatalog {
        try await json("DELETE", ["groups", groupID, "task-labels", labelID])
    }

    public func resolveTaskLabelProposal(groupID: String, proposalID: String, approve: Bool) async throws -> TaskLabelCatalog {
        try await json("POST", ["groups", groupID, "task-labels", "proposals", proposalID, "resolve"],
                       body: ["decision": .string(approve ? "approve" : "reject")])
    }

    /// `ask` or `auto`.
    public func setTaskLabelApprovalPolicy(groupID: String, policy: String) async throws -> TaskLabelCatalog {
        guard ["ask", "auto"].contains(policy) else { throw CommaError.invalidInput("Unknown label approval policy.") }
        return try await json("PATCH", ["groups", groupID, "task-labels", "policy"], body: ["approval_policy": .string(policy)])
    }
}
