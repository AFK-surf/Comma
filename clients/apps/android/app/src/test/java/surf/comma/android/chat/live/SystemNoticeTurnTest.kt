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
 * on both sides are one reply with one set of buttons that copies all of it. A gap still splits
 * turns. Invented test data only.
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

    private fun rows(state: ConversationState) = mapConversation(state, replyActions = true).rows
    private fun List<ChatMessage>.kinds() = map { it.cardKind ?: it.role.name }
    private fun assertUniqueIds(rows: List<ChatMessage>) {
        val duplicates = rows.groupBy { it.id }.filterValues { it.size > 1 }
        assertTrue("Duplicate stable row IDs: $duplicates", duplicates.isEmpty())
    }

    @Test fun `a system notice between two answers must not duplicate stable row ids`() {
        assertUniqueIds(rows(state(question, first, notice, second)))
    }

    @Test fun `a system notice must not duplicate the same full-reply copy button`() {
        val conversation = state(question, first, notice, second)
        val actions = rows(conversation).filter { it.cardKind == LiveRowKinds.REPLY_ACTIONS }
        val copied = actions.map { replyText(conversation, requireNotNull(it.cardPayload)) }
        assertEquals("Repeated controls copy the same full reply: $copied", copied.size, copied.distinct().size)
    }

    @Test fun `both answers are one reply, with one button after the second that copies both`() {
        val conversation = state(question, first, notice, second)
        val rows = rows(conversation)
        assertEquals(listOf("USER", "AGENT", "SYSTEM", "AGENT", LiveRowKinds.REPLY_ACTIONS), rows.kinds())
        val actions = rows.single { it.cardKind == LiveRowKinds.REPLY_ACTIONS }
        assertEquals(rows[3].turnId, actions.turnId)
        assertEquals(rows[1].turnId, actions.turnId)
        assertEquals("First answer\n\nSecond answer", replyText(conversation, actions.cardPayload!!))
    }

    @Test fun `a notice after the last answer leaves the button under the answer`() {
        val conversation = state(question, first, notice)
        val rows = rows(conversation)
        assertEquals(listOf("USER", "AGENT", LiveRowKinds.REPLY_ACTIONS, "SYSTEM"), rows.kinds())
        assertEquals("First answer", replyText(conversation, rows[2].cardPayload!!))
    }

    @Test fun `while the reply goes on after a notice, only its reserved room shows`() {
        val draft = ReplyDraft("resp-1", listOf("msg_test_1"), "d1", 2, "Sec", false).let { TimelineEntry.Draft(it.key, it) }
        val waiting = rows(state(question, first, notice, draft, participant = active))
        assertEquals(listOf("USER", "AGENT", "SYSTEM", TimelineBlockKinds.LIVE_STATUS, LiveRowKinds.REPLY_ACTIONS_RESERVED),
            waiting.kinds())
        assertUniqueIds(waiting)
        // The second answer lands and the agent stops: the room becomes the one set of buttons.
        val done = rows(state(question, first, notice, second))
        assertEquals(1, done.count { it.cardKind == LiveRowKinds.REPLY_ACTIONS })
        assertTrue(done.none { it.cardKind == LiveRowKinds.REPLY_ACTIONS_RESERVED })
        assertUniqueIds(done)
    }

    @Test fun `a notice followed by a failed reply gives one error card and one button`() {
        val error = ParticipantStatus("ptp_1", "error", "failed", "Model quota exceeded", null, null)
        val conversation = state(question, first, notice, participant = error, awaiting = true)
        val rows = rows(conversation)
        assertEquals(listOf("USER", "AGENT", "SYSTEM", TimelineBlockKinds.REPLY_ERROR, LiveRowKinds.REPLY_ACTIONS), rows.kinds())
        assertUniqueIds(rows)
        assertEquals("First answer", replyText(conversation, rows.last().cardPayload!!))
        assertTrue(rows.none { it.cardKind == TimelineBlockKinds.LIVE_STATUS })
    }

    @Test fun `a gap still splits the reply around it, each half with its own button`() {
        val conversation = state(question, first, TimelineEntry.Gap("gap:4"), second, notice)
        val rows = rows(conversation)
        val actions = rows.filter { it.cardKind == LiveRowKinds.REPLY_ACTIONS }
        assertEquals(2, actions.size)
        assertUniqueIds(rows)
        assertEquals(listOf("First answer", "Second answer"), actions.map { replyText(conversation, it.cardPayload!!) })
    }

    @Test fun `notices before the first question keep one button for the agent rows around them`() {
        val opening = entry(2, "agent", "Hello")
        val later = entry(4, "agent", "Anything else?")
        val conversation = state(opening, notice, later)
        val rows = rows(conversation)
        assertUniqueIds(rows)
        assertEquals(1, rows.count { it.cardKind == LiveRowKinds.REPLY_ACTIONS })
        assertEquals(LiveRowKinds.REPLY_ACTIONS, rows.last().cardKind)
    }
}
