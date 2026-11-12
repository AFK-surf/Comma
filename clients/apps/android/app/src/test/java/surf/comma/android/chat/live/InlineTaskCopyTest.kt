package surf.comma.android.chat.live

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import surf.comma.android.chat.render.MarkdownTree
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.MessagePart
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.conversation.display
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.ui.KnownTasks

class InlineTaskCopyTest {
    private val title = "Ship the report"
    private val labels = LiveLabels(task = "Unnamed fixture", taskUnavailable = "Unavailable fixture")
    private val known = KnownTasks(summaries = mapOf("cnv_a" to TaskSummary("cnv_a", title, TaskStatusBucket.IN_PROGRESS)))

    private fun message(standalone: Boolean = false): surf.comma.android.conversation.ChatMessage {
        val content = JSONArray()
        if (!standalone) content.put(JSONObject().put("type", "text").put("text", "见 "))
        content.put(JSONObject().put("type", "conversation_ref").put("presentation", "inline")
            .put("kind", "agent_task").put("conversation_id", "cnv_a"))
        if (!standalone) content.put(JSONObject().put("type", "text").put("text", "。"))
        return requireNotNull(display(JSONObject().put("message_id", "msg_2").put("seq", 2)
            .put("actor_type", "agent").put("agent_id", "agt_1").put("content", content)))
    }

    private fun assertCopies(message: surf.comma.android.conversation.ChatMessage, tasks: KnownTasks, expected: String) {
        for (shown in listOf(message, message.copy(markdown = null))) {
            val state = ConversationState(conversationId = "cnv_1", timeline = listOf(TimelineEntry.Message("reply", shown)))
            val text = requireNotNull(entryText(state, "reply", tasks, labels))
            val selected = MarkdownTree.plainText(requireNotNull(entryBlocks(state, "reply", tasks, labels)))
            assertEquals(expected, text)
            assertEquals(expected, selected)
            assertFalse(text.contains("comma:task/"))
            assertFalse(selected.contains("comma:task/"))
        }
    }

    @Test fun `copy helpers use directory titles even when the server chip has no title`() {
        val message = message()
        assertNull(message.parts.filterIsInstance<MessagePart.TaskChip>().single().title)
        assertCopies(message, known, "见 $title。")
    }

    @Test fun `copy helpers share inline title fallbacks and unavailable text`() {
        val message = message()
        assertCopies(message, KnownTasks(), "见 ${labels.task}。")
        val titled = message.copy(parts = message.parts.map {
            if (it is MessagePart.TaskChip) it.copy(title = "Reference fixture") else it
        })
        assertCopies(titled, KnownTasks(), "见 Reference fixture。")
        assertCopies(titled, known, "见 $title。")
        assertCopies(message, KnownTasks(confirmed = setOf("cnv_a")), "见 ${labels.taskUnavailable}。")
    }

    @Test fun `standalone task copying uses the directory title when the server chip has no title`() {
        val message = message(standalone = true)
        assertNull(message.parts.filterIsInstance<MessagePart.TaskChip>().single().title)
        assertCopies(message, known, title)
        assertCopies(message, KnownTasks(), labels.task)
        val titled = message.copy(parts = message.parts.map {
            if (it is MessagePart.TaskChip) it.copy(title = "Reference fixture") else it
        })
        assertCopies(titled, KnownTasks(), "Reference fixture")
        assertCopies(titled, known, title)
        assertCopies(message, KnownTasks(confirmed = setOf("cnv_a")), labels.taskUnavailable)
    }
}
