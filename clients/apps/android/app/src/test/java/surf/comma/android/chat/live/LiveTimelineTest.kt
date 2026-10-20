package surf.comma.android.chat.live

import surf.comma.android.conversation.replyOf
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.chat.render.MessageActionLabels
import surf.comma.android.chat.render.messageActionsFor
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.display
import surf.comma.android.conversation.ParticipantStatus
import surf.comma.android.conversation.PendingMessage
import surf.comma.android.conversation.PendingStatus
import surf.comma.android.conversation.ReplyDraft
import surf.comma.android.conversation.TimelineEntry

// Invented test data only.
class LiveTimelineTest {
    private fun block(type: String, configure: JSONObject.() -> Unit = {}) = JSONObject().put("type", type).apply(configure)
    private fun text(value: String) = block("text") { put("text", value) }

    private fun canonical(seq: Long, actor: String, vararg content: JSONObject, requestId: String? = null,
                          configure: JSONObject.() -> Unit = {}): TimelineEntry? {
        val json = JSONObject().put("message_id", "msg_$seq").put("seq", seq).put("actor_type", actor)
            .put("content", JSONArray(content.toList())).put("created_at", 1_700_000_000_000L + seq)
            .apply { requestId?.let { put("client_request_id", it) }; if (actor == "agent") put("agent_id", "agt_1") }
            .apply(configure)
        val display = display(json) ?: return null
        return TimelineEntry.Message(display.clientRequestId?.let { "r:$it" } ?: "m:${display.messageId}", display)
    }

    private fun pending(id: String, text: String, status: PendingStatus) =
        TimelineEntry.Pending("r:$id", PendingMessage(id, text, emptyList(), null, 5, status))

    private fun draft(text: String, ended: Boolean = false, draftId: String = "d1") = ReplyDraft("resp-1",
        listOf("msg_1"), draftId, 3, text, ended).let { TimelineEntry.Draft(it.key, it) }

    private fun state(vararg entries: TimelineEntry?, participant: ParticipantStatus? = null, awaiting: Boolean = false) =
        ConversationState(conversationId = "cnv_1", timeline = entries.filterNotNull(), participant = participant,
            reply = replyOf(participant, awaiting, entries.filterNotNull()))

    @Test fun `messages map to rows with roles, turns and design text`() {
        val rows = mapConversation(state(
            canonical(1, "user", text("hello"), requestId = "req-1"),
            canonical(2, "agent", text("**hi** there")),
        )).rows
        assertEquals(listOf(ChatRole.USER, ChatRole.AGENT), rows.map { it.role })
        assertEquals(listOf("hello", "hi there"), rows.map { it.text }) // A row says its words: the core parsed the Markdown.
        assertEquals(rows[0].turnId, rows[1].turnId)
        assertEquals(rowId("r:req-1#p0"), rows[0].id)
        assertEquals(rowId("m:msg_2#p0"), rows[1].id)
    }

    @Test fun `pending keeps its row id when it becomes the canonical message`() {
        // A send on its way also brings the typing bubble after it.
        val sending = mapConversation(state(pending("req-9", "hi", PendingStatus.SENDING))).rows.first()
        val confirmed = mapConversation(state(canonical(1, "user", text("hi"), requestId = "req-9"))).rows.single()
        assertEquals(sending.id, confirmed.id)
        assertEquals(MessageStatus.PENDING, sending.status)
        assertEquals(MessageStatus.COMPLETED, confirmed.status)
        assertEquals(sending.turnId, confirmed.turnId)
    }

    private val question get() = canonical(1, "user", text("q"), requestId = "req-1")
    private val active = ParticipantStatus("ptp_1", "active", "is searching the web", null, null, null)

    private fun assertTypingBubbleOnly(rows: List<surf.comma.android.chat.model.ChatMessage>) {
        val bubble = rows.single { it.cardKind == TimelineBlockKinds.LIVE_STATUS }
        assertEquals(rows.last(), bubble)
        assertEquals(ChatRole.AGENT, bubble.role)
        assertEquals("the waiting row carries no status text", "", bubble.text)
        assertNull(bubble.cardPayload)
    }

    @Test fun `a streamed draft is never shown, across reconnects or once it ends`() {
        val first = mapConversation(state(question, draft("Hel")))
        val reconnected = mapConversation(state(question, draft("Hello", draftId = "d2")))
        val ended = mapConversation(state(question, draft("Hello", ended = true)))
        listOf(first, reconnected, ended).forEach { timeline ->
            assertTrue(timeline.rows.none { it.text.startsWith("Hel") })
            assertTrue(timeline.rows.none { it.status == MessageStatus.STREAMING })
        }
        assertTypingBubbleOnly(first.rows.drop(1))
        assertEquals("the same bubble across a reconnect", first.rows, reconnected.rows)
        assertEquals("an ended draft on its own shows nothing", listOf("q"), ended.rows.map { it.text })
    }

