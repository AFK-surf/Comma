package surf.comma.android.conversation

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the chat makes of the client core's `chatView` topic: its rows and their keys, and the calls the person's
 * actions become. The conversation itself (the stream, seq paging, gaps, what is kept, what a message shows) is the
 * core's and is tested there.
 */
class ChatViewTest {
    private val sessions = FakeSessions()
    private val core = FakeChatViewCore()
    private val view = ChatView(sessions, core, newRequestId = { "req-new-1" })

    @After fun after() = view.close()

    private suspend fun await(matches: (ConversationState) -> Boolean): ConversationState = view.state.first(matches)

    private suspend fun shown(): ConversationState {
        sessions.scopes.value = scope(1)
        view.start()
        view.setForeground(true)
        return await { it.cacheLoaded }
    }

    @Test fun `messages show in seq order with a gap between the ranges read`() = runBlocking {
        core.show(messages(1L..2L) + messages(7L..8L), listOf(1L..2L, 7L..8L))
        val state = shown()
        assertEquals(listOf("r:req-1", "m:msg_test_2", "gap:7", "r:req-7", "m:msg_test_8"), state.timeline.map { it.key })
        assertEquals(GROUP, state.groupId)
        assertEquals(Connection.LIVE, state.connection)
        assertTrue(view.isCurrent(state))
        val topic = core.subscribed.single()
        assertEquals(listOf("chatView", GROUP, CHAT, "android"),
            listOf("topic", "group", "conversation", "surface").map(topic::getString))
    }

    @Test fun `a message sent keeps its row when its canonical message replaces it`() = runBlocking {
        core.show(messages(1L..2L))
        shown()
        assertEquals("req-new-1", view.send("hello"))
        val pending = await { it.timeline.any { entry -> entry is TimelineEntry.Pending } }
        val row = pending.timeline.last() as TimelineEntry.Pending
        assertEquals("r:req-new-1", row.key)
        assertEquals(PendingStatus.FAILED, row.pending.status)
        assertEquals("No connection", row.pending.error)

        core.accept = true
        view.retry("req-new-1")
        val confirmed = await { it.timeline.none { entry -> entry is TimelineEntry.Pending } }
        assertEquals("r:req-new-1", confirmed.timeline.last().key)
        assertTrue(confirmed.timeline.last() is TimelineEntry.Message)
    }

    @Test fun `a file attached uploads in the draft and goes with the next message`() = runBlocking {
        core.show(emptyList())
        shown()
        val row = view.attach("photo.jpg", byteArrayOf(1, 2, 3))!!
        val attached = await { it.attachments.isNotEmpty() }.attachments.single()
        assertEquals(DraftAttachment(row, "photo.jpg", 3, DraftAttachmentStatus.UPLOADED, "/uploads/abcdefghijklmnopqrstuv-photo.jpg"), attached)
        val file = core.calls.single { it.first == "chatView.attach" }.second.getJSONArray("files").getJSONObject(0)
        assertEquals("AQID", file.getJSONObject("bytes").getString("\$bytes"))

        view.send("  look  ", clientRequestId = "req-photo")
        val sent = await { it.timeline.isNotEmpty() }
        val pending = (sent.timeline.single() as TimelineEntry.Pending).pending
        assertEquals("look", pending.text)
        assertEquals(listOf(WorkspaceFile("photo.jpg", "/uploads/abcdefghijklmnopqrstuv-photo.jpg")), pending.workspaceFiles)
        assertTrue(sent.attachments.isEmpty())
    }

    @Test fun `a file taken out of the draft is not sent`() = runBlocking {
        core.show(emptyList())
        shown()
        val row = view.attach("photo.jpg", byteArrayOf(1))!!
        view.removeAttachment(row)
        assertTrue(await { it.attachments.isEmpty() }.timeline.isEmpty())
        assertNull(view.send("   "))
    }

    @Test fun `nothing is sent without text, without a conversation, or when the draft may no longer go`() = runBlocking {
        assertNull(view.send("hello"))
        core.show(emptyList())
        shown()
        assertNull(view.send("   "))
        assertNull(view.send("hello", canSend = { false }))
        assertTrue(core.sends.isEmpty())
    }

    @Test fun `the streaming reply, the participant and what is awaited come from the topic`() = runBlocking {
        core.show(messages(1L..1L), fields = JSONObject()
            .put("assistantDraft", JSONObject().put("responseKey", "k1").put("sourceMessageIds", JSONArray().put("msg_test_1"))
                .put("draftId", "d1").put("revision", 2).put("text", "Hel").put("status", "streaming"))
            .put("participantStatus", JSONObject().put("participantId", "ptp_1").put("state", "active").put("status", "thinking")
                .put("loopWake", false))
            .put("reply", JSONObject().put("coming", true).put("streaming", true).put("working", true))
            .put("history", JSONObject().put("hasOlder", true).put("loadingOlder", false).put("ranges", JSONArray().put(JSONArray().put(1).put(1)))))
        val state = shown()
        val draft = (state.timeline.last() as TimelineEntry.Draft).draft
        assertEquals("Hel", draft.text)
        assertFalse(draft.ended)
        assertEquals(draftKey("k1", listOf("msg_test_1")), state.timeline.last().key)
        assertEquals("active", state.participant!!.state)
        assertEquals(ReplyState(coming = true, streaming = true, working = true), state.reply)
        assertTrue(state.hasOlder)
        assertEquals("Test chat", state.title)
    }

