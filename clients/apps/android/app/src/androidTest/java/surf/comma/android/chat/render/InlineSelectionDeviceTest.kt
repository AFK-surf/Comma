package surf.comma.android.chat.render

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ClipboardManager
import android.graphics.Bitmap
import android.os.Bundle
import android.view.Choreographer
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.ui.MessageActionsPopup
import surf.comma.android.ui.composer.demo.ComposerDemoActivity
import java.io.File
import java.util.concurrent.CompletableFuture

/** Offline rendering test: the real floating toolbar and handle windows receive system input. */
class InlineSelectionDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun settle() {
        instrumentation.waitForIdleSync()
        nextFrame()
        instrumentation.waitForIdleSync()
    }

    /** Input timestamps come from the display frame that receives each gesture step. */
    private fun nextFrame(): Long {
        val frame = CompletableFuture<Long>()
        main { Choreographer.getInstance().postFrameCallback { frame.complete(it / 1_000_000) } }
        return frame.get()
    }

    @Test(timeout = 30_000) fun selectInBubbleDragCopyAndResumeScrolling() {
        instrumentation.uiAutomation.serviceInfo = instrumentation.uiAutomation.serviceInfo.apply {
            flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        }
        ActivityScenario.launch(ComposerDemoActivity::class.java).use { scenario ->
            lateinit var timeline: ChatTimelineView
            lateinit var cell: ChatMessageCell
            lateinit var item: PreparedChatMessage
            lateinit var activity: ComposerDemoActivity
            scenario.onActivity {
                activity = it
                timeline = ChatTimelineView(it)
                val root = FrameLayout(it).apply {
                    setBackgroundColor(it.getColor(R.color.token_bg_primary))
                    addView(timeline, FrameLayout.LayoutParams(-1, -1))
                }
                ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
                    val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
                    view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                    insets
                }
                it.setContentView(root)
            }
            settle()
            val paragraphs = listOf("First paragraph.", "Second paragraph.") +
                List(30) { "More text $it for scrolling through this offline selection sample." }
            val tree = JSONArray().apply {
                paragraphs.forEach { put(JSONArray().put("p").put(JSONArray().put(it))) }
            }
            item = runBlocking {
                MessageLayoutPrecomputer(bubbles = true).prepare(listOf(ChatMessage(1, "offline", "reply",
                    ChatRole.AGENT, paragraphs.joinToString("\n\n"), 0, markdown = tree.toString())),
                    timeline.width, activity.resources.displayMetrics.density, 1f, false).single()
            }
            main { timeline.submitPrepared(listOf(item)) }
            settle()
            main { (timeline.layoutManager as LinearLayoutManager).scrollToPositionWithOffset(0, 0) }
            settle()
            main {
                cell = requireNotNull(timeline.viewForRow(1)) as ChatMessageCell
                cell.onLongPress = { MessageActionsPopup.show(cell, it) }
                assertTrue(cell.performAccessibilityAction(AccessibilityNodeInfo.ACTION_LONG_CLICK, null))
            }
            settle()
            clickText(activity.getString(R.string.action_select_text))
            settle()
            var fromX = 0f
            var fromY = 0f
            var toX = 0f
            var toY = 0f
            main {
                val selection = requireNotNull(cell.textSelection)
                assertEquals(paragraphs.joinToString("\n\n"), selection.selectedText)
                assertTrue(cell.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, 5)
                }))
                assertEquals("First", selection.selectedText)
                val geometry = MessageSelectionGeometry(item)
                val runs = geometry.runs(item.sideMarginPx.toFloat()) { 0 }
                val first = requireNotNull(geometry.caret(runs, selection.end, true))
                val target = requireNotNull(geometry.caret(runs, geometry.text.indexOf("Second") + 6, true))
                val location = IntArray(2).also(cell::getLocationOnScreen)
                val density = activity.resources.displayMetrics.density
                fromX = location[0] + first.x + 6 * density
                fromY = location[1] + first.y + 12 * density
                toX = location[0] + target.x + 6 * density
                toY = location[1] + target.y + 12 * density
                assertSame(timeline, cell.parent)
                assertFalse(activity.isFinishing)
            }
            capture("inline-selection-before")
            drag(fromX, fromY, toX, toY)
            settle()
            capture("inline-selection")
            main { assertEquals("First paragraph.\n\nSecond", cell.textSelection?.selectedText) }
            clickText(activity.getString(android.R.string.copy))
            settle()
            main {
                assertNull(cell.textSelection)
                assertEquals("First paragraph.\n\nSecond", activity.getSystemService(ClipboardManager::class.java)
                    .primaryClip!!.getItemAt(0).text.toString())
            }
            val before = cell.y
            drag(timeline.width / 2f, timeline.height * 0.7f, timeline.width / 2f, timeline.height * 0.3f)
            settle()
            main { assertTrue("the transcript scrolls normally after selection", cell.y < before) }
        }
    }

    private fun clickText(text: String) {
        val ready = CompletableFuture<AccessibilityNodeInfo>()
        fun inspectWindows() {
            if (ready.isDone) return
            val roots = instrumentation.uiAutomation.windows.mapNotNull { it.root } +
                listOfNotNull(instrumentation.uiAutomation.rootInActiveWindow)
            val pending = ArrayDeque(roots)
            val nodes = ArrayList<AccessibilityNodeInfo>()
            while (pending.isNotEmpty() && nodes.size < 1_000) {
                val node = pending.removeFirst()
                nodes += node
                for (index in 0 until node.childCount) node.getChild(index)?.let(pending::addLast)
            }
            val node = nodes.asSequence()
                .filter { it.text?.toString() == text || it.contentDescription?.toString() == text }
                .mapNotNull { label -> generateSequence(label) { it.parent }.firstOrNull { it.isClickable } }
                .firstOrNull()
            if (node != null) ready.complete(node)
        }
        instrumentation.uiAutomation.setOnAccessibilityEventListener { inspectWindows() }
        try {
            inspectWindows()
            assertTrue(ready.get().performAction(AccessibilityNodeInfo.ACTION_CLICK))
        } finally {
            instrumentation.uiAutomation.setOnAccessibilityEventListener(null)
        }
    }

    private fun drag(x1: Float, y1: Float, x2: Float, y2: Float) {
        val down = nextFrame()
        fun send(action: Int, x: Float, y: Float) {
            val event = MotionEvent.obtain(down, nextFrame(), action, x, y, 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            instrumentation.uiAutomation.injectInputEvent(event, true)
            event.recycle()
        }
        send(MotionEvent.ACTION_DOWN, x1, y1)
        repeat(12) { step ->
            val p = (step + 1) / 12f
            send(MotionEvent.ACTION_MOVE, x1 + (x2 - x1) * p, y1 + (y2 - y1) * p)
        }
        send(MotionEvent.ACTION_UP, x2, y2)
    }

    private fun capture(name: String) {
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        File(instrumentation.targetContext.filesDir, "$name.png").outputStream().use {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        bitmap.recycle()
    }
}