    @Test fun `every waiting state shows the typing bubble and no status text`() {
        // Sent, no reply yet.
        assertTypingBubbleOnly(mapConversation(state(pending("req-2", "q", PendingStatus.SENDING), awaiting = true)).rows)
        // The agent is active, whatever it reports doing.
        assertTypingBubbleOnly(mapConversation(state(question, participant = active)).rows)
        assertTypingBubbleOnly(mapConversation(state(question, participant = active.copy(status = "is working"))).rows)
        // A draft has started without text.
        assertTypingBubbleOnly(mapConversation(state(question, draft(""))).rows)
        assertTypingBubbleOnly(mapConversation(state(question, draft("  \n"), participant = active)).rows)
    }

    @Test fun `the typing bubble keeps one row id across the waiting states`() {
        val awaiting = mapConversation(state(question, awaiting = true)).rows.last()
        val working = mapConversation(state(question, participant = active)).rows.last()
        val drafting = mapConversation(state(question, draft(""), participant = active)).rows.last()
        assertEquals(awaiting, working)
        assertEquals(awaiting, drafting)
    }

    @Test fun `the typing bubble stays while the draft streams, and leaves when the message lands or the agent stops`() {
        val streaming = mapConversation(state(question, draft("Answer"), participant = active, awaiting = true)).rows
        assertTypingBubbleOnly(streaming.drop(1))
        assertTrue(streaming.none { it.text == "Answer" })
        val landed = mapConversation(state(question, canonical(2, "agent", text("Answer")),
            participant = active.copy(state = "stopped"))).rows
        assertTrue(landed.none { it.cardKind == TimelineBlockKinds.LIVE_STATUS })
        assertEquals("Answer", landed.last().text)
        val stopped = mapConversation(state(question, participant = active.copy(state = "stopped"))).rows
        assertTrue(stopped.none { it.cardKind == TimelineBlockKinds.LIVE_STATUS })
        val ended = mapConversation(state(question, draft("", ended = true))).rows
        assertTrue(ended.none { it.cardKind == TimelineBlockKinds.LIVE_STATUS })
    }

    @Test fun `an agent its own loop woke shows no typing bubble under a finished reply`() {
        // The participant frame the server sends when the agent's loop, not a message, wakes it.
        val woke = active.copy(status = "is thinking...", loopWake = true)
        val replied = state(question, canonical(2, "agent", text("done")), participant = woke)
        val rows = mapConversation(replied, replyActions = true).rows
        assertTrue("no typing bubble", rows.none { it.cardKind == TimelineBlockKinds.LIVE_STATUS })
        assertEquals("the finished reply keeps its actions", LiveRowKinds.REPLY_ACTIONS, rows.last().cardKind)
        assertFalse(isGenerating(replied))
        // Without the loop wake the agent is working on a message, and the bubble stays.
        assertTypingBubbleOnly(mapConversation(state(question, participant = woke.copy(loopWake = false))).rows)
    }

    @Test fun `failed send keeps its row and maps back to its original request id`() {
        val sending = mapConversation(state(pending("req-fail", "hello", PendingStatus.SENDING)))
        val timeline = mapConversation(state(pending("req-fail", "hello", PendingStatus.FAILED)))
        val row = timeline.rows.single()
        assertEquals(sending.rows.first().id, row.id)
        assertEquals(MessageStatus.FAILED, row.status)
        assertEquals("req-fail", timeline.retryTargets[row.id])
        // No buttons: the failure mark and note beside the bubble open the options.
        assertTrue(messageActionsFor(row, MessageActionLabels()).isEmpty())
        assertTrue(sending.retryTargets.isEmpty())
    }

    @Test fun `a participant error becomes one reply error card with its issue`() {
        val error = ParticipantStatus("ptp_1", "error", "failed", "Model quota exceeded\nstack trace line", null, null)
        val rows = mapConversation(state(canonical(1, "user", text("q"), requestId = "req-1"), participant = error)).rows
        val card = rows.last()
        assertEquals(TimelineBlockKinds.REPLY_ERROR, card.cardKind)
        assertEquals("回复出错了", card.text)
        assertEquals("Model quota exceeded", card.cardPayload)
        assertFalse(card.retryable)
        assertTrue(rows.none { it.cardKind == TimelineBlockKinds.LIVE_STATUS })
        val withoutIssue = mapConversation(state(canonical(1, "user", text("q"), requestId = "req-1"),
            participant = error.copy(issue = null))).rows.last()
        assertEquals("请稍后再试。", withoutIssue.cardPayload)
        assertTrue(messageActionsFor(card, MessageActionLabels()).isEmpty())
    }

