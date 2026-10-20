package surf.comma.android.chat.live

import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.ViewGroup
import android.view.animation.AnimationUtils
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowChoreographer
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.scroll.widget.RecyclerView
import java.time.Duration
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class ScrollToLatestTest {
    @Test fun `visibility follows the distance from the end`() {
        val screen = 1000
        assertFalse("following", scrollToLatestVisible(false, 5000, 5000, screen, readingHistory = false))
        assertFalse("less than a screen up", scrollToLatestVisible(false, 600, 5000, screen, readingHistory = true))
        assertTrue("more than a screen up", scrollToLatestVisible(false, 1200, 5000, screen, readingHistory = true))
        assertTrue("stays while coming back down", scrollToLatestVisible(true, 600, 900, screen, readingHistory = true))
        assertFalse("gone at the end", scrollToLatestVisible(true, 1200, 0, screen, readingHistory = true))
    }

    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        .apply { setTheme(R.style.Theme_Chat) }
    private val density = activity.resources.displayMetrics.density
    private val timeline = ChatTimelineView(activity)
    private val button = ScrollToLatestButton(activity)
    private val viewport get() = timeline.height - timeline.paddingTop - timeline.paddingBottom

    init {
        activity.setContentView(FrameLayout(activity).apply {
            addView(timeline, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            addView(button, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL))
        })
        button.bindTo(timeline)
        settle()
    }

    private fun settle() = repeat(150) {
        ShadowLooper.idleMainLooper(16, TimeUnit.MILLISECONDS)
    }

    private val reply = (1..40).joinToString("\n\n") { "line $it" }
    private fun history(turns: Int) = (1..turns).flatMap {
        listOf(
            ChatMessage(id = it * 10L, conversationId = "c", turnId = "t$it", role = ChatRole.USER, text = "question $it", createdAt = it * 10L),
            ChatMessage(id = it * 10L + 1, conversationId = "c", turnId = "t$it", role = ChatRole.AGENT, text = reply, createdAt = it * 10L + 1),
        )
    }

    private fun submit(rows: List<ChatMessage>) {
        val prepared = runBlocking {
            MessageLayoutPrecomputer().prepare(rows, viewportWidthPx = timeline.width, density = density, fontScale = 1f, darkTheme = false)
        }
        timeline.submitPrepared(prepared)
        settle()
    }

    /** A finger drag down the list by [distancePx], i.e. back into history. */
    private fun drag(distancePx: Int) {
        val start = SystemClock.uptimeMillis()
        val x = timeline.width / 2f
        val y = timeline.height / 3f
        fun event(action: Int, dy: Float, at: Long) = MotionEvent.obtain(start, start + at, action, x, y + dy, 0).also {
            timeline.dispatchTouchEvent(it)
            it.recycle()
        }
        event(MotionEvent.ACTION_DOWN, 0f, 0)
        val steps = 20
        for (step in 1..steps) event(MotionEvent.ACTION_MOVE, distancePx * step / steps.toFloat(), step * 400L)
        event(MotionEvent.ACTION_UP, distancePx.toFloat(), (steps + 1) * 400L)
        settle()
    }

    private fun lastMessageBottom(count: Int): Int? =
        (0 until timeline.childCount).map { timeline.getChildAt(it) }
            .firstOrNull { timeline.getChildAdapterPosition(it) == count - 1 }?.bottom

    @Test fun `shows beyond a screen of history and a tap goes back and keeps following`() {
        submit(history(6))
        // Opened on a reply taller than the screen: its visible end rests at the bottom.
        assertTrue(timeline.isPinnedToEnd())
        assertEquals(0, timeline.bottomOverflowPx())
        assertFalse(button.shown)

        drag(viewport / 2)
        assertFalse("reading, but less than a screen up", timeline.isPinnedToEnd())
        assertFalse(button.shown)

        drag(viewport)
        assertTrue(button.shown)

        // Back down by half a screen: still reading, the button stays.
        drag(-viewport / 2)
        assertTrue(button.shown)

        button.performClick()
        settle()
        assertTrue(timeline.isPinnedToEnd())
        assertEquals("the last message rests on the list's bottom line", timeline.height - timeline.paddingBottom, lastMessageBottom(12))
        assertFalse(button.shown)

        // Following again: the reply still streaming grows and the list stays on its end.
        val streaming = history(6).dropLast(1) + history(6).last().copy(text = reply + "\n\nmore")
        submit(streaming)
        assertTrue(timeline.isPinnedToEnd())
        assertEquals(timeline.height - timeline.paddingBottom, lastMessageBottom(12))
        assertFalse(button.shown)
    }

    @Test fun `a tap from deep in the history lands on the latest message within 500 ms`() {
        submit(history(40))
        repeat(12) { drag(viewport) }
        assertTrue(button.shown)
        assertTrue("far from the end", lastMessageBottom(80) == null)

        // Animation time is read off the frames that move the list: the first step after the
        // tap to the step that reaches the latest message.
        val resting = timeline.height - timeline.paddingBottom
        var firstStep = -1L
        var arrived = -1L
        timeline.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                if (dy == 0 || arrived >= 0) return
                val now = AnimationUtils.currentAnimationTimeMillis()
                if (firstStep < 0) firstStep = now
                if (lastMessageBottom(80) == resting) arrived = now
            }
        })
        ShadowChoreographer.setFrameDelay(Duration.ofMillis(16))
        button.performClick()
        settle()

        assertTrue("reached the latest message", arrived >= 0)
        assertTrue("animated for ${arrived - firstStep} ms", arrived - firstStep <= 500)
        // And it stays there: nothing re-pins it afterwards.
        assertEquals(resting, lastMessageBottom(80))
        assertTrue(timeline.isPinnedToEnd())
    }

}
