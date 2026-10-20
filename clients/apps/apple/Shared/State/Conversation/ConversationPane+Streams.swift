import Foundation
import CommaCore

/// The conversation's live event stream and the refreshes it schedules.
extension ConversationPane {
    // MARK: Streams

    /// The router chat listens to its conversation events. A Task listens to the group feed filtered to it, which
    /// also carries task-list invalidations while the Task is open.
    func startStream() {
        stopStream()
        guard let store, let target, let conversation, store.session != nil, !closed else { return }
        let token = fence
        let isTask = conversation.isTask
        stream = Task { [weak self] in
            var retry = 0
            while !Task.isCancelled {
                guard let self, self.isLive(token), store.session != nil else { return }
                let incarnation = self.updateChannel { $0.beginStream() } ?? 0
                do {
                    let events = isTask
                        ? await store.client.taskEvents(workspace: self.workspace, conversationID: target.conversationID)
                        : await store.client.conversationEvents(target: target)
                    defer { events.cancel() }
                    for try await event in events {
                        guard self.isLive(token), !Task.isCancelled else { return }
                        self.connected = true
                        // Back after an outage: read what the stream missed, which answers the failure it reported.
                        if retry > 0 { self.scheduleRefresh() }
                        retry = 0
                        if isTask {
                            if event.type == "task_participant_statuses" {
                                try self.updateChannel { try $0.apply(event: event, incarnation: incarnation) }
                            }
                            if ["conversation_list_invalidated", "conversation_list_resync_required"].contains(event.type) {
                                // The task list refreshes below, so the Task's own refresh does not ask again.
                                self.scheduleRefresh()
                                store.scheduleTaskListRefresh()
                            }
                        } else if try self.updateChannel(coalescingDraft: event.type == "message_draft_delta", {
                            try $0.apply(event: event, incarnation: incarnation)
                        }) == true {
                            // A new message or a cancelled reply arrives with the reconnect's snapshot, which swaps
                            // the draft for the message in one update, as on the desktop. A separate read could
                            // land first and show the message beside the draft.
                            let transcriptOnly = event.type == "message_created" || event.type.hasPrefix("message_draft_")
                            if !transcriptOnly { self.scheduleRefresh() }
                            break
                        }
                    }
                    // A wait that ended with no event connected all the same: a quiet conversation is back too.
                    if retry > 0, self.isLive(token), !Task.isCancelled {
                        self.connected = true
                        self.scheduleRefresh()
                        retry = 0
                    }
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    guard self.isLive(token), !Task.isCancelled else { return }
                    self.connected = false
                    // Once per outage: the attempts after the first, until one connects, report nothing new. Each
                    // still checks whether the session ended meanwhile.
                    if retry == 0 { self.present(error, token) } else { store.checkSessionAfter(error) }
                    retry = min(retry + 1, 4)
                    try? await Task.sleep(for: .seconds(min(15, 1 << retry)))
                }
            }
        }
    }

    func stopStream() {
        stream?.cancel(); stream = nil
        refreshTask?.cancel(); refreshTask = nil
        connected = false
    }

    /// Only stream invalidations schedule this; a Task's list refresh is scheduled beside it.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        let token = fence
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.isLive(token) else { return }
            await self.refresh(updatingTaskList: false)
            if self.isLive(token) { self.refreshTask = nil }
        }
    }
}
