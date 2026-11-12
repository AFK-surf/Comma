package surf.comma.android.chat.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.conversation.CHAT
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.display
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.conversation.message

/** An unread gap separates turns: replies after it belong to no turn before it until it fills. */
class HistoryGapTurnTest {
    private fun entry(seq: Long, actor: String, text: String): TimelineEntry.Message {
        val display = display(message(seq, actor = actor, text = text))!!
        return TimelineEntry.Message(display.clientRequestId?.let { "r:$it" } ?: "m:${display.messageId}", display)
    }

    private val before = listOf(entry(1, "user", "Old question"), entry(2, "agent", "Old answer"))
    private val after = listOf(entry(132, "agent", "Answer to an unread question"), entry(133, "user", "New question"),
        entry(134, "agent", "New answer"))
    private val unread = listOf(entry(131, "user", "Unread question"))

    private fun state(vararg parts: List<TimelineEntry>) = ConversationState(conversationId = CHAT, timeline = parts.flatMap { it })
    private fun replyTurns(state: ConversationState) = mapConversation(state).rows
        .filter { it.role == ChatRole.AGENT }.map { it.turnId }

    @Test fun `replies on each side of a gap have their own ids and turns`() {
        val gapped = state(before, listOf(TimelineEntry.Gap("gap:132")), after)
        val rows = mapConversation(gapped).rows
        assertEquals("duplicate row ids", rows.size, rows.map { it.id }.toSet().size)
        assertEquals(listOf("r:req-1", "gap:132", "r:req-133"), replyTurns(gapped))
        val gap = rows.single { it.role == ChatRole.SYSTEM }
        assertEquals("gap:132", gap.turnId)
        assertEquals("gap:132", rows.single { it.text == "Answer to an unread question" }.turnId)
    }

    @Test fun `once the gap fills, the reply joins the question it answers`() {
        val filled = state(before, unread, after)
        assertTrue(mapConversation(filled).rows.none { it.role == ChatRole.SYSTEM })
        assertEquals(listOf("r:req-1", "r:req-131", "r:req-133"), replyTurns(filled))
        // The messages themselves keep their rows; only their turn changes.
        val gapped = mapConversation(state(before, listOf(TimelineEntry.Gap("gap:132")), after))
        val joined = mapConversation(filled)
        for (key in listOf("r:req-1", "m:msg_test_2", "m:msg_test_132", "r:req-133", "m:msg_test_134")) {
            assertEquals(key, gapped.entryRows[key], joined.entryRows[key])
        }
    }

    @Test fun `two gaps give three separate turns`() {
        val twice = state(before, listOf(TimelineEntry.Gap("gap:132")), after.take(1),
            listOf(TimelineEntry.Gap("gap:232")), listOf(entry(232, "agent", "Later answer")))
        val rows = mapConversation(twice).rows
        assertEquals(rows.size, rows.map { it.id }.toSet().size)
        assertEquals(listOf("r:req-1", "gap:132", "gap:232"), replyTurns(twice))
    }
}
