package surf.comma.android.chat.live

import surf.comma.android.conversation.replyOf
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.conversation.Connection
import surf.comma.android.conversation.ConversationProblem
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.display
import surf.comma.android.conversation.ParticipantStatus
import surf.comma.android.conversation.PendingMessage
import surf.comma.android.conversation.PendingStatus
import surf.comma.android.conversation.ReplyDraft
import surf.comma.android.conversation.TimelineEntry

/**
 * A reply is shown one complete message at a time: drafts drive the typing bubble only, and
 * every way a wait can end (a message, a stop, an error, a lost connection, another
 * conversation) takes the bubble away. Invented test data only.
 */
class WholeReplyTimelineTest {
    private fun message(seq: Long, actor: String, text: String, requestId: String? = null): TimelineEntry {
        val json = JSONObject().put("message_id", "msg_$seq").put("seq", seq).put("actor_type", actor)
            .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", text)))
            .put("created_at", 1_700_000_000_000L + seq)
            .apply { requestId?.let { put("client_request_id", it) }; if (actor == "agent") put("agent_id", "agt_1") }
        val display = display(json)!!
        return TimelineEntry.Message(display.clientRequestId?.let { "r:$it" } ?: "m:${display.messageId}", display)
    }

    private fun draft(text: String, ended: Boolean = false, response: String = "resp-1") =
        ReplyDraft(response, listOf("msg_1"), "d1", 3, text, ended).let { TimelineEntry.Draft(it.key, it) }

    private val question = message(1, "user", "q", requestId = "req-1")
    private val active = ParticipantStatus("ptp_1", "active", "is working", null, null, null)

    private fun state(
        vararg entries: TimelineEntry,
        participant: ParticipantStatus? = null,
        awaiting: Boolean = false,
        connection: Connection = Connection.LIVE,
        problem: ConversationProblem? = null,
        conversation: String = "cnv_1",
    ) = ConversationState(conversationId = conversation, timeline = entries.toList(), participant = participant,
        reply = replyOf(participant, awaiting, entries.toList()), connection = connection, problem = problem)

    private fun rows(state: ConversationState) = mapConversation(state, replyActions = true).rows
    private fun List<ChatMessage>.typing() = count { it.cardKind == TimelineBlockKinds.LIVE_STATUS }
    private fun List<ChatMessage>.texts() = filter { it.cardKind == null }.map { it.text }

    @Test fun `each canonical message shows whole as it lands while the reply goes on`() {
        // The first message landed; the agent is still drafting the next one.
        val one = rows(state(question, message(2, "agent", "First part, **complete**."), draft("Second pa"),
            participant = active))
        assertEquals(listOf("q", "First part, complete."), one.texts())
        assertEquals(1, one.typing())
        assertEquals(listOf(null, null, TimelineBlockKinds.LIVE_STATUS, LiveRowKinds.REPLY_ACTIONS_RESERVED),
            one.map { it.cardKind })
        // The second lands, the agent finishes: no bubble, buttons under the whole reply.
        val two = rows(state(question, message(2, "agent", "First part, **complete**."),
            message(3, "agent", "Second part."), participant = active.copy(state = "stopped")))
        assertEquals(listOf("q", "First part, complete.", "Second part."), two.texts())
        assertEquals(0, two.typing())
        assertEquals(LiveRowKinds.REPLY_ACTIONS, two.last().cardKind)
        assertEquals("the first message keeps its row", one[1].id, two[1].id)
        assertTrue(two.none { it.status == MessageStatus.STREAMING })
    }

    @Test fun `a draft and its message are never shown twice`() {
        // A snapshot installs the message while the old draft is still being cleared.
        val both = rows(state(question, message(2, "agent", "Answer"), draft("Answer")))
        assertEquals(listOf("q", "Answer"), both.texts())
        assertEquals("the draft still means more may come", 1, both.typing())
        val settled = rows(state(question, message(2, "agent", "Answer"), draft("Answer", ended = true)))
        assertEquals(listOf("q", "Answer"), settled.texts())
        assertEquals(0, settled.typing())
    }

