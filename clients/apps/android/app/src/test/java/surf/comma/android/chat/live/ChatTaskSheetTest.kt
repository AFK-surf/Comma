package surf.comma.android.chat.live

import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import androidx.activity.ComponentActivity
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.pages.TaskDetailActivity
import surf.comma.android.tasks.ui.TaskDetailView
import surf.comma.android.tasks.ui.TaskRefDirectory

/** Task cards in the chat open the task in a sheet over the chat. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w360dp-h740dp-xxhdpi")
class ChatTaskSheetTest {
    private class Home(val activity: ComponentActivity, val screen: LiveChatScreen, val home: ChatHome, val timeline: ChatTimelineView) {
        val sheet get() = home.taskSheet
        val layout get() = home.taskSheet.layout
    }

    @Before fun jumpSprings() = setDurationScale(0f)

    @After fun restoreSprings() = setDurationScale(1f)

    private fun setDurationScale(scale: Float) {
        android.animation.ValueAnimator::class.java.getDeclaredMethod("setDurationScale", Float::class.javaPrimitiveType)
            .invoke(null, scale)
    }

    private fun <T> withHome(block: (Home) -> T): T =
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Chat)
            controller.setup()
            val screen = LiveChatScreen(activity, ChatGraph.conversations(activity), AuthGraph.get(activity).state,
                retrySession = {}, onOpenAccount = {})
            val home = ChatHome(activity, screen, onOpenSettings = {})
            activity.setContentView(home.root)
            ShadowLooper.idleMainLooper()
            val timeline = activity.findViewById<ChatTimelineView>(R.id.conversation_timeline)
            try {
                block(Home(activity, screen, home, timeline))
            } finally {
                screen.release()
            }
        }

    private val known = TaskSummary("task-3", "Summarise today's Slack", TaskStatusBucket.IN_PROGRESS)

    /** What a card in the transcript does when tapped: it asks the timeline's directory. */
    private fun tapCard(h: Home, taskId: String = "task-3") {
        TaskRefDirectory.find(h.timeline)!!.open(taskId)
        settle(h)
    }

    private fun settle(h: Home) {
        ShadowLooper.idleMainLooper()
        val root = h.home.root
        root.measure(View.MeasureSpec.makeMeasureSpec(root.width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(root.height, View.MeasureSpec.EXACTLY))
        root.layout(root.left, root.top, root.right, root.bottom)
        ShadowLooper.idleMainLooper()
    }

    private fun open(h: Home) {
        h.screen.onOpenTaskCard!!.invoke(known.id, known)
        settle(h)
    }

    @Test fun `tapping a task card in the chat opens the sheet, not the page`() = withHome { h ->
        tapCard(h)
        assertNull("no page is started", shadowOf(h.activity).nextStartedActivity)
        assertTrue(h.sheet.isOpen)
        assertEquals("task-3", h.sheet.taskId)
        assertEquals(View.VISIBLE, h.layout.visibility)
        assertFalse("opens part way, not full height", h.layout.isExpanded)
        // About 60% of the screen: the sheet's top sits 40% down.
        val top = h.layout.offsetPx + h.sheet.shown!!.view.top
        assertEquals(0.4f, top / h.layout.height, 0.02f)
    }

    @Test fun `the sidebar still opens the full page`() = withHome { h ->
        h.home.sidebar.onOpenTask!!.invoke("task-3")
        assertEquals(TaskDetailActivity::class.java.name, shadowOf(h.activity).nextStartedActivity.component!!.className)
        assertFalse(h.sheet.isOpen)
    }

    @Test fun `the sheet is the task page's own body, showing what the card knew at once`() = withHome { h ->
        open(h)
        val body = h.sheet.shown!!.view
        assertTrue(body is TaskDetailView)
        assertEquals(known.title, body.title.text.toString())
        assertNotNull("the same list as the page", (body.messageArea.getChildAt(0) as? ChatTimelineView))
        assertTrue(body.gripHeightPx > 0)
    }

    private fun drag(h: Home, fromY: Float, toY: Float) {
        val x = h.layout.width / 2f
        val start = SystemClock.uptimeMillis()
        val steps = 10
        h.layout.dispatchTouchEvent(MotionEvent.obtain(start, start, MotionEvent.ACTION_DOWN, x, fromY, 0))
        for (step in 1..steps) {
            val y = fromY + (toY - fromY) * step / steps
            h.layout.dispatchTouchEvent(MotionEvent.obtain(start, start + step * 16L, MotionEvent.ACTION_MOVE, x, y, 0))
        }
        h.layout.dispatchTouchEvent(MotionEvent.obtain(start, start + (steps + 1) * 16L, MotionEvent.ACTION_UP, x, toY, 0))
        settle(h)
    }

    private fun gripY(h: Home) = h.layout.offsetPx + h.sheet.shown!!.view.top + 10f

    @Test fun `dragging the handle up expands it, dragging down closes it`() = withHome { h ->
        open(h)
        drag(h, gripY(h), 10f)
        assertTrue("full height", h.layout.isExpanded)
        assertEquals(0f, h.layout.offsetPx)

        drag(h, gripY(h), h.layout.height - 10f)
        assertFalse(h.sheet.isOpen)
        assertNull("let go once closed", h.sheet.taskId)
    }

    @Test fun `the list scrolls first, and the sheet moves once the list is at its top`() = withHome { h ->
        open(h)
        val list = h.sheet.shown!!.timeline
        val consumed = IntArray(2)
        // Finger up at half height: the sheet grows before the list scrolls.
        val before = h.layout.offsetPx
        h.layout.onNestedPreScroll(list, 0, 60, consumed, androidx.core.view.ViewCompat.TYPE_TOUCH)
        assertEquals(60, consumed[1])
        assertEquals(before - 60f, h.layout.offsetPx)

        // At full height the list takes every scroll.
        drag(h, gripY(h), 10f)
        consumed.fill(0)
        h.layout.onNestedPreScroll(list, 0, 60, consumed, androidx.core.view.ViewCompat.TYPE_TOUCH)
        assertEquals("the sheet leaves the list alone", 0, consumed[1])
        assertEquals(0f, h.layout.offsetPx)

        // Finger down: what the list could still scroll is its own; only the rest moves the sheet.
        h.layout.onNestedScroll(list, 0, -40, 0, 0, androidx.core.view.ViewCompat.TYPE_TOUCH, consumed)
        assertEquals("the list scrolled, the sheet stayed", 0f, h.layout.offsetPx)
        h.layout.onNestedScroll(list, 0, 0, 0, -50, androidx.core.view.ViewCompat.TYPE_TOUCH, consumed)
        assertEquals("pulled down past the list's top", 50f, h.layout.offsetPx)
    }

    @Test fun `back and a tap on the dimmed chat close it`() = withHome { h ->
        open(h)
        h.activity.onBackPressedDispatcher.onBackPressed()
        settle(h)
        assertFalse(h.sheet.isOpen)
        assertNull(h.sheet.taskId)

        open(h)
        assertTrue(h.sheet.isOpen)
        h.layout.getChildAt(0).performClick()
        settle(h)
        assertFalse(h.sheet.isOpen)
    }
}
