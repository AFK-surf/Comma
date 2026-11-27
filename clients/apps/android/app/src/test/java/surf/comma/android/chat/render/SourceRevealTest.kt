package surf.comma.android.chat.render

import android.view.MotionEvent
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import java.util.concurrent.TimeUnit

/** Dragging the chat to the left moves the person's rows and shows where their messages came from; letting go returns them. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class SourceRevealTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val density = activity.resources.displayMetrics.density
    private val timeline = ChatTimelineView(activity)

    init {
        activity.setContentView(FrameLayout(activity).apply {
            addView(timeline, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        })
        settle()
        val rows = listOf(
            ChatMessage(1, "c", "t1", ChatRole.USER, "From WeChat", 1, platformSource = "wechat"),
            ChatMessage(2, "c", "t1", ChatRole.AGENT, "Reply", 2),
        )
        timeline.submitPrepared(runBlocking {
            MessageLayoutPrecomputer(bubbles = true).prepare(rows, timeline.width, density, 1f, false)
        })
        settle()
    }

    private fun settle() = repeat(100) { ShadowLooper.idleMainLooper(16, TimeUnit.MILLISECONDS) }

    private fun touch(action: Int, x: Float, y: Float) {
        // Fixed event times: the drag reads where the finger is, not when.
        val event = MotionEvent.obtain(0L, 0L, action, x, y, 0)
        timeline.dispatchTouchEvent(event)
        event.recycle()
    }

    @Test fun `a leftward drag moves the person's rows, not the agent's, and letting go brings them back`() {
        val y = timeline.viewForRow(1)!!.let { it.top + it.height / 2f }
        val x = timeline.width * 0.6f
        touch(MotionEvent.ACTION_DOWN, x, y)
        // One to one with the finger while the strip opens (the drag starts once past the touch slop).
        touch(MotionEvent.ACTION_MOVE, x - 20 * density, y)
        touch(MotionEvent.ACTION_MOVE, x - 50 * density, y)
        assertEquals(-30 * density, timeline.viewForRow(1)!!.translationX, 1f)
        for (step in 1..10) touch(MotionEvent.ACTION_MOVE, x - 50 * density - step * 30 * density, y)
        val moved = timeline.viewForRow(1)!!.translationX
        assertTrue("resisted past the strip, $moved", moved < -56 * density && moved > -112 * density)
        assertEquals("the agent's row stays", 0f, timeline.viewForRow(2)!!.translationX, 0f)
        touch(MotionEvent.ACTION_UP, x - 200 * density, y)
        settle()
        assertEquals(0f, timeline.viewForRow(1)!!.translationX, 0.5f)
    }

    @Test fun `a vertical drag leaves the rows where they are`() {
        val y = timeline.viewForRow(1)!!.let { it.top + it.height / 2f }
        touch(MotionEvent.ACTION_DOWN, 200f, y)
        for (step in 1..10) touch(MotionEvent.ACTION_MOVE, 200f - step * 2, y - step * 20 * density)
        assertEquals(0f, timeline.viewForRow(1)!!.translationX, 0f)
        touch(MotionEvent.ACTION_UP, 180f, y)
    }
}