    @Test fun `a failed reply shows its error, never the partial draft`() {
        val error = ParticipantStatus("ptp_1", "error", "failed", "Model quota exceeded", null, null)
        val failed = rows(state(question, draft("Half an ans"), participant = error, awaiting = true))
        assertTrue(failed.none { it.text.contains("Half") })
        assertEquals(0, failed.typing())
        assertEquals(TimelineBlockKinds.REPLY_ERROR, failed.last().cardKind)
    }

    @Test fun `a cancelled reply stops waiting and leaves nothing half written`() {
        val cancelled = rows(state(question, draft("Half an ans", ended = true),
            participant = active.copy(state = "stopped")))
        assertEquals(listOf("q"), cancelled.texts())
        assertEquals(0, cancelled.typing())
        assertTrue(cancelled.none { it.cardKind == LiveRowKinds.REPLY_ACTIONS_RESERVED })
    }

    @Test fun `while the connection is down the bubble waits instead of spinning`() {
        for (problem in listOf(ConversationProblem.NETWORK, ConversationProblem.SERVER)) {
            val offline = rows(state(question, draft("Half"), participant = active, awaiting = true,
                connection = Connection.RECONNECTING, problem = problem))
            assertEquals(0, offline.typing())
            assertEquals(listOf("q"), offline.texts())
        }
        val stopped = rows(state(question, participant = active, connection = Connection.PAUSED,
            problem = ConversationProblem.UNAUTHORIZED))
        assertEquals(0, stopped.typing())
        // Back online, the snapshot's state decides again.
        assertEquals(1, rows(state(question, draft("Half"), participant = active)).typing())
        // A planned reconnect, or a cache that cannot be written, is not being cut off.
        assertEquals(1, rows(state(question, participant = active, connection = Connection.RECONNECTING)).typing())
        assertEquals(1, rows(state(question, participant = active, problem = ConversationProblem.STORAGE)).typing())
    }

    @Test fun `a send waiting offline keeps its own pending state`() {
        val pending = TimelineEntry.Pending("r:req-2", PendingMessage("req-2", "later", emptyList(), null, 5,
            PendingStatus.SENDING))
        val offline = rows(state(question, pending, awaiting = true, connection = Connection.RECONNECTING,
            problem = ConversationProblem.NETWORK))
        assertEquals(0, offline.typing())
        assertEquals(MessageStatus.PENDING, offline.single { it.text == "later" }.status)
    }

    @Test fun `switching to another conversation drops the bubble of the one before`() {
        val waiting = rows(state(question, draft("Half"), participant = active))
        assertEquals(1, waiting.typing())
        val other = rows(state(message(7, "user", "elsewhere", requestId = "req-7"), message(8, "agent", "done"),
            conversation = "cnv_2"))
        assertEquals(0, other.typing())
        assertTrue(other.all { it.conversationId == "cnv_2" })
        assertTrue(other.none { row -> waiting.any { it.id == row.id && it.cardKind == null } })
    }

    @Test fun `system messages and history gaps are status lines, not agent bubbles`() {
        val rows = rows(state(question, TimelineEntry.Gap("gap:5"), message(5, "agent", "after the gap"),
            message(6, "system", "Workspace is ready")))
        val gap = rows.single { it.id == rowId("gap:5") }
        assertEquals(ChatRole.SYSTEM, gap.role)
        assertEquals(ChatRole.SYSTEM, rows.single { it.text == "Workspace is ready" }.role)
        assertEquals(ChatRole.AGENT, rows.single { it.text == "after the gap" }.role)
        // Nothing the system says is copied as the reply.
        val copied = replyText(state(question, message(2, "agent", "Answer"), message(3, "system", "Workspace is ready")),
            "r:req-1")
        assertEquals("Answer", copied)
        assertFalse(rows.any { it.role == ChatRole.SYSTEM && it.cardKind == LiveRowKinds.REPLY_ACTIONS })
    }
}