    @Test fun `a conversation the core cannot read says why`() = runBlocking {
        core.show(emptyList(), fields = JSONObject().put("status", "error").put("errorKind", "not-found").put("connection", "paused"))
        val state = shown()
        assertEquals(ConversationProblem.NOT_FOUND, state.problem)
        assertEquals(Connection.PAUSED, state.connection)
    }

    @Test fun `scrolling up, retrying a pause and a network change ask the core`() = runBlocking {
        core.show(messages(1L..1L))
        shown()
        view.loadOlder()
        view.reconnect()
        view.networkChanged(true)
        core.refreshes.first { it >= 2 }
        assertEquals(1, core.calls.count { it.first == "chatView.older" })
    }

    @Test fun `leaving the chat lets the conversation go, and another account never sees this one's rows`() = runBlocking {
        core.show(messages(1L..2L))
        val first = shown()
        view.setForeground(false)
        assertEquals(Connection.BACKGROUND, await { it.connection == Connection.BACKGROUND }.connection)

        sessions.scopes.value = scope(2, account = "usr_test_b")
        val next = await { it.scope?.generation == 2L }
        assertTrue(next.timeline.isEmpty())
        assertFalse(view.isCurrent(first))
        sessions.scopes.value = null
        assertNull(await { it.scope == null }.groupId)
    }

    @Test fun `a view of a task shows the conversation it is given`() = runBlocking {
        val task = ChatView(sessions, core, main = false)
        try {
            sessions.scopes.value = scope(1)
            task.start()
            task.setForeground(true)
            assertNull(task.state.value.conversationId)
            task.open("cnv_task")
            assertEquals("cnv_task", task.state.first { it.cacheLoaded }.conversationId)
            assertEquals("cnv_task", core.subscribed.single().getString("conversation"))
            task.open(null)
            assertNull(task.state.first { it.conversationId == null }.groupId)
        } finally {
            task.close()
        }
    }

    @Test fun `what a message shows comes from its parts, its attachments and the core's reading of it`() {
        val message = display(message(1, "user", "look"), shown("look", listOf(WorkspaceFile("a.png", "/uploads/a.png")))
            .put("quotes", org.json.JSONArray().put("first\n\nsecond")))!!
        assertEquals(listOf(MessagePart.Text("> first\n>\n> second"), MessagePart.Text("look")), message.parts)
        assertEquals(listOf(WorkspaceFile("a.png", "/uploads/a.png")), message.workspaceFiles)
        assertEquals("req-1", message.clientRequestId)

        val blob = JSONObject().put("uuid", "u".repeat(32)).put("hash", "h".repeat(64)).put("size", 9)
        val reply = display(message(2, "agent", "  Made ") {
            getJSONArray("content").put(JSONObject().put("type", "conversation_ref").put("presentation", "inline")
                .put("kind", "agent_task").put("conversation_id", "cnv_task").put("title", "Task"))
                .put(JSONObject().put("type", "image").put("file_name", "a.png").put("width", 4).put("height", 2).put("blob_ref", blob))
            put("metadata", JSONObject().put("message_type", "task_command"))
        })!!
        assertEquals(listOf(MessagePart.Text("Made "), MessagePart.TaskChip("cnv_task", "Task", null, null, false)), reply.parts)
        val image = reply.attachments.single()
        assertEquals(listOf(2, 4, 2), listOf(image.blockIndex, image.widthPx, image.heightPx))
        assertTrue(image.downloadable)
        assertEquals("agt_test_1", image.agentId)
        assertTrue(reply.brief)
        assertEquals(listOf("cnv_task"), reply.createdTaskIds)
        assertEquals("agent", reply.actorType)
        assertNull(display(message(3, "agent", "   ")))
    }

    @Test fun `a message that only attaches a text shows that text under its app's name`() {
        val texts = JSONArray().put(JSONObject().put("source", "Linear").put("text", "Review COMMA-1\n\nhttps://linear.app"))
            .put(JSONObject().put("text", "Reply to Dana"))
        // The core's parts hold the message's words, which a message of attached texts alone leaves empty.
        val message = display(message(1, "user", ""), shown("").put("texts", texts))!!
        assertEquals(listOf(MessagePart.Text("> **Linear**\n>\n> Review COMMA-1\n>\n> https://linear.app\n\n> Reply to Dana")),
            message.parts)
    }

