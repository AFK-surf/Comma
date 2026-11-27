package surf.comma.android.chat.live

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.conversation.display

// Invented test data only.
/**
 * In a Task together, another person's message is not the account's own: it sits on the left under their name, as
 * on desktop. It was drawn on the right as the account's own, because only user and Agent messages were told apart.
 */
class OtherWriterTimelineTest {
    private fun message(seq: Long, actor: String, words: String, writer: String? = null): TimelineEntry.Message {
        val json = JSONObject().put("message_id", "msg_$seq").put("seq", seq).put("actor_type", actor)
            .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", words)))
            .put("created_at", 1_700_000_000_000L + seq)
            .apply { if (actor == "agent") put("agent_id", "agt_1") }
        val shown = display(json)!!
        return TimelineEntry.Message("m:${shown.messageId}", shown.copy(createdBy = writer))
    }

    private fun rows(vararg entries: TimelineEntry, self: String? = "u1", task: Boolean = true) =
        mapConversation(ConversationState(conversationId = "cnv_1", timeline = entries.toList()),
            writers = MessageWriters(self, task) { id -> mapOf("u2" to WriterFace("Maya", """{"path":"maya.png"}"""))[id] }).rows

    @Test fun `another person's messages sit on the left under their name, their face beside the run's last`() {
        val rows = rows(
            message(1, "user", "mine", writer = "u1"),
            message(2, "user", "first of theirs", writer = "u2"),
            message(3, "user", "second of theirs", writer = "u2"),
            message(4, "user", "from someone unknown", writer = "u3"),
            message(5, "agent", "**hi** there"),
        )
        assertEquals(listOf(ChatRole.USER, ChatRole.AGENT, ChatRole.AGENT, ChatRole.AGENT, ChatRole.AGENT), rows.map { it.role })
        assertEquals(listOf(null, "Maya", "Maya", "Someone", null), rows.map { it.otherWriterName })
        assertEquals(listOf(false, true, false, true, false), rows.map { it.writerLabel })
        // Every left-side row of a Task has its speaker; the avatar closes each speaker's run, the Agent's included.
        assertEquals(listOf(null, "person:u2", "person:u2", "person:u3", "worker"), rows.map { it.speaker })
        assertEquals(listOf(false, false, true, true, true), rows.map { it.speakerAvatar })
        assertEquals(listOf(null, """{"path":"maya.png"}""", """{"path":"maya.png"}""", null, null), rows.map { it.otherWriterAvatar })
    }

    @Test fun `the Router chat's rows have no speaker gutter`() {
        val rows = rows(message(1, "user", "hi", writer = "current"), message(2, "agent", "**hi** there"), task = false)
        assertEquals(listOf(null, null), rows.map { it.speaker })
        assertEquals(listOf(false, false), rows.map { it.speakerAvatar })
    }

    @Test fun `the Router chat's current user and an unknown account are the account's own`() {
        assertEquals(ChatRole.USER, rows(message(1, "user", "hi", writer = "current")).single().role)
        val unknownSelf = rows(message(1, "user", "hi", writer = "u2"), self = null).single()
        assertEquals(ChatRole.USER, unknownSelf.role)
        assertNull(unknownSelf.otherWriterName)
    }
}
