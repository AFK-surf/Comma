import Foundation
import Testing
@testable import CommaCore

@Suite("Conversation presentation")
struct ConversationStateTests {
    @Test func reconnectDraftsAreCumulativeAndReplaceAtomicallyWithCanonicalHistory() throws {
        var state = ConversationState(target: target)
        let first = state.beginStream()
        try state.apply(event: draftFrame(text: "Before snapshot"), incarnation: first)
        #expect(state.draft == nil)
        try state.apply(event: snapshot(), incarnation: first)
        try state.apply(event: draftFrame(text: "Hello"), incarnation: first)
        try state.apply(event: draftFrame("delta", text: "Hello world", revision: 3), incarnation: first)
        try state.apply(event: draftFrame("delta", text: "Hello", revision: 2), incarnation: first)
        #expect(state.draft?.text == "Hello world")
        let second = state.beginStream()
        try state.apply(event: draftFrame("delta", text: "Old callback", revision: 4), incarnation: first)
        #expect(state.draft?.text == "Hello world")
        let owner = "{\"conversation_id\":\"c1\",\"draft_id\":\"d1\",\"response_key\":\"r1\",\"source_message_ids\":[\"m1\"],\"revision\":4,\"text\":\"Hello world!\"}"
        try state.apply(event: snapshot(owner), incarnation: second)
        #expect(state.draft?.text == "Hello world!")
        let canonical = "[{\"message_id\":\"assistant1\",\"kind\":\"message\",\"actor_type\":\"agent\",\"content\":[{\"type\":\"text\",\"text\":\"Hello world!\"}]}]"
        try state.apply(event: snapshot(messages: canonical), incarnation: second)
        #expect(state.draft == nil)
        #expect(state.messages.map(\.text) == ["Hello world!"])
    }

    @Test func draftSourceOrderAndCancellationFencePreventQueuedResurrection() throws {
        var state = ConversationState(target: target)
        let first = state.beginStream()
        try state.apply(event: snapshot(), incarnation: first)
        try state.apply(event: draftFrame(text: "Reply", sources: ["m1", "m2"]), incarnation: first)
        try state.apply(event: draftFrame("delta", text: "Reply corrupted", revision: 2, sources: ["m2", "m1"]), incarnation: first)
        #expect(state.draft?.text == "Reply")
        let restart = try state.apply(event: draftFrame("cancelled", text: "Reply", sources: ["m1", "m2"]), incarnation: first)
        #expect(restart)
        #expect(state.draft?.text == "Reply")
        let second = state.beginStream()
        try state.apply(event: snapshot(), incarnation: second)
        try state.apply(event: draftFrame(text: "Queued duplicate", sources: ["m1", "m2"]), incarnation: second)
        #expect(state.draft == nil)
        let third = state.beginStream()
        try state.apply(event: snapshot(), incarnation: third)
        try state.apply(event: draftFrame(text: "New activation send", sources: ["m1", "m2"]), incarnation: third)
        #expect(state.draft?.text == "New activation send")
    }

    @Test func participantActivityCannotCompleteTaskAndLoadedHistorySurvivesTailRefresh() throws {
        var state = ConversationState(target: target)
        let old = Message(id: "old", kind: "message", actorType: "user", content: [ContentBlock(type: "text", fields: ["text": .string("Older")])])
        let task = Conversation(id: "c1", groupID: "g1", title: "Task", status: "ready_for_review", kind: "agent_task", reviewVersion: 4, messages: [old])
        try state.reconcile(conversation: task)
        let stream = state.beginStream()
        try state.apply(event: event("{\"type\":\"task_participant_statuses\",\"conversation_id\":\"c1\",\"bound_worker\":{\"participant_id\":\"p1\",\"name\":\"Research Worker\"},\"participants\":[{\"conversation_id\":\"c1\",\"participant_id\":\"p1\",\"state\":\"active\",\"status\":\"running\",\"updated_at\":12}]}"), incarnation: stream)
        #expect(state.conversation?.bucket == .needsReview)
        #expect(state.participantStatuses.first?.status == "running")
        #expect(state.boundWorker == BoundWorker(participantID: "p1", name: "Research Worker"))
        let tail = Message(id: "new", kind: "message", actorType: "agent", content: [])
        try state.reconcile(conversation: Conversation(id: "c1", groupID: "g1", title: "Task", status: "ready_for_review", kind: "agent_task", messages: [tail]))
        #expect(state.messages.map(\.id) == ["old", "new"])
        #expect(throws: CommaError.invalidResponse) {
            try state.reconcile(conversation: Conversation(id: "other", groupID: "g1", title: "Other", status: "active", kind: "agent_task"))
        }
    }

    @Test func malformedTransientOwnerDoesNotLoseReadableCanonicalHistory() throws {
        var state = ConversationState(target: target)
        let stream = state.beginStream()
        let message = "[{\"message_id\":\"m1\",\"kind\":\"message\",\"actor_type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Canonical\"}]}]"
        try state.apply(event: snapshot("{\"unexpected\":true}", messages: message), incarnation: stream)
        #expect(state.messages.first?.text == "Canonical")
        #expect(state.draft == nil)
    }

    @Test func contextAndPrivateFencesStayOutOfChatPresentation() throws {
        var state = ConversationState(target: target)
        let privateRow = Message(id: "context", kind: "message", actorType: "system", content: [ContentBlock(type: "text", fields: ["text": .string("[[comma-context]] internal instructions")])])
        let reply = Message(id: "reply", kind: "message", actorType: "agent", content: [ContentBlock(type: "text", fields: ["text": .string("Public\n```comma:private\ninternal\n```\nReply[[comma-protocol]]hidden")])])
        try state.reconcile(conversation: Conversation(id: "c1", groupID: "g1", title: "Chat", status: "open", kind: "user_chat", messages: [privateRow, reply]))
        #expect(state.messages.map(\.id) == ["reply"])
        #expect(state.messages.first?.text == "Public\n\nReply")
        #expect(Message.publicText("Visible\n```comma:private\ntruncated") == "Visible")
    }

    @Test func homeMailInteractionEventsStayOutOfChat() throws {
        var state = ConversationState(target: target)
        let mail = Message(id: "mail-quiet", kind: "app_event", actorType: "system", content: [],
                           metadata: ["event_type": .string("mail.quiet"), "mail_source": .string("gmail:thread")])
        let reply = Message(id: "reply", kind: "message", actorType: "agent", content: [ContentBlock(type: "text", fields: ["text": .string("Done")])])
        try state.reconcile(conversation: Conversation(id: "c1", groupID: "g1", title: "Home", status: "open", kind: "user_chat", messages: [mail, reply]))
        #expect(state.messages.map(\.id) == ["reply"])
    }
}
