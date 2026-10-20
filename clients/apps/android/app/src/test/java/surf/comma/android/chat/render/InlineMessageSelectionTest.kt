package surf.comma.android.chat.render

import android.content.ClipboardManager
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import kotlinx.coroutines.runBlocking
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
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class InlineMessageSelectionTest {
    private fun prepare(text: String, id: Long = 1, role: ChatRole = ChatRole.AGENT): PreparedChatMessage = runBlocking {
        MessageLayoutPrecomputer().prepareChanged(emptyList(), listOf(ChatMessage(
            id = id, conversationId = "selection-test", turnId = "reply", role = role, text = text, createdAt = 0,
            markdown = if (role == ChatRole.AGENT) Md.of(text) else null)),
            viewportWidthPx = 1080, density = 3f, fontScale = 1f, darkTheme = false).single()
    }

    @Test fun `touch selects its word but accessibility long press does not reuse that position`() {
        val item = prepare("First **paragraph**.\n\nSecond paragraph.")
        Robolectric.buildActivity(ComponentActivity::class.java).use { built ->
            val activity = built.get().apply { setTheme(R.style.Theme_Chat) }
            built.setup()
            val cell = ChatMessageCell(activity).apply {
                bind(item)
                onLongPress = { selectText() }
            }
            activity.setContentView(cell)
            ShadowLooper.idleMainLooper()
            val geometry = MessageSelectionGeometry(item)
            val runs = geometry.runs(item.sideMarginPx.toFloat()) { 0 }
            val point = requireNotNull(geometry.caret(runs, geometry.text.indexOf("Second") + 2, false))
            val down = MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, point.x, point.y - 1, 0)
            cell.dispatchTouchEvent(down)
            down.recycle()
            ShadowLooper.idleMainLooper(ViewConfiguration.getLongPressTimeout().toLong(), TimeUnit.MILLISECONDS)
            assertEquals("Second", cell.textSelection?.selectedText)
            val up = MotionEvent.obtain(0, ViewConfiguration.getLongPressTimeout().toLong(),
                MotionEvent.ACTION_UP, point.x, point.y - 1, 0)
            cell.dispatchTouchEvent(up)
            up.recycle()
            cell.clearTextSelection()

            assertTrue(cell.performAccessibilityAction(AccessibilityNodeInfo.ACTION_LONG_CLICK, null))
            assertEquals("a non-touch selection starts with the whole message",
                "First paragraph.\n\nSecond paragraph.", cell.textSelection?.selectedText)
        }
    }

    @Test fun `handles select across paragraphs in the same bubble and copy just that range`() {
        val item = prepare("First **paragraph**.\n\nSecond paragraph.")
        Robolectric.buildActivity(ComponentActivity::class.java).use { activityController ->
            val activity = activityController.get().apply { setTheme(R.style.Theme_Chat) }
            activityController.setup()
            val root = FrameLayout(activity)
            val cell = ChatMessageCell(activity).apply { bind(item) }
            root.addView(cell)
            activity.setContentView(root)
            ShadowLooper.idleMainLooper()
            val height = cell.height
            cell.selectText()
            val selection = requireNotNull(cell.textSelection)
            val geometry = MessageSelectionGeometry(item)
            val runs = geometry.runs(item.sideMarginPx.toFloat()) { 0 }
            val from = geometry.text.indexOf("paragraph")
            val to = geometry.text.indexOf("Second") + "Second".length
            val first = requireNotNull(geometry.caret(runs, from, false))
            val last = requireNotNull(geometry.caret(runs, to, true))
            selection.selectAll()
            selection.moveHandle(true, first.x, first.y - 1)
            selection.moveHandle(false, last.x, last.y - 1)
            assertEquals("paragraph.\n\nSecond", selection.selectedText)
            assertSame(root, cell.parent)
            assertEquals("selection preserves the bubble's layout", height, cell.height)
            assertNull(shadowOf(activity).nextStartedActivity)
            selection.copy()
            assertEquals("paragraph.\n\nSecond",
                activity.getSystemService(ClipboardManager::class.java).primaryClip!!.getItemAt(0).text.toString())
            assertNull(cell.textSelection)
        }
    }

    @Test fun `select all keeps text beyond a task reference and recycling ends the selection`() {
        val item = prepare("Before the card")
        Robolectric.buildActivity(ComponentActivity::class.java).use { built ->
            val activity = built.get().apply { setTheme(R.style.Theme_Chat) }
            built.setup()
            val cell = ChatMessageCell(activity).apply { bind(item) }
            activity.setContentView(cell)
            ShadowLooper.idleMainLooper()
            cell.selectText(Md.blocks("Before the card\n\nTask title\n\nAfter the card"))
            requireNotNull(cell.textSelection).selectAll()
            assertEquals("Before the card\n\nTask title\n\nAfter the card", cell.textSelection?.selectedText)
            cell.bind(prepare("Another message", 2))
            assertNull("a reused row cannot retain another message's copy action", cell.textSelection)
        }
    }

    @Test fun `long paragraphs map later chunks without losing repeated words or emoji boundaries`() {
        val item = prepare(List(35) { "Line $it: 中文 👩🏽‍💻 repeated words." }.joinToString("\n\n"))
        val geometry = MessageSelectionGeometry(item)
        val runs = geometry.runs(item.sideMarginPx.toFloat()) { 0 }
        for (run in runs) {
            val caret = run.caret(run.start, false)
            val offset = geometry.offsetAt(runs, caret.x, caret.y - 1)
            assertEquals(run.start, offset)
        }
        val emoji = geometry.text.indexOf("👩🏽‍💻")
        val emojiEnd = emoji + "👩🏽‍💻".length
        for (offset in emoji + 1 until emojiEnd) {
            assertTrue("a handle must not split an emoji sequence", geometry.boundary(offset) in listOf(emoji, emojiEnd))
        }
        val longItem = prepare(List(80) { "word$it" }.joinToString(" "))
        val longGeometry = MessageSelectionGeometry(longItem)
        val chunks = longGeometry.runs(longItem.sideMarginPx.toFloat()) { 0 }
        assertTrue(chunks.size > 1)
        assertEquals("the last chunk reaches the last word", longGeometry.text.length, chunks.last().end)
        for (run in chunks) {
            val layout = requireNotNull(run.layout)
            for (line in 1 until layout.lineCount) {
                val offset = run.base + layout.getLineStart(line)
                val caret = run.caret(offset, true)
                assertEquals("a handle at a wrapped line must stay at its text offset", offset,
                    longGeometry.offsetAt(chunks, caret.x, caret.y - 1))
            }
        }
    }

    @Test fun `code and repeated table cells follow their horizontal scroll offset`() {
        val item = prepare("```kt\nval answer = 42\n```\n\n| Same | Same |\n|---|---|\n| one | two |")
        val geometry = MessageSelectionGeometry(item)
        val rest = geometry.runs(item.sideMarginPx.toFloat()) { 0 }
        val scrolled = geometry.runs(item.sideMarginPx.toFloat()) { 40 }
        assertEquals("val answer = 42\n\nSame\tSame\none\ttwo", geometry.text)
        assertEquals(rest.map { it.start }, scrolled.map { it.start })
        rest.zip(scrolled).forEach { (before, after) ->
            assertEquals(40f, before.x - after.x, 0f)
            assertEquals(before.clip, after.clip)
        }
        assertEquals(listOf(geometry.text.indexOf("Same"), geometry.text.lastIndexOf("Same")),
            rest.filter { it.layout?.text.toString() == "Same" }.map { it.start })
        val secondCell = rest.last { it.layout?.text.toString() == "Same" }
        val point = secondCell.caret(secondCell.start, false)
        assertEquals("a table hit selects the cell under the finger", secondCell.start,
            geometry.offsetAt(rest, point.x, point.y - 1))
    }
}