    @Test fun `a system message is a status line, not an agent bubble`() {
        val rows = mapConversation(state(canonical(6, "system", text("Workspace is ready")))).rows
        assertEquals(listOf("Workspace is ready"), rows.map { it.text })
        assertEquals(ChatRole.SYSTEM, rows.single().role)
    }

    @Test fun `task references, attachments and interactive content become their own rows in order`() {
        val entry = canonical(2, "agent",
            text("Created "),
            block("conversation_ref") { put("presentation", "inline"); put("kind", "agent_task"); put("conversation_id", "cnv_task") },
            text(" for you."),
            block("dynamic_ui") { put("summary", "A chart of sales") },
            block("image") { put("file_name", "chart.png"); put("width", 800); put("height", 400) },
            block("file") { put("path", "/files/report.pdf") },
        )
        val rows = mapConversation(state(entry)).rows
        assertEquals(listOf(null, LiveRowKinds.TASK_REF, null, LiveRowKinds.INTERACTIVE_SUMMARY, LiveRowKinds.ATTACHMENT,
            LiveRowKinds.ATTACHMENT), rows.map { it.cardKind })
        assertEquals("Created", rows[0].text)
        assertEquals("for you.", rows[2].text)
        assertEquals("A chart of sales", rows[3].text)
        val task = LiveRowKinds.decodeTask(rows[1].cardPayload)
        assertEquals("cnv_task", task.conversationId)
        assertFalse(task.unavailable)
        val image = LiveRowKinds.decodeAttachment(rows[4].cardPayload)
        assertFalse(image.image) // No source: an unavailable file card, even with image dimensions.
        assertEquals(800, image.widthPx)
        assertEquals(400, image.heightPx)
        val file = LiveRowKinds.decodeAttachment(rows[5].cardPayload)
        assertFalse(file.image)
        assertEquals("report.pdf", file.name)
        assertEquals(rows.size, rows.map { it.id }.toSet().size)
    }

    @Test fun `punctuation after an inline task chip stays on the chip's line`() {
        fun chip(id: String) = block("conversation_ref") {
            put("presentation", "inline"); put("kind", "agent_task"); put("conversation_id", id)
        }
        val rows = mapConversation(state(canonical(2, "agent", text("Created "), chip("cnv_a"), text(". Next, "),
            chip("cnv_b"), text("），然后"), chip("cnv_c"), text(".")))).rows
        assertEquals(listOf(null, LiveRowKinds.TASK_REF, null, LiveRowKinds.TASK_REF, null, LiveRowKinds.TASK_REF),
            rows.map { it.cardKind })
        assertEquals(listOf("Created", "", "Next,", "", "然后", ""), rows.map { it.text })
        assertEquals(listOf(".", "），", "."), rows.filter { it.cardKind == LiveRowKinds.TASK_REF }
            .map { LiveRowKinds.decodeTask(it.cardPayload).suffix })
        // The chip keeps everything else it carried.
        assertEquals("cnv_b", LiveRowKinds.decodeTask(rows[3].cardPayload).conversationId)
    }

    @Test fun `only closing punctuation attaches to a chip`() {
        val chip = block("conversation_ref") {
            put("presentation", "inline"); put("kind", "agent_task"); put("conversation_id", "cnv_a")
        }
        val spaced = mapConversation(state(canonical(2, "agent", chip, text(" (draft)")))).rows
        assertEquals("", LiveRowKinds.decodeTask(spaced[0].cardPayload).suffix)
        assertEquals("(draft)", spaced[1].text)
        val opening = mapConversation(state(canonical(3, "agent", chip, text("(draft)")))).rows
        assertEquals("", LiveRowKinds.decodeTask(opening[0].cardPayload).suffix)
        assertEquals("(draft)", opening[1].text)
        assertEquals(3, attachedPunctuationLength("?!) and more"))
        assertEquals(0, attachedPunctuationLength("word."))
    }

    @Test fun `a task payload without a suffix still decodes`() {
        val legacy = listOf("cnv_a", "Title", "done", "0").joinToString("\u001F")
        val task = LiveRowKinds.decodeTask(legacy)
        assertEquals("cnv_a", task.conversationId)
        assertEquals("", task.suffix)
    }

