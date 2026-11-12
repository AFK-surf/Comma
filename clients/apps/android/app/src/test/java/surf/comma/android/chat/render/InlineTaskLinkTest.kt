package surf.comma.android.chat.render

import android.content.Intent
import android.view.MotionEvent
import android.view.ViewConfiguration
import java.util.concurrent.TimeUnit
import androidx.activity.ComponentActivity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.live.LiveLabels
import surf.comma.android.chat.live.mapConversation
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.MessagePart
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.conversation.display
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.ui.KnownTasks
import surf.comma.android.tasks.ui.TaskRefDirectory
import surf.comma.android.tasks.data.TaskDataState

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class InlineTaskLinkTest {
    @Test fun `offset lookup uses exclusive bounds and ignores web links`() {
        val text = MarkdownText("abc def ghi", listOf(
            MarkdownSpan(4, 7, MarkdownStyle.LINK, "comma:task/cnv_a"),
            MarkdownSpan(8, 11, MarkdownStyle.LINK, "https://example.com")))
        assertNull(text.taskAt(3))
        assertEquals("cnv_a", text.taskAt(4))
        assertEquals("cnv_a", text.taskAt(6))
        assertNull(text.taskAt(7))
        assertNull(text.taskAt(8))
    }

    @Test fun `tap on title opens task while outside movement and long press do not`() {
        val source = "Before [Review](comma:task/cnv_a) after"
        val item = runBlocking {
            MessageLayoutPrecomputer().prepareChanged(emptyList(), listOf(ChatMessage(
                id = 1, conversationId = "test", turnId = "reply", role = ChatRole.AGENT,
                text = "Before Review after", createdAt = 0, markdown = Md.of(source))),
                viewportWidthPx = 1080, density = 3f, fontScale = 1f, darkTheme = false).single()
        }
        Robolectric.buildActivity(ComponentActivity::class.java).use { built ->
            val activity = built.get().apply { setTheme(R.style.Theme_Chat) }
            built.setup()
            val opened = mutableListOf<String>()
            val directory = TaskRefDirectory(MutableStateFlow<Any?>(null), MutableStateFlow(TaskDataState()), { true })
                .apply { onOpenTask = { opened += it } }
            val cell = ChatMessageCell(activity).apply { bind(item) }
            directory.install(cell)
            activity.setContentView(cell)
            ShadowLooper.idleMainLooper()
            assertTrue(cell.contentDescription.contains(item.message.text))
            cell.selectText()
            requireNotNull(cell.textSelection).copy()
            assertEquals(item.message.text,
                activity.getSystemService(android.content.ClipboardManager::class.java)
                    .primaryClip!!.getItemAt(0).text.toString())
            val block = item.blocks.filterIsInstance<PreparedContentBlock.Text>().single()
            val layout = block.layout
            val y = (block.yOffsetPx + block.padPx + layout.getLineTop(0) + layout.getLineBottom(0)) / 2f
            fun x(offset: Int) = item.sideMarginPx + item.horizontalPaddingPx + block.padPx +
                block.leftInsetPx + layout.getPrimaryHorizontal(offset)
            var now = 0L
            fun event(action: Int, offset: Int, elapsed: Long = 0) {
                val ev = MotionEvent.obtain(now, now + elapsed, action, x(offset), y, 0)
                cell.dispatchTouchEvent(ev)
                ev.recycle()
            }
            event(MotionEvent.ACTION_DOWN, 8)
            event(MotionEvent.ACTION_UP, 8, 1)
            assertEquals(listOf("cnv_a"), opened)
            opened.clear()
            now += 100
            event(MotionEvent.ACTION_DOWN, 2)
            event(MotionEvent.ACTION_UP, 2, 1)
            assertTrue(opened.isEmpty())
            now += 100
            event(MotionEvent.ACTION_DOWN, 8)
            event(MotionEvent.ACTION_MOVE, 16, 1)
            event(MotionEvent.ACTION_UP, 8, 2)
            assertTrue(opened.isEmpty())
            now = android.os.SystemClock.uptimeMillis()
            var longPressed = false
            cell.onLongPress = { longPressed = true }
            event(MotionEvent.ACTION_DOWN, 8)
            ShadowLooper.idleMainLooper(ViewConfiguration.getLongPressTimeout().toLong(), TimeUnit.MILLISECONDS)
            event(MotionEvent.ACTION_UP, 8, ViewConfiguration.getLongPressTimeout().toLong())
            assertTrue(longPressed)
            assertTrue(opened.isEmpty())
            now = android.os.SystemClock.uptimeMillis() + 100
            event(MotionEvent.ACTION_DOWN, 8)
            event(MotionEvent.ACTION_CANCEL, 8, 1)
            event(MotionEvent.ACTION_UP, 8, 2)
            assertTrue(opened.isEmpty())
        }
    }

    /** An Agent's reply of [content] (server blocks) as the chat draws it, with what the page's task directory [known]. */
    private fun reply(
        vararg content: JSONObject,
        known: KnownTasks = KnownTasks(),
        change: (surf.comma.android.conversation.ChatMessage) -> surf.comma.android.conversation.ChatMessage = { it },
    ): ChatMessage {
        val message = change(display(JSONObject().put("message_id", "msg_2").put("seq", 2).put("actor_type", "agent")
            .put("agent_id", "agt_1").put("content", JSONArray(content.toList())))!!)
        return mapConversation(ConversationState(conversationId = "cnv_1", timeline = listOf(TimelineEntry.Message("m:msg_2", message))),
            tasks = known).rows.single()
    }

    private fun text(value: String) = JSONObject().put("type", "text").put("text", value)
    private fun chip() = JSONObject().put("type", "conversation_ref").put("presentation", "inline").put("kind", "agent_task")
        .put("conversation_id", "cnv_a")

    /** The tasks a tap on [words] in [row]'s drawn text asks the page's directory to open. */
    private fun opensTapping(row: ChatMessage, words: String): List<String> = tapping(row, words).first

    /** The tasks and the page a tap on [words] in [row]'s drawn text opens. */
    private fun tapping(row: ChatMessage, words: String): Pair<List<String>, Intent?> {
        val item = runBlocking {
            MessageLayoutPrecomputer().prepareChanged(emptyList(), listOf(row),
                viewportWidthPx = 1080, density = 3f, fontScale = 1f, darkTheme = false).single()
        }
        return Robolectric.buildActivity(ComponentActivity::class.java).use { built ->
            val activity = built.get().apply { setTheme(R.style.Theme_Chat) }
            built.setup()
            val opened = mutableListOf<String>()
            val directory = TaskRefDirectory(MutableStateFlow<Any?>(null), MutableStateFlow(TaskDataState()), { true })
                .apply { onOpenTask = { opened += it } }
            val cell = ChatMessageCell(activity).apply { bind(item) }
            directory.install(cell)
            activity.setContentView(cell)
            ShadowLooper.idleMainLooper()
            val block = item.blocks.filterIsInstance<PreparedContentBlock.Text>().single()
            val layout = block.layout
            val offset = layout.text.indexOf(words) + 1
            assertTrue("\"$words\" is drawn in \"${layout.text}\"", offset > 0)
            val line = layout.getLineForOffset(offset)
            val x = item.sideMarginPx + item.horizontalPaddingPx + block.padPx + block.leftInsetPx + layout.getPrimaryHorizontal(offset)
            val y = block.yOffsetPx + block.padPx + (layout.getLineTop(line) + layout.getLineBottom(line)) / 2f
            for ((action, time) in listOf(MotionEvent.ACTION_DOWN to 0L, MotionEvent.ACTION_UP to 1L)) {
                val event = MotionEvent.obtain(0, time, action, x, y, 0)
                cell.dispatchTouchEvent(event)
                event.recycle()
            }
            opened to shadowOf(activity).nextStartedActivity
        }
    }

    private fun agentSays(source: String) = ChatMessage(id = 1, conversationId = "test", turnId = "reply", role = ChatRole.AGENT,
        text = source, createdAt = 0, markdown = Md.of(source))

    @Test fun `a web link opens in the browser, in inline code too`() {
        val page = tapping(agentSays("看 [这个页面](https://x.test/guide?a=1) 吧"), "这个页面").second!!
        assertEquals(Intent.ACTION_VIEW, page.action)
        assertEquals("https://x.test/guide?a=1", page.dataString)
        assertTrue(page.hasCategory(Intent.CATEGORY_BROWSABLE))

        val code = "解出来了：`https://a.mguide.jp/0/mappaexpo?dp=4259`，你试试"
        assertEquals("https://a.mguide.jp/0/mappaexpo?dp=4259", tapping(agentSays(code), "mappaexpo").second!!.dataString)
    }

    @Test fun `words and code that is no address open nothing`() {
        val source = "跑一下 `make test` 再看 https://x.test/1"
        assertNull(tapping(agentSays(source), "跑一下").second)
        assertNull(tapping(agentSays(source), "make test").second)
    }

    @Test fun `a task in a list item or a heading opens from its link`() {
        val known = KnownTasks(summaries = mapOf("cnv_a" to TaskSummary("cnv_a", "Ship the report", TaskStatusBucket.IN_PROGRESS)))
        assertEquals(listOf("cnv_a"), opensTapping(reply(text("- 已创建 "), chip(), known = known), "Ship the report"))
        assertEquals(listOf("cnv_a"), opensTapping(reply(text("## "), chip(), text(" 进度")), LiveLabels().task))
    }

    @Test fun `a task that cannot be opened is words that open nothing`() {
        val unavailable = LiveLabels().taskUnavailable
        fun chipped(change: (MessagePart.TaskChip) -> MessagePart.TaskChip): (surf.comma.android.conversation.ChatMessage) ->
            surf.comma.android.conversation.ChatMessage = { message ->
            message.copy(parts = message.parts.map { if (it is MessagePart.TaskChip) change(it) else it })
        }
        for (row in listOf(
            reply(text("见 "), chip(), text("。"), change = chipped { it.copy(conversationId = null, unavailable = true) }),
            reply(text("见 "), chip(), text("。"), change = chipped { it.copy(conversationId = null) }),
            reply(text("见 "), chip(), text("。"), known = KnownTasks(confirmed = setOf("cnv_a"))),
        )) assertEquals(emptyList<String>(), opensTapping(row, unavailable))
    }
}