    private fun asking(state: JSONObject = JSONObject().put("status", "open"), choices: JSONArray = JSONArray()
        .put(JSONObject().put("id", "c1").put("label", "Keep both").put("description", "Nothing is lost?").put("recommended", true))
        .put(JSONObject().put("id", "c2").put("label", "Merge them").put("reply", "Merge them, please."))) =
        JSONObject().put("type", "question").put("prompt", "How should these two be handled?").put("choices", choices)
            .put("multi_select", false).put("allow_other", true).put("state", state)

    @Test fun `an Agent's question is a part of its own and a person's answer shows as their words`() {
        val asked = display(message(2, "agent", "Anything else?") { getJSONArray("content").put(asking()) })!!
        assertEquals(MessagePart.Text("Anything else?"), asked.parts.first())
        val question = (asked.parts.last() as MessagePart.Question).question
        assertEquals("msg_test_2", question.messageId)
        assertEquals("How should these two be handled?", question.prompt)
        assertEquals(listOf(QuestionChoice("c1", "Keep both", "Nothing is lost?", recommended = true),
            QuestionChoice("c2", "Merge them", reply = "Merge them, please.")), question.choices)
        assertEquals("c1", question.recommended)
        assertEquals(QuestionState(QuestionStatus.OPEN), question.state)
        assertTrue(question.allowOther)
        assertFalse(question.multiSelect)

        // The core drops the question's plain-text fallback: a message that only asks still shows, as its card.
        val failed = JSONObject().put("status", "failed").put("choiceIds", JSONArray().put("c2")).put("other", " both ")
            .put("error", "No connection")
        val only = display(message(4, "agent") { put("content", JSONArray().put(asking(failed))) })!!
        assertEquals(QuestionState(QuestionStatus.FAILED, listOf("c2"), " both ", "No connection"),
            (only.parts.single() as MessagePart.Question).question.state)

        val answer = display(message(5, "user", "Merge them, please.") {
            getJSONArray("content").put(JSONObject().put("type", "question_answer").put("question_message_id", "msg_test_4")
                .put("choice_ids", JSONArray().put("c2")).put("skipped", false))
        })!!
        assertEquals(listOf(MessagePart.Text("Merge them, please.")), answer.parts)

        // A card the core could not have made (one choice) is no card.
        val broken = asking(choices = JSONArray().put(JSONObject().put("id", "c1").put("label", "Only")))
        assertNull(display(message(6, "agent") { put("content", JSONArray().put(broken)) }))
    }

    @Test fun `a question card's images and answer go to the core apart from the draft`() = runBlocking {
        core.show(emptyList())
        shown()
        val row = view.attach("photo.jpg", byteArrayOf(1, 2, 3), questionMessageId = "msg_q")!!
        val attached = await { it.questionAttachments.isNotEmpty() }
        assertEquals(DraftAttachment(row, "photo.jpg", 3, DraftAttachmentStatus.UPLOADED, "/uploads/abcdefghijklmnopqrstuv-photo.jpg"),
            attached.questionAttachments.getValue("msg_q").single())
        assertTrue(attached.attachments.isEmpty())
        val params = core.calls.single { it.first == "chatView.attach" }.second
        assertEquals("msg_q", params.getString("questionMessageId"))
        assertEquals("AQID", params.getJSONArray("files").getJSONObject(0).getJSONObject("bytes").getString("\$bytes"))

        assertTrue(view.answerQuestion("msg_q", listOf("c2"), other = "both"))
        val answer = core.calls.last { it.first == "chatView.answerQuestion" }.second
        assertEquals("msg_q", answer.getString("questionMessageId"))
        assertEquals("[\"c2\"]", answer.getJSONArray("choiceIds").toString())
        assertEquals("both", answer.getString("other"))
        assertFalse(answer.has("skipped"))

        assertTrue(view.answerQuestion("msg_q", emptyList(), skipped = true))
        val skipped = core.calls.last { it.first == "chatView.answerQuestion" }.second
        assertTrue(skipped.getBoolean("skipped"))
        assertFalse(skipped.has("other"))

        core.answers = false
        assertFalse(view.answerQuestion("msg_q", listOf("c1")))

        view.removeAttachment(row, questionMessageId = "msg_q")
        assertTrue(await { it.questionAttachments.isEmpty() }.questionAttachments.isEmpty())
    }

    @Test fun `a message is read again only when it changed`() {
        val reader = ChatViewReader(scope(1), CHAT)
        val state = viewState(messages(1L..3L))
        val first = reader.read(viewValue(state)).timeline
        // A streaming reply changes the draft's text alone: the messages are the same objects.
        val streaming = JSONObject().apply { for (key in state.keys()) put(key, state.get(key)) }.put("assistantDraft", JSONObject().put("responseKey", "k")
            .put("sourceMessageIds", JSONArray().put("m")).put("draftId", "d").put("text", "ab").put("status", "streaming"))
        val second = reader.read(viewValue(streaming)).timeline
        assertSame(first[0], second[0])
        assertEquals("ab", (second.last() as TimelineEntry.Draft).draft.text)
    }
}