    @Test fun `structured attachments route to images videos and files and preserve original block identities`() {
        val ref = JSONObject().put("kind", "blob").put("uuid", "a".repeat(32)).put("hash", "b".repeat(64)).put("size", 200)
        val entry = canonical(4, "agent", text("Here"),
            block("image") { put("file_name", "photo.png"); put("mime_type", "image/png"); put("blob_ref", ref); put("width", 800); put("height", 400) },
            block("file") { put("file_name", "clip.webm"); put("mime_type", "video/webm"); put("blob_ref", ref) },
            block("file") { put("file_name", "page.svg"); put("mime_type", "image/svg+xml"); put("blob_ref", ref) },
            block("image") { put("file_name", "mismatch.jpg"); put("mime_type", "image/png"); put("blob_ref", ref) },
            block("file") { put("file_name", "big.mp4"); put("blob_ref", ref); put("size", 10000001) },
            block("file") { put("file_name", "workspace.pdf"); put("path", "/reports/workspace.pdf") },
        )
        val rows = mapConversation(state(entry)).rows.drop(1)
        assertEquals(listOf("IMAGE", "VIDEO", "FILE", "FILE", "VIDEO", "FILE"), rows.map { it.attachment!!.display.name })
        val image = rows[0].attachment!!
        assertEquals(surf.comma.android.media.ImageDimensions(800, 400), image.dimensions)
        assertEquals(1, image.gallery.size)
        assertEquals(0, image.galleryIndex)
        assertEquals(rowId("m:msg_4#a1"), rows[0].id)
        assertEquals(rowId("m:msg_4#a2"), rows[1].id)
        assertTrue(image.file.source is surf.comma.android.media.MediaSource.AgentResource)
        assertNull(rows.last().attachment!!.file.source)
    }

    @Test fun `interactive content without a summary says it is unavailable`() {
        val rows = mapConversation(state(canonical(2, "agent", block("dynamic_ui") { put("ui_ref", "u1") }))).rows
        assertEquals("交互内容暂不可用", rows.single().text)
    }

    @Test fun `generating follows the live draft and the participant`() {
        assertTrue(isGenerating(state(draft("x"))))
        assertFalse(isGenerating(state(draft("x", ended = true))))
        assertTrue(isGenerating(state(participant = ParticipantStatus("p", "active", null, null, null, null))))
        assertFalse(isGenerating(state(pending("req-1", "q", PendingStatus.SENDING))))
    }

    private fun kinds(timeline: LiveTimeline) = timeline.rows.map { it.cardKind }

    @Test fun `a finished reply of several messages gets one action row, after its last message`() {
        val chip = block("conversation_ref") {
            put("presentation", "inline"); put("kind", "agent_task"); put("conversation_id", "cnv_a"); put("title", "Draft")
        }
        val st = state(
            canonical(1, "user", text("q1"), requestId = "req-1"),
            canonical(2, "agent", text("First "), chip, text(".")),
            canonical(3, "agent", text("```kt\nval x = 1\n```")),
            canonical(4, "user", text("q2"), requestId = "req-2"),
            canonical(5, "agent", text("Second")),
        )
        val timeline = mapConversation(st, replyActions = true)
        assertEquals(listOf(null, null, LiveRowKinds.TASK_REF, null, LiveRowKinds.REPLY_ACTIONS, null, null,
            LiveRowKinds.REPLY_ACTIONS), kinds(timeline))
        val actions = timeline.rows.filter { it.cardKind == LiveRowKinds.REPLY_ACTIONS }
        assertEquals(listOf("r:req-1", "r:req-2"), actions.map { it.cardPayload })
        assertEquals(timeline.rows[1].turnId, actions[0].turnId)
        assertEquals(ChatRole.AGENT, actions[0].role)
        // The whole reply, as markdown source, one message per block.
        assertEquals("First Draft.\n\n```kt\nval x = 1\n```", replyText(st, "r:req-1"))
        assertEquals("Second", replyText(st, "r:req-2"))
        // Without the option (the task page) nothing is added.
        assertEquals(listOf(null, null, LiveRowKinds.TASK_REF, null, null, null), kinds(mapConversation(st)))
    }

    @Test fun `user messages and replies without text get no action row`() {
        val ref = block("conversation_ref") {
            put("presentation", "inline"); put("kind", "agent_task"); put("conversation_id", "cnv_a")
        }
        val rows = mapConversation(state(
            canonical(1, "user", text("q"), requestId = "req-1"),
            canonical(2, "agent", ref),
            canonical(3, "user", text("unanswered"), requestId = "req-3"),
        ), replyActions = true).rows
        assertTrue(rows.none { it.cardKind == LiveRowKinds.REPLY_ACTIONS || it.cardKind == LiveRowKinds.REPLY_ACTIONS_RESERVED })
    }

