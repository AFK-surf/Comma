package surf.comma.android.scroll.widget

import android.animation.ValueAnimator
import android.app.Activity
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowSystemClock
import surf.comma.android.scroll.physics.EdgeEffectAdapter
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ScrollContainerTest {
    private fun setDurationScale(value: Float) {
        ValueAnimator::class.java.getDeclaredMethod("setDurationScale", Float::class.javaPrimitiveType).invoke(null, value)
    }

    private fun layout(view: View, width: Int = 320, height: Int = 480) {
        view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
        view.layout(0, 0, width, height)
    }

    private fun edge(view: RecyclerView, horizontal: Boolean): EdgeEffectAdapter? =
        RecyclerView::class.java.getDeclaredField(if (horizontal) "mHorizontalEdgeEffect" else "mVerticalEdgeEffect")
            .apply { isAccessible = true }.get(view) as EdgeEffectAdapter?

    private fun touch(view: View, action: Int, x: Float, y: Float, time: Long) {
        val event = MotionEvent.obtain(0, time, action, x, y, 0)
        view.dispatchTouchEvent(event)
        event.recycle()
    }

    @Test fun identicalDragsAndReleaseFramesMatchListsInBothAxesAndAtBothEdges() {
        for (axis in listOf(ScrollContainer.VERTICAL, ScrollContainer.HORIZONTAL)) {
            for (atEnd in listOf(false, true)) {
                Robolectric.buildActivity(Activity::class.java).setup().use { controller ->
                    val activity = controller.get()
                    val horizontal = axis == ScrollContainer.HORIZONTAL
                    val size = if (horizontal) 1800 to 480 else 320 to 1800
                    val container = ScrollContainer(activity).apply {
                        orientation = axis
                        addView(View(activity), FrameLayout.LayoutParams(size.first, size.second))
                    }
                    val list = RecyclerView(activity).apply {
                        layoutManager = LinearLayoutManager(activity, axis, false)
                        itemAnimator = null
                        adapter = object : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
                            override fun getItemCount() = 1
                            override fun onCreateViewHolder(parent: ViewGroup, type: Int) =
                                object : RecyclerView.ViewHolder(View(activity).apply {
                                    layoutParams = RecyclerView.LayoutParams(size.first, size.second)
                                }) {}
                            override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) = Unit
                        }
                    }
                    val root = FrameLayout(activity).apply { addView(container); addView(list) }
                    activity.setContentView(root)
                    layout(root)
                    layout(container)
                    layout(list)
                    if (atEnd) {
                        container.fullScroll(if (horizontal) View.FOCUS_RIGHT else View.FOCUS_DOWN)
                        list.scrollBy(if (horizontal) 3000 else 0, if (horizontal) 0 else 3000)
                    }
                    val sign = if (atEnd) -1 else 1
                    for (target in listOf(container, list)) touch(target, MotionEvent.ACTION_DOWN, 140f, 180f, 0)
                    for (step in 1..5) {
                        val delta = step * 22f * sign
                        for (target in listOf(container, list)) touch(target, MotionEvent.ACTION_MOVE,
                            140f + if (horizontal) delta else 0f, 180f + if (horizontal) 0f else delta, step * 20L)
                        assertEquals(edge(list, horizontal)!!.getDistance(), edge(container.scrollingView, horizontal)!!.getDistance(), 0f)
                    }
                    assertTrue("The gesture must exercise real overscroll", edge(list, horizontal)!!.getDistance() != 0f)
                    for (target in listOf(container, list)) touch(target, MotionEvent.ACTION_CANCEL, 140f, 180f, 120)
                    val canvas = Canvas(Bitmap.createBitmap(320, 480, Bitmap.Config.ARGB_8888))
                    repeat(60) {
                        ShadowSystemClock.advanceBy(Duration.ofMillis(16))
                        list.draw(canvas)
                        container.draw(canvas)
                        assertEquals(edge(list, horizontal)!!.getDistance(), edge(container.scrollingView, horizontal)!!.getDistance(), 0f)
                        assertEquals(edge(list, horizontal)!!.isFinished, edge(container.scrollingView, horizontal)!!.isFinished)
                    }
                    assertTrue(edge(list, horizontal)!!.isFinished)
                }
            }
        }
    }

    @Test fun flingTravelAndBoundaryImpactMatchListsFrameByFrame() {
        for (axis in listOf(ScrollContainer.VERTICAL, ScrollContainer.HORIZONTAL)) {
            Robolectric.buildActivity(Activity::class.java).setup().use { controller ->
                val activity = controller.get()
                val horizontal = axis == ScrollContainer.HORIZONTAL
                val itemWidth = if (horizontal) 1500 else 320
                val itemHeight = if (horizontal) 480 else 1500
                val container = ScrollContainer(activity).apply {
                    orientation = axis
                    addView(View(activity), FrameLayout.LayoutParams(itemWidth, itemHeight))
                }
                val list = RecyclerView(activity).apply {
                    layoutManager = LinearLayoutManager(activity, axis, false)
                    itemAnimator = null
                    adapter = object : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
                        override fun getItemCount() = 1
                        override fun onCreateViewHolder(parent: ViewGroup, type: Int) =
                            object : RecyclerView.ViewHolder(View(activity).apply {
                                layoutParams = RecyclerView.LayoutParams(itemWidth, itemHeight)
                            }) {}
                        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) = Unit
                    }
                }
                val root = FrameLayout(activity).apply { addView(container); addView(list) }
                activity.setContentView(root)
                layout(root)
                layout(container)
                layout(list)
                for (view in listOf(container.scrollingView, list)) {
                    view.scrollBy(if (horizontal) 300 else 0, if (horizontal) 0 else 300)
                    assertTrue(view.fling(if (horizontal) 5000 else 0, if (horizontal) 0 else 5000))
                }
                val canvas = Canvas(Bitmap.createBitmap(320, 480, Bitmap.Config.ARGB_8888))
                // Drive both ViewFlingers at identical frame times, without unrelated Activity
                // traversals changing the test viewport or scheduling one view a frame later.
                val flingers = listOf(container.scrollingView, list).map { view ->
                    val runnable = RecyclerView::class.java.getDeclaredField("mViewFlinger")
                        .apply { isAccessible = true }.get(view) as Runnable
                    view.removeCallbacks(runnable)
                    view to runnable
                }
                var sawImpact = false
                repeat(150) {
                    ShadowSystemClock.advanceBy(Duration.ofMillis(16))
                    flingers.forEach { (view, runnable) -> runnable.run(); view.removeCallbacks(runnable) }
                    list.draw(canvas)
                    container.draw(canvas)
                    assertEquals(list.computeHorizontalScrollOffset(), container.scrollingView.computeHorizontalScrollOffset())
                    assertEquals(list.computeVerticalScrollOffset(), container.scrollingView.computeVerticalScrollOffset())
                    val distance = edge(list, horizontal)?.getDistance() ?: 0f
                    sawImpact = sawImpact || distance != 0f
                    assertEquals(distance, edge(container.scrollingView, horizontal)?.getDistance() ?: 0f, 0f)
                }
                assertTrue("The fling must reach and spring back from a boundary", sawImpact)
                assertEquals(RecyclerView.SCROLL_STATE_IDLE, list.scrollState)
            }
        }
    }

    @Test fun wrapContentFillViewportMarginsAndDynamicContentWorkInBothAxes() {
        Robolectric.buildActivity(Activity::class.java).setup().use { controller ->
            val activity = controller.get()
            for (axis in listOf(ScrollContainer.VERTICAL, ScrollContainer.HORIZONTAL)) {
                val container = ScrollContainer(activity).apply { orientation = axis }
                val child = View(activity)
                val lp = FrameLayout.LayoutParams(110, 90).apply { setMargins(7, 11, 13, 17) }
                container.addView(child, lp)
                container.setPadding(5, 9, 15, 19)
                container.measure(View.MeasureSpec.makeMeasureSpec(320, View.MeasureSpec.AT_MOST),
                    View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.AT_MOST))
                assertEquals(150, container.measuredWidth)
                assertEquals(146, container.measuredHeight)
                container.isFillViewport = true
                // fillViewport must not expand a wrap_content container to the parent's limit.
                container.measure(View.MeasureSpec.makeMeasureSpec(320, View.MeasureSpec.AT_MOST),
                    View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.AT_MOST))
                assertEquals(150, container.measuredWidth)
                assertEquals(146, container.measuredHeight)
                layout(container)
                if (axis == ScrollContainer.VERTICAL) assertEquals(424, child.height)
                else assertEquals(280, child.width)
                container.isFillViewport = false
                child.layoutParams = lp.apply { width = if (axis == ScrollContainer.HORIZONTAL) 1200 else 110; height = if (axis == ScrollContainer.VERTICAL) 1600 else 90 }
                layout(container)
                assertEquals(if (axis == ScrollContainer.HORIZONTAL) 1200 else 110, child.width)
                assertEquals(if (axis == ScrollContainer.VERTICAL) 1600 else 90, child.height)
                assertTrue(container.fullScroll(if (axis == ScrollContainer.HORIZONTAL) View.FOCUS_RIGHT else View.FOCUS_DOWN))
            }
        }
    }

    @Test fun focusesOffscreenDescendantsAndKeepsThemVisibleAfterKeyboardResizeAndPadding() {
        Robolectric.buildActivity(Activity::class.java).setup().use { controller ->
            val activity = controller.get()
            for (axis in listOf(ScrollContainer.VERTICAL, ScrollContainer.HORIZONTAL)) {
                val horizontal = axis == ScrollContainer.HORIZONTAL
                val row = LinearLayout(activity).apply { orientation = axis }
                row.addView(View(activity), LinearLayout.LayoutParams(if (horizontal) 900 else 200, if (horizontal) 80 else 900))
                val editor = EditText(activity)
                row.addView(editor, LinearLayout.LayoutParams(140, 70))
                row.addView(View(activity), LinearLayout.LayoutParams(if (horizontal) 300 else 200, if (horizontal) 80 else 400))
                val container = ScrollContainer(activity).apply { orientation = axis; addView(row) }
                activity.setContentView(container)
                layout(container)
                assertTrue(editor.requestFocus())
                assertVisible(container, editor)
                layout(container, 220, 240)
                assertVisible(container, editor)
                container.setPadding(20, 16, 35, 60)
                layout(container, 220, 240)
                assertVisible(container, editor)
            }
        }
    }

    private fun assertVisible(container: ScrollContainer, view: View) {
        val rect = Rect(0, 0, view.width, view.height)
        container.offsetDescendantRectToMyCoords(view, rect)
        if (container.orientation == ScrollContainer.VERTICAL) {
            assertTrue("$rect must fit height ${container.height}", rect.top >= container.paddingTop && rect.bottom <= container.height - container.paddingBottom)
        } else {
            assertTrue("$rect must fit width ${container.width}", rect.left >= container.paddingLeft && rect.right <= container.width - container.paddingRight)
        }
    }

    @Test fun disabledAnimationsFinishReleaseImpactAndAnAlreadyRunningSpring() {
        Robolectric.buildActivity(Activity::class.java).setup().use { controller ->
            val edge = EdgeEffectAdapter(controller.get()).apply { updateViewportRange(480) }
            try {
                setDurationScale(1f)
                edge.onPullDistance(-100f, false)
                assertTrue(edge.getDistance() != 0f)
                setDurationScale(0f)
                edge.onRelease()
                assertEquals(0f, edge.getDistance(), 0f)
                assertTrue(edge.isFinished)
                edge.onAbsorb(2400)
                assertTrue(edge.isFinished)
                setDurationScale(1f)
                edge.onPullDistance(-100f, false)
                edge.onRelease()
                setDurationScale(0f)
                assertFalse(edge.computeScrollOffset())
                assertEquals(0f, edge.getDistance(), 0f)
                assertTrue(edge.isFinished)
            } finally { setDurationScale(1f) }
        }
    }

    @Test fun horizontalStripLetsVerticalAncestorDragAndRetainsHorizontalGestures() {
        Robolectric.buildActivity(Activity::class.java).setup().use { controller ->
            val activity = controller.get()
            val strip = ScrollContainer(activity).apply {
                orientation = ScrollContainer.HORIZONTAL
                addView(View(activity), FrameLayout.LayoutParams(1500, 120))
            }
            val column = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(strip, LinearLayout.LayoutParams(320, 120))
                addView(View(activity), LinearLayout.LayoutParams(320, 1600))
            }
            val parent = ScrollContainer(activity).apply { addView(column) }
            activity.setContentView(parent)
            layout(parent)
            touch(parent, MotionEvent.ACTION_DOWN, 220f, 100f, 0)
            repeat(5) { touch(parent, MotionEvent.ACTION_MOVE, 220f - (it + 1) * 20, 100f - (it + 1) * 2, (it + 1) * 20L) }
            assertTrue(strip.scrollingView.computeHorizontalScrollOffset() > 0)
            assertEquals(0, parent.scrollingView.computeVerticalScrollOffset())
            touch(parent, MotionEvent.ACTION_CANCEL, 120f, 90f, 120)
            val offset = strip.scrollingView.computeHorizontalScrollOffset()
            touch(parent, MotionEvent.ACTION_DOWN, 220f, 100f, 0)
            repeat(5) { touch(parent, MotionEvent.ACTION_MOVE, 220f - (it + 1) * 2, 100f - (it + 1) * 20, (it + 1) * 20L) }
            assertTrue(parent.scrollingView.computeVerticalScrollOffset() > 0)
            assertEquals(offset, strip.scrollingView.computeHorizontalScrollOffset())
            touch(parent, MotionEvent.ACTION_CANCEL, 210f, 0f, 120)
        }
    }

    @Test fun scrollOffsetRestoresBeforeLayoutReportsMovesAndFollowsContentThatShrinks() {
        Robolectric.buildActivity(Activity::class.java).setup().use { controller ->
            val activity = controller.get()
            val content = View(activity)
            val reported = mutableListOf<Int>()
            val strip = ScrollContainer(activity).apply {
                orientation = ScrollContainer.HORIZONTAL
                addView(content, FrameLayout.LayoutParams(1500, 120))
                onScrollOffsetChanged = { reported += it }
            }
            activity.setContentView(FrameLayout(activity).apply { addView(strip) })
            strip.scrollOffset = 400
            assertEquals("readable before the first layout", 400, strip.scrollOffset)
            layout(strip, 320, 120)
            assertEquals(400, strip.scrollOffset)
            assertEquals("the content really moved", -400, (content.parent as View).left)
            assertEquals(listOf(400), reported)
            strip.scrollingView.scrollBy(100, 0)
            assertEquals(500, strip.scrollOffset)
            assertEquals(listOf(400, 500), reported)
            // Narrower content: the offset is clamped to the new end, and the clamp is reported.
            content.layoutParams = content.layoutParams.apply { width = 700 }
            layout(strip, 320, 120)
            assertEquals(380, strip.scrollOffset)
            assertEquals(listOf(400, 500, 380), reported)
            strip.scrollOffset = 9999
            layout(strip, 320, 120)
            assertEquals(380, strip.scrollOffset)
            strip.scrollOffset = 0
            layout(strip, 320, 120)
            assertEquals(0, strip.scrollOffset)
            assertTrue(strip.canScroll)
        }
    }

    @Test fun containerThatFitsYieldsTheWholeGestureOnlyWhenAskedTo() {
        Robolectric.buildActivity(Activity::class.java).setup().use { controller ->
            val activity = controller.get()
            for (yields in listOf(false, true)) {
                var parentSaw = 0
                val strip = ScrollContainer(activity).apply {
                    orientation = ScrollContainer.HORIZONTAL
                    yieldsWhenContentFits = yields
                    addView(View(activity), FrameLayout.LayoutParams(200, 120))
                }
                val parent = object : FrameLayout(activity) {
                    override fun onTouchEvent(event: MotionEvent): Boolean { parentSaw++; return true }
                }.apply { addView(strip, FrameLayout.LayoutParams(320, 120)) }
                activity.setContentView(parent)
                layout(parent, 320, 120)
                assertFalse(strip.canScroll)
                touch(parent, MotionEvent.ACTION_DOWN, 100f, 60f, 0)
                touch(parent, MotionEvent.ACTION_MOVE, 200f, 60f, 16)
                touch(parent, MotionEvent.ACTION_UP, 200f, 60f, 32)
                // Only a yielding strip lets the page see the gesture at all.
                assertEquals(if (yields) 3 else 0, parentSaw)
                // Once its content is wider, it scrolls again, yielding or not.
                val wide = View(activity)
                strip.removeAllViews()
                strip.addView(wide, FrameLayout.LayoutParams(900, 120))
                layout(parent, 320, 120)
                assertTrue(strip.canScroll)
                parentSaw = 0
                touch(parent, MotionEvent.ACTION_DOWN, 200f, 60f, 100)
                repeat(4) { touch(parent, MotionEvent.ACTION_MOVE, 200f - (it + 1) * 30, 60f, 116L + it * 16) }
                touch(parent, MotionEvent.ACTION_CANCEL, 80f, 60f, 200)
                assertTrue(strip.scrollOffset > 0)
                assertEquals(0, parentSaw)
            }
        }
    }

    @Test fun rightToLeftOffsetsCountFromTheStartEdgeForRestoreCallbackClampAndDrags() {
        Robolectric.buildActivity(Activity::class.java).setup().use { controller ->
            val activity = controller.get()
            // This module's test manifest does not declare supportsRtl; without it every view is LTR.
            activity.applicationInfo.flags = activity.applicationInfo.flags or ApplicationInfo.FLAG_SUPPORTS_RTL
            val content = View(activity)
            val reported = mutableListOf<Int>()
            val strip = ScrollContainer(activity).apply {
                orientation = ScrollContainer.HORIZONTAL
                layoutDirection = View.LAYOUT_DIRECTION_RTL
                addView(content, FrameLayout.LayoutParams(1500, 120))
                onScrollOffsetChanged = { reported += it }
            }
            activity.setContentView(FrameLayout(activity).apply { addView(strip) })
            layout(strip, 320, 120)
            val host = content.parent as View
            assertEquals("the fixture must really be right-to-left", View.LAYOUT_DIRECTION_RTL, strip.layoutDirection)
            // At rest the start is the right edge.
            assertEquals(0, strip.scrollOffset)
            assertEquals(320, host.right)
            // Restore: the content moves right by the offset, and reads back the same.
            strip.scrollOffset = 400
            assertEquals(400, strip.scrollOffset)
            layout(strip, 320, 120)
            assertEquals(400, strip.scrollOffset)
            assertEquals(720, host.right)
            assertEquals(listOf(400), reported)
            // A finger moving right reveals more of the end: the offset grows, as in LTR.
            touch(strip, MotionEvent.ACTION_DOWN, 100f, 60f, 0)
            repeat(5) { touch(strip, MotionEvent.ACTION_MOVE, 100f + (it + 1) * 30, 60f, (it + 1) * 16L) }
            touch(strip, MotionEvent.ACTION_CANCEL, 250f, 60f, 100)
            assertTrue(strip.scrollOffset > 400)
            assertEquals(strip.scrollOffset, reported.last())
            // Past the end: clamped to content minus viewport, and that is reported.
            strip.scrollOffset = 5000
            layout(strip, 320, 120)
            assertEquals(1180, strip.scrollOffset)
            assertEquals(1180, reported.last())
            // Narrower content clamps an offset that no longer fits.
            content.layoutParams = content.layoutParams.apply { width = 700 }
            layout(strip, 320, 120)
            assertEquals(380, strip.scrollOffset)
            assertEquals(380, reported.last())
            assertEquals(320 + 380, host.right)
        }
    }
}
