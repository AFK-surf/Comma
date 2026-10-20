import Foundation

// Generation-fenced SSE connections for one conversation or a Group's Task list.
extension CommaClient {
    public func conversationEvents(target: ConversationTarget) -> ConversationEventConnection {
        events(path(target) + ["events"], query: [URLQueryItem(name: "wait", value: "30000"), URLQueryItem(name: "message_limit", value: "24")], target: target)
    }

    public func taskEvents(workspace: Workspace, conversationID: String? = nil) -> ConversationEventConnection {
        var query = [URLQueryItem(name: "wait", value: "30000")]
        if let conversationID { query.append(URLQueryItem(name: "conversation_id", value: conversationID)) }
        return events(["groups", workspace.groupID, "conversations", "events"], query: query,
                      target: conversationID.map { ConversationTarget(workspaceID: workspace.id, groupID: workspace.groupID, conversationID: $0) })
    }

    /// A consumer that exits iteration early must cancel explicitly; `break` alone does not terminate AsyncStream.
    public func cancelConversationEvents(target: ConversationTarget) { cancelEvents(path(target) + ["events"]) }
    public func cancelTaskEvents(workspace: Workspace) { cancelEvents(["groups", workspace.groupID, "conversations", "events"]) }

    private func events(_ path: [String], query: [URLQueryItem], target: ConversationTarget?) -> ConversationEventConnection {
        // Replace a finite stream before reconnecting, including when the previous consumer only broke its loop.
        cancelEvents(path)
        let expected = generation
        let id = UUID()
        let key = path.joined(separator: "/")
        let (events, continuation) = AsyncThrowingStream<ConversationEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let task = Task {
            defer {
                self.cancellation.removeValue(forKey: id)
                if self.eventConnections[key] == id { self.eventConnections.removeValue(forKey: key) }
            }
            do {
                var request = try self.makeRequest("GET", path, query: query)
                request.timeoutInterval = 40; request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                let stream = try await self.transport.stream(for: request)
                defer { stream.cancel() }
                try Task.checkCancellation()
                try self.assertCurrent(expected)
                try self.validateHTTP(HTTPResponse(data: Data(), status: stream.status, url: stream.url, headers: stream.headers), authenticated: true)
                guard stream.headers["content-type"]?.lowercased().hasPrefix("text/event-stream") == true else { throw CommaError.invalidResponse }
                try await withTaskCancellationHandler {
                    var parser = SSEParser()
                    for try await chunk in stream.chunks {
                        try Task.checkCancellation(); try self.assertCurrent(expected)
                        for frame in try parser.append(chunk) {
                            var event = try self.decode(ConversationEvent.self, data: frame.data)
                            // Servers before message_limit support send the whole transcript; the tail is enough.
                            if let messages = event.messages, messages.count > 24 { event.messages = Array(messages.suffix(24)) }
                            let groupID = path.count > 1 && path[0] == "groups" ? path[1] : nil
                            guard event.groupID == nil || event.groupID == groupID else { throw CommaError.invalidResponse }
                            if let target {
                                guard event.groupID == nil || event.groupID == target.groupID,
                                      event.conversationID == nil || event.conversationID == target.conversationID else { throw CommaError.invalidResponse }
                            }
                            switch continuation.yield(event) {
                            case .dropped: throw CommaError.responseTooLarge
                            case .terminated: return
                            case .enqueued: break
                            @unknown default: return
                            }
                        }
                    }
                    _ = try parser.finish(); try self.assertCurrent(expected)
                } onCancel: { stream.cancel() }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        cancellation[id] = { task.cancel() }
        eventConnections[key] = id
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return ConversationEventConnection(events: events, cancel: { task.cancel() })
    }

    private func cancelEvents(_ path: [String]) {
        guard let id = eventConnections.removeValue(forKey: path.joined(separator: "/")),
              let cancel = cancellation.removeValue(forKey: id) else { return }
        cancel()
    }
}