    @Test fun `a reply on its way reserves the action row, which then arrives under its own id`() {
        val user = canonical(1, "user", text("q"), requestId = "req-1")
        val thinking = mapConversation(state(user, awaiting = true), replyActions = true)
        assertEquals(listOf(null, TimelineBlockKinds.LIVE_STATUS, LiveRowKinds.REPLY_ACTIONS_RESERVED), kinds(thinking))
        val streaming = mapConversation(state(user, draft("Hel")), replyActions = true)
        assertEquals("a streaming draft looks like waiting", thinking.rows, streaming.rows)
        assertEquals("", streaming.rows.last().text)
        // A draft the server ended is not the reply: nothing to show, copy or act on.
        val ended = state(user, draft("Hello", ended = true))
        assertEquals(listOf<String?>(null), kinds(mapConversation(ended, replyActions = true)))
        assertEquals("", replyText(ended, "r:req-1"))
        val landed = mapConversation(state(user, canonical(2, "agent", text("Hello"))), replyActions = true)
        assertEquals(listOf(null, null, LiveRowKinds.REPLY_ACTIONS), kinds(landed))
        assertFalse(landed.rows.last().id == streaming.rows.last().id)
        assertEquals("Hello", replyText(state(user, canonical(2, "agent", text("Hello"))), "r:req-1"))
    }

    @Test fun `an earlier reply keeps its action row while the next one is on its way`() {
        val rows = mapConversation(state(
            canonical(1, "user", text("q1"), requestId = "req-1"),
            canonical(2, "agent", text("a1")),
            canonical(3, "user", text("q2"), requestId = "req-3"),
            draft("a2"),
        ), replyActions = true).rows
        assertEquals(listOf(null, null, LiveRowKinds.REPLY_ACTIONS, null, TimelineBlockKinds.LIVE_STATUS,
            LiveRowKinds.REPLY_ACTIONS_RESERVED), rows.map { it.cardKind })
    }

    @Test fun `every message row knows the entry it came from, with that entry's whole text`() {
        val chip = block("conversation_ref") {
            put("presentation", "inline"); put("kind", "agent_task"); put("conversation_id", "cnv_a"); put("title", "Plan")
        }
        val st = state(
            canonical(1, "user", text("hello"), requestId = "req-1"),
            canonical(2, "agent", text("Made "), chip, text(" for you.")),
            pending("req-3", "  later  ", PendingStatus.SENDING),
        )
        val timeline = mapConversation(st)
        val entries = timeline.rows.map { timeline.rowEntries[it.id] }
        // The typing bubble after the send on its way comes from no entry.
        assertEquals(listOf("r:req-1", "m:msg_2", "m:msg_2", "m:msg_2", "r:req-3", null), entries)
        assertEquals("Made Plan for you.", entryText(st, "m:msg_2"))
        assertEquals("later", entryText(st, "r:req-3"))
        assertNull(entryText(st, "m:missing"))
    }

    @Test fun `rows from elsewhere get the same buttons, reserved while the last one streams`() {
        fun row(id: Long, turn: String, role: ChatRole, text: String, status: MessageStatus = MessageStatus.COMPLETED) =
            surf.comma.android.chat.model.ChatMessage(id = id, conversationId = "c", turnId = turn, role = role, text = text,
                createdAt = 0L, status = status)
        val history = listOf(row(1, "", ChatRole.AGENT, "hello"), row(2, "t1", ChatRole.USER, "q"),
            row(3, "t1", ChatRole.AGENT, "a"), row(4, "t2", ChatRole.USER, "q2"))
        val streaming = withReplyActions(history + row(5, "t2", ChatRole.AGENT, "b", MessageStatus.STREAMING))
        assertEquals(listOf(null, LiveRowKinds.REPLY_ACTIONS, null, null, LiveRowKinds.REPLY_ACTIONS, null, null,
            LiveRowKinds.REPLY_ACTIONS_RESERVED), streaming.map { it.cardKind })
        assertEquals(streaming.size, streaming.map { it.id }.toSet().size)
        val done = withReplyActions(history + row(5, "t2", ChatRole.AGENT, "b"))
        assertEquals(LiveRowKinds.REPLY_ACTIONS, done.last().cardKind)
        assertEquals("t2", done.last().cardPayload)
    }
}
