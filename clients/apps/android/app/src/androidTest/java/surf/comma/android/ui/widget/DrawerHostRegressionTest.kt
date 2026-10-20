package surf.comma.android.ui.widget

import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.EditText
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

class DrawerHostRegressionTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun onMain(block: () -> Unit) = instrumentation.runOnMainSync(block)

    private class Fixture(val host: DrawerHostLayout, val page: FrameLayout, val panel: View, val scrim: View)
    private fun fixture(): Fixture {
        val context = instrumentation.targetContext
        val host = DrawerHostLayout(context)
        val page = FrameLayout(context).apply { isClickable = true }
        val scrim = View(context).apply { isClickable = true }
        val panel = View(context).apply { isClickable = true }
        for (view in listOf(page, scrim, panel)) host.addView(view, FrameLayout.LayoutParams(-1, -1))
        host.bind(panel, scrim, listOf(page)) { }
        host.measure(View.MeasureSpec.makeMeasureSpec(720, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(1200, View.MeasureSpec.EXACTLY))
        host.layout(0, 0, 720, 1200)
        return Fixture(host, page, panel, scrim)
    }

    private fun drag(host: DrawerHostLayout, x: Float, y: Float, dx: Float, dy: Float = 0f, finish: Boolean = true) {
        val now = SystemClock.uptimeMillis()
        fun send(action: Int, px: Float, py: Float, time: Long) {
            val event = MotionEvent.obtain(now, time, action, px, py, 0)
            host.dispatchTouchEvent(event)
            event.recycle()
        }
        send(MotionEvent.ACTION_DOWN, x, y, now)
        for (i in 1..8) send(MotionEvent.ACTION_MOVE, x + dx * i / 8, y + dy * i / 8, now + i * 25)
        if (finish) send(MotionEvent.ACTION_UP, x + dx, y + dy, now + 225)
    }

    @Test fun rightDragFromPageCenterMovesDrawerContentAndScrimTogether() = onMain {
        val f = fixture()
        drag(f.host, 330f, 400f, 280f, finish = false)
        assertTrue(f.host.drawerProgress > 0.1f)
        assertEquals(f.panel.width * f.host.drawerProgress / 3f, f.page.translationX, 1f)
        assertEquals(f.host.drawerProgress, f.scrim.alpha, 0.001f)
        val expectedWidth = minOf(720 * 0.84f, 320 * f.host.resources.displayMetrics.density)
        assertEquals(expectedWidth, f.panel.width.toFloat(), 1f)
    }

    @Test fun verticalAndDiagonalScrollingDoesNotOpenDrawer() = onMain {
        val f = fixture()
        drag(f.host, 330f, 400f, 120f, 180f)
        assertEquals(0f, f.host.drawerProgress, 0f)
    }

    @Test fun customHorizontalRegionKeepsItsDrag() = onMain {
        val f = fixture()
        val region = object : View(f.host.context), HorizontalDragRegion {
            override fun ownsHorizontalDragAt(x: Float, y: Float) = true
        }.apply { isClickable = true }
        f.page.addView(region, FrameLayout.LayoutParams(720, 800))
        f.page.measure(View.MeasureSpec.makeMeasureSpec(720, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(1200, View.MeasureSpec.EXACTLY))
        f.page.layout(0, 0, 720, 1200)
        drag(f.host, 330f, 400f, 280f)
        assertEquals(0f, f.host.drawerProgress, 0f)
    }

    @Test fun settingsOverlayBlocksFullPageGesture() = onMain {
        val f = fixture()
        f.host.canStartDrag = { false }
        drag(f.host, 330f, 400f, 280f)
        assertEquals(0f, f.host.drawerProgress, 0f)
    }

    @Test fun inputKeepsItsSelectionGesture() = onMain {
        val f = fixture()
        f.page.addView(EditText(f.host.context), FrameLayout.LayoutParams(720, 800))
        f.page.measure(View.MeasureSpec.makeMeasureSpec(720, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(1200, View.MeasureSpec.EXACTLY))
        f.page.layout(0, 0, 720, 1200)
        drag(f.host, 330f, 400f, 280f)
        assertEquals(0f, f.host.drawerProgress, 0f)
    }

    @Test fun excludedPageAreaNeverPullsTheDrawer() = onMain {
        val f = fixture()
        f.host.excludesDragAt = { _, y -> y > 1000f }
        drag(f.host, 330f, 1100f, 280f)
        assertEquals(0f, f.host.drawerProgress, 0f)
        drag(f.host, 330f, 400f, 280f, finish = false)
        assertTrue(f.host.drawerProgress > 0.1f)
    }

    @Test fun openDrawerKeepsItsOwnHorizontalStripButScrimDragCloses() = onMain {
        val f = fixture()
        f.host.restoreOpen()
        f.host.layout(0, 0, 720, 1200)
        // The drawer's own sideways strip, over part of the panel.
        val strip = object : View(f.host.context), HorizontalDragRegion {
            override fun ownsHorizontalDragAt(x: Float, y: Float) = true
        }
        val panel = FrameLayout(f.host.context).apply { addView(strip, FrameLayout.LayoutParams(-1, 200)) }
        f.host.removeView(f.panel)
        f.host.addView(panel, FrameLayout.LayoutParams(-1, -1))
        f.host.bind(panel, f.scrim, listOf(f.page)) { }
        f.host.restoreOpen()
        f.host.measure(View.MeasureSpec.makeMeasureSpec(720, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(1200, View.MeasureSpec.EXACTLY))
        f.host.layout(0, 0, 720, 1200)
        drag(f.host, 300f, 100f, -250f, finish = false)
        assertEquals("the strip keeps its drag", 1f, f.host.drawerProgress, 0f)
        drag(f.host, 300f, 600f, -250f, finish = false)
        assertTrue("elsewhere on the panel a left drag closes", f.host.drawerProgress < 1f)
    }

    @Test fun rtlDrawerOpensFromRightAndContentFollowsLeft() = onMain {
        val f = fixture()
        f.host.layoutDirection = View.LAYOUT_DIRECTION_RTL
        f.host.requestLayout()
        f.host.layout(0, 0, 720, 1200)
        drag(f.host, 400f, 400f, -280f, finish = false)
        assertTrue(f.host.drawerProgress > 0.1f)
        assertEquals(-f.panel.width * f.host.drawerProgress / 3f, f.page.translationX, 1f)
    }

    @Test fun closingAndReopeningMidSettleKeepsPositionContinuous() {
        lateinit var f: Fixture
        onMain { f = fixture(); f.host.restoreOpen(); f.host.layout(0, 0, 720, 1200); f.host.close() }
        SystemClock.sleep(80)
        onMain {
            val before = f.panel.left
            assertTrue(f.host.drawerProgress < 1f)
            f.host.open()
            assertEquals(before, f.panel.left)
        }
        SystemClock.sleep(1500)
        onMain {
            assertEquals(1f, f.host.drawerProgress, 0.01f)
            assertEquals(0, f.panel.left)
            assertEquals(f.panel.width / 3f, f.page.translationX, 1f)
        }
    }

    @Test fun resizeDuringCloseSettlesAtNewAnchor() {
        lateinit var f: Fixture
        onMain { f = fixture(); f.host.restoreOpen(); f.host.layout(0, 0, 720, 1200); f.host.close() }
        SystemClock.sleep(80)
        onMain {
            f.host.measure(View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.EXACTLY))
            f.host.layout(0, 0, 480, 1000)
        }
        SystemClock.sleep(1500)
        onMain {
            assertEquals(-f.panel.width, f.panel.left)
            assertEquals(0f, f.page.translationX, 0f)
            assertEquals(View.GONE, f.scrim.visibility)
            assertFalse(f.host.isOpen)
        }
    }
}
