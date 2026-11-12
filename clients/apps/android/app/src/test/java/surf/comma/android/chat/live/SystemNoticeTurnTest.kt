package surf.comma.android.chat.live

import surf.comma.android.conversation.replyOf
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.conversation.CHAT
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.display
import surf.comma.android.conversation.ParticipantStatus
import surf.comma.android.conversation.ReplyDraft
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.conversation.message

/**
 * A system notice inside a reply is a status line, not the end of the reply: the agent messages
 * on both sides are one turn. A gap still splits turns. Invented test data only.
 */
class SystemNoticeTurnTest {
    private fun entry(seq: Long, actor: String, text: String): TimelineEntry.Message {
        val display = display(message(seq, actor = actor, text = text))!!
        return TimelineEntry.Message(display.clientRequestId?.let { "r:$it" } ?: "m:${display.messageId}", display)
    }

    private fun state(vararg entries: TimelineEntry, participant: ParticipantStatus? = null, awaiting: Boolean = false) =
        ConversationState(conversationId = CHAT, timeline = entries.toList(), participant = participant,
            reply = replyOf(participant, awaiting, entries.toList()))

    private val question = entry(1, "user", "Question")
    private val first = entry(2, "agent", "First answer")
    private val notice = entry(3, "system", "Workspace ready")
    private val second = entry(4, "agent", "Second answer")
    private val active = ParticipantStatus("ptp_1", "active", null, null, null, null)

    private fun rows(state: ConversationState) = mapConversation(state).rows
    private fun List<ChatMessage>.kinds() = map { it.cardKind ?: it.role.name }
    private fun assertUniqueIds(rows: List<ChatMessage>) {
        val duplicates = rows.groupBy { it.id }.filterValues { it.size > 1 }
        assertTrue("Duplicate stable row IDs: $duplicates", duplicates.isEmpty())
    }

    @Test fun `a system notice between two answers must not duplicate stable row ids`() {
        assertUniqueIds(rows(state(question, first, notice, second)))
    }

    @Test fun `both answers are one reply, and the notice between them starts no turn`() {
        val rows = rows(state(question, first, notice, second))
        assertEquals(listOf("USER", "AGENT", "SYSTEM", "AGENT"), rows.kinds())
        assertEquals(rows[1].turnId, rows[3].turnId)
    }

    @Test fun `while the reply goes on after a notice, only the typing bubble shows`() {
        val draft = ReplyDraft("resp-1", listOf("msg_test_1"), "d1", 2, "Sec", false).let { TimelineEntry.Draft(it.key, it) }
        val waiting = rows(state(question, first, notice, draft, participant = active))
        assertEquals(listOf("USER", "AGENT", "SYSTEM", TimelineBlockKinds.LIVE_STATUS), waiting.kinds())
        assertUniqueIds(waiting)
        // The second answer lands and the agent stops: the bubble gives way to it.
        val done = rows(state(question, first, notice, second))
        assertTrue(done.none { it.cardKind == TimelineBlockKinds.LIVE_STATUS })
        assertUniqueIds(done)
    }

    @Test fun `a notice followed by a failed reply gives one error card and no typing bubble`() {
        val error = ParticipantStatus("ptp_1", "error", "failed", "Model quota exceeded", null, null)
        val rows = rows(state(question, first, notice, participant = error, awaiting = true))
        assertEquals(listOf("USER", "AGENT", "SYSTEM", TimelineBlockKinds.REPLY_ERROR), rows.kinds())
        assertUniqueIds(rows)
    }

    @Test fun `a gap still splits the reply around it into two turns`() {
        val rows = rows(state(question, first, TimelineEntry.Gap("gap:4"), second, notice))
        val answers = rows.filter { it.role == ChatRole.AGENT }
        assertEquals(2, answers.map { it.turnId }.distinct().size)
        assertUniqueIds(rows)
    }
}
