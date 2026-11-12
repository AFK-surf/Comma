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
import surf.comma.android.chat.render.MarkdownStyle
import surf.comma.android.chat.render.MarkdownTree
import surf.comma.android.chat.render.MessageActionLabels
import surf.comma.android.chat.render.MessageContent
import surf.comma.android.chat.render.messageActionsFor
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.display
import surf.comma.android.conversation.MessagePart
import surf.comma.android.conversation.ParticipantStatus
import surf.comma.android.conversation.PendingMessage
import surf.comma.android.conversation.PendingStatus
import surf.comma.android.conversation.ReplyDraft
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.ui.KnownTasks

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
        val rows = mapConversation(replied).rows
        assertTrue("no typing bubble", rows.none { it.cardKind == TimelineBlockKinds.LIVE_STATUS })
        assertEquals("the finished reply ends the list", "done", rows.last().text)
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
        val labels = LiveLabels(task = "Untitled fixture task")
        val rows = mapConversation(state(entry), labels).rows
        assertEquals(listOf(null, LiveRowKinds.INTERACTIVE_SUMMARY, LiveRowKinds.ATTACHMENT,
            LiveRowKinds.ATTACHMENT), rows.map { it.cardKind })
        assertEquals("Created ${labels.task} for you.", rows[0].text)
        assertEquals("A chart of sales", rows[1].text)
        val image = LiveRowKinds.decodeAttachment(rows[2].cardPayload)
        assertFalse(image.image) // No source: an unavailable file card, even with image dimensions.
        assertEquals(800, image.widthPx)
        assertEquals(400, image.heightPx)
        val file = LiveRowKinds.decodeAttachment(rows[3].cardPayload)
        assertFalse(file.image)
        assertEquals("report.pdf", file.name)
        assertEquals(rows.size, rows.map { it.id }.toSet().size)
    }

    @Test fun `inline tasks keep surrounding text and exact title links in both mapping paths`() {
        val title = "Review files"
        val chip = block("conversation_ref") {
            put("presentation", "inline"); put("kind", "agent_task")
            put("conversation_id", "cnv_a"); put("title", title)
        }
        for ((before, after) in listOf("稍后告诉你结果。（处理中：" to "）", "见 " to "。")) {
            val entry = canonical(2, "agent", text(before), chip, text(after)) as TimelineEntry.Message
            for (message in listOf(entry.message, entry.message.copy(markdown = null))) {
                val row = mapConversation(state(entry.copy(message = message))).rows.single()
                assertNull(row.cardKind)
                assertEquals(before + title + after, row.text)
                val block = surf.comma.android.chat.render.MarkdownTree.blocks(JSONArray(row.markdown)).single()
                    as surf.comma.android.chat.render.MessageContent.Paragraph
                val link = block.text.spans.single { it.href != null }
                assertEquals(surf.comma.android.chat.render.MarkdownStyle.LINK, link.style)
                assertEquals("comma:task/cnv_a", link.href)
                assertEquals(title, block.text.text.substring(link.start, link.end))
                assertEquals(row.text, entryText(state(entry.copy(message = message)), entry.key))
            }
        }
    }

    @Test fun `a standalone task keeps its card and trailing punctuation in both mapping paths`() {
        val chip = block("conversation_ref") {
            put("presentation", "inline"); put("kind", "agent_task"); put("conversation_id", "cnv_a")
        }
        val entry = canonical(2, "agent", chip, text("。")) as TimelineEntry.Message
        for (message in listOf(entry.message, entry.message.copy(markdown = null))) {
            val row = mapConversation(state(entry.copy(message = message))).rows.single()
            assertEquals(LiveRowKinds.TASK_REF, row.cardKind)
            assertEquals("。", LiveRowKinds.decodeTask(row.cardPayload).suffix)
        }
        assertEquals(3, attachedPunctuationLength("?!) and more"))
        assertEquals(0, attachedPunctuationLength("word."))
    }

    /** A task chip as the server sends one inside a reply's text, without a title unless [configure] gives it one. */
    private fun inlineChip(configure: JSONObject.() -> Unit = {}) = block("conversation_ref") {
        put("presentation", "inline"); put("kind", "agent_task"); put("conversation_id", "cnv_a"); configure()
    }

    /** Each link in [row]'s text: where it goes, and the words it shows. */
    private fun links(row: surf.comma.android.chat.model.ChatMessage): List<Pair<String?, String>> =
        MarkdownTree.blocks(JSONArray(row.markdown)).flatMap { block ->
            val text = when (block) {
                is MessageContent.Paragraph -> block.text
                is MessageContent.ListItem -> block.text
                is MessageContent.Heading -> block.text
                else -> return@flatMap emptyList()
            }
            text.spans.filter { it.style == MarkdownStyle.LINK }.map { it.href to text.text.substring(it.start, it.end) }
        }

    private val shipped = TaskSummary("cnv_a", "Ship the report", TaskStatusBucket.IN_PROGRESS)

    @Test fun `a task in running text is titled by the task directory, then by its chip, then as a task`() {
        val directory = KnownTasks(summaries = mapOf("cnv_a" to shipped))
        val untitled = canonical(2, "agent", text("见 "), inlineChip(), text("。")) as TimelineEntry.Message
        val titled = canonical(2, "agent", text("见 "), inlineChip { put("title", "Review files") }, text("。")) as TimelineEntry.Message
        for ((entry, known, title) in listOf(
            Triple(untitled, directory, "Ship the report"),
            Triple(untitled, KnownTasks(), LiveLabels().task),
            Triple(titled, KnownTasks(), "Review files"),
            Triple(titled, directory, "Ship the report"),
            Triple(titled, KnownTasks(summaries = mapOf("cnv_a" to shipped.copy(title = " "))), "Review files"),
        )) for (message in listOf(entry.message, entry.message.copy(markdown = null))) {
            val row = mapConversation(state(entry.copy(message = message)), tasks = known).rows.single()
            assertNull(row.cardKind)
            assertEquals("见 $title。", row.text)
            assertEquals(listOf("comma:task/cnv_a" to title), links(row))
        }
    }

    @Test fun `a task in running text that cannot be opened is plain words, as its card would say`() {
        val entry = canonical(2, "agent", text("见 "), inlineChip(), text("。")) as TimelineEntry.Message
        fun chipped(change: (MessagePart.TaskChip) -> MessagePart.TaskChip) =
            entry.message.copy(parts = entry.message.parts.map { if (it is MessagePart.TaskChip) change(it) else it })
        for ((message, known) in listOf(
            // Withdrawn, or not an Agent task.
            chipped { it.copy(conversationId = null, unavailable = true) } to KnownTasks(),
            chipped { it.copy(conversationId = null) } to KnownTasks(),
            chipped { it.copy(conversationId = "") } to KnownTasks(),
            // The server answered and has no such task.
            entry.message to KnownTasks(confirmed = setOf("cnv_a")),
        )) for (shown in listOf(message, message.copy(markdown = null))) {
            val row = mapConversation(state(entry.copy(message = shown)), tasks = known).rows.single()
            assertNull(row.cardKind)
            assertEquals("见 ${LiveLabels().taskUnavailable}。", row.text)
            assertEquals(emptyList<Pair<String?, String>>(), links(row))
        }
    }

    @Test fun `a task in a list item or a heading is a link in its text`() {
        val known = KnownTasks(summaries = mapOf("cnv_a" to shipped))
        val listed = mapConversation(state(canonical(2, "agent", text("- 已创建 "), inlineChip())), tasks = known).rows.single()
        assertEquals("已创建 Ship the report", (MarkdownTree.blocks(JSONArray(listed.markdown)).single() as MessageContent.ListItem).text.text)
        assertEquals(listOf("comma:task/cnv_a" to "Ship the report"), links(listed))

        val heading = mapConversation(state(canonical(2, "agent", text("## "), inlineChip(), text(" 进度")))).rows.single()
        assertEquals("${LiveLabels().task} 进度", (MarkdownTree.blocks(JSONArray(heading.markdown)).single() as MessageContent.Heading).text.text)
        assertEquals(listOf("comma:task/cnv_a" to LiveLabels().task), links(heading))

        val missing = mapConversation(state(canonical(2, "agent", text("- 已创建 "), inlineChip())),
            tasks = KnownTasks(confirmed = setOf("cnv_a"))).rows.single()
        assertEquals("已创建 ${LiveLabels().taskUnavailable}", missing.text)
        assertEquals(emptyList<Pair<String?, String>>(), links(missing))
    }

    @Test fun `text without a parsed tree breaks into paragraphs at blank lines, without blank space at the break`() {
        for (written in listOf("a\n\n\nb", "a \n\n b")) {
            val row = mapConversation(state(canonical(1, "user", text(written), requestId = "req-1"))).rows.single()
            val tree = JSONArray(row.markdown)
            assertEquals(listOf(listOf("a"), listOf("b")), (0 until tree.length()).map { at ->
                val paragraph = tree.getJSONArray(at)
                assertEquals("p", paragraph.getString(0))
                paragraph.getJSONArray(1).let { words -> (0 until words.length()).map(words::getString) }
            })
            assertEquals("a\n\nb", row.text)
        }
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
        assertEquals(listOf("r:req-1", "m:msg_2", "r:req-3", null), entries)
        assertEquals("Made Plan for you.", entryText(st, "m:msg_2"))
        assertEquals("later", entryText(st, "r:req-3"))
        assertNull(entryText(st, "m:missing"))
    }
}
