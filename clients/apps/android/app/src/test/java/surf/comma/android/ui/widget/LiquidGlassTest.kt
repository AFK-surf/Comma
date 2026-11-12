package surf.comma.android.ui.widget

import android.graphics.Rect
import android.graphics.RectF
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LiquidGlassTest {
    @Test fun `a glass node records every shape and the margin the blur reads from`() {
        val source = glassSource(listOf(GlassShape(Rect(10, 100, 200, 160), 30f), GlassShape(Rect(210, 100, 270, 160), 30f)), 24)
        assertEquals(Rect(-14, 76, 294, 184), source)
    }

    @Test fun `a press swells a circle most and a long capsule little`() {
        assertEquals(1.47f, glassPressScale(44f, 44f), 0.001f)
        assertEquals(1.117f, glassPressScale(176f, 44f), 0.001f)
    }

    @Test fun `a drag pulls a control the way it goes and never past its reach`() {
        assertEquals(0f, glassDragPull(0f, 6f), 0f)
        assertTrue(glassDragPull(40f, 6f) in 0f..6f)
        assertEquals(-glassDragPull(40f, 6f), glassDragPull(-40f, 6f), 0f)
        assertTrue(glassDragStretch(100_000f, 6f) <= GlassPress.MAX_STRETCH)
    }

    @Test fun `a drag on pressed glass goes to the list it lies on`() {
        val context = org.robolectric.RuntimeEnvironment.getApplication()
        val events = mutableListOf<Int>()
        val glass = android.view.View(context).apply {
            val press = GlassPress(this) { _, _, _ -> }
            setOnTouchListener { _, event -> press.track(event); events += event.actionMasked; true }
        }
        val list = object : android.widget.FrameLayout(context) {
            override fun onInterceptTouchEvent(event: android.view.MotionEvent) = event.actionMasked == android.view.MotionEvent.ACTION_MOVE
        }
        list.addView(glass)
        list.measure(android.view.View.MeasureSpec.makeMeasureSpec(100, android.view.View.MeasureSpec.EXACTLY), android.view.View.MeasureSpec.makeMeasureSpec(100, android.view.View.MeasureSpec.EXACTLY))
        list.layout(0, 0, 100, 100)

        listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_MOVE).forEach { action ->
            val event = android.view.MotionEvent.obtain(0L, 0L, action, 50f, 50f, 0)
            list.dispatchTouchEvent(event)
            event.recycle()
        }

        assertEquals(listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_CANCEL), events)
    }

    @Test fun `a menu's shape leaves its control one axis at a time`() {
        val control = RectF(100f, 50f, 200f, 90f)
        val card = RectF(30f, 50f, 270f, 300f)
        val shape = RectF()

        glassMorphRect(control, card, 0f, 1f, shape)
        assertEquals(RectF(100f, 50f, 200f, 300f), shape)
        glassMorphRect(control, card, 1f, 0f, shape)
        assertEquals(RectF(30f, 50f, 270f, 90f), shape)
    }

    @Test fun `the rim follows a slim shape and stops growing on a wide card`() {
        assertEquals(13.2f, glassBand(44f, 54f), 0.001f)
        assertEquals(16.5f, glassDepth(44f, 66f), 0.001f)
        assertEquals(54f, glassBand(600f, 54f), 0f)
        assertEquals(66f, glassDepth(600f, 66f), 0f)
    }
}
