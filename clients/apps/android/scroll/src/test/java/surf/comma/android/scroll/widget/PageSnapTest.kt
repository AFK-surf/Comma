package surf.comma.android.scroll.widget

import android.app.Activity
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowChoreographer
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class PageSnapTest {
    private val width = 1000

    @Test
    fun aFlingMovesOnePageFromWhereTheDragBegan() {
        // A hard fling a little way into the next page does not skip past it.
        assertEquals(3, PageSnap.target(2_100, width, 8_000f, from = 2, lastIndex = 7))
        assertEquals(1, PageSnap.target(1_900, width, -8_000f, from = 2, lastIndex = 7))
        // A short flick still turns the page, though the drag moved less than half of it.
        assertEquals(3, PageSnap.target(2_050, width, 600f, from = 2, lastIndex = 7))
        // Flinging back after dragging forward returns to where the drag began.
        assertEquals(2, PageSnap.target(2_400, width, -600f, from = 2, lastIndex = 7))
        assertEquals(0, PageSnap.target(0, width, -600f, from = 0, lastIndex = 7))
        assertEquals(7, PageSnap.target(7_000, width, 600f, from = 7, lastIndex = 7))
    }

    @Test
    fun theSettleLeavesAtTheFingersSpeedAndRestsOnThePage() {
        val dt = 1e-5
        for (velocity in floatArrayOf(-4f, 0f, 2f, 12f, 80f)) {
            val curve = SpringCurve(275f, 0.9f, velocity)
            assertEquals(0.0, curve.at(0.0), 1e-9)
            assertEquals(velocity.toDouble(), (curve.at(dt) - curve.at(0.0)) / dt, 0.01 * maxOf(1f, velocity))
            val rest = (1..2000).first { curve.settled(it / 1000.0) } / 1000.0
            assertTrue("$velocity settles at $rest", rest in 0.05..1.0)
            assertEquals(1.0, curve.at(rest), 0.001)
        }
        // A fling far faster than the spring glides in without passing the page.
        val hard = SpringCurve(275f, 0.9f, 80f)
        assertTrue((0..1000).all { hard.at(it / 1000.0) <= 1.0 + 1e-9 })
    }

    /** Drags a five-page pager by [by] pixels over [moveFrames] frames, holds still for [stillFrames], lets go, and lists the offsets of the frames after. */
    private fun release(by: Float, moveFrames: Int, stillFrames: Int): Pair<List<Int>, Int> {
        // One frame each 16 ms of the test's clock, as on a device, rather than every frame due at once.
        ShadowChoreographer.setPaused(true)
        ShadowChoreographer.setFrameDelay(Duration.ofMillis(16))
        Robolectric.buildActivity(Activity::class.java).setup().use { controller ->
            val activity = controller.get()
            val pager = RecyclerView(activity).apply {
                layoutManager = LinearLayoutManager(activity, LinearLayoutManager.HORIZONTAL, false)
                adapter = object : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
                    override fun getItemCount() = 5
                    override fun onCreateViewHolder(parent: ViewGroup, type: Int) = object : RecyclerView.ViewHolder(View(activity).apply {
                        layoutParams = RecyclerView.LayoutParams(RecyclerView.LayoutParams.MATCH_PARENT, RecyclerView.LayoutParams.MATCH_PARENT)
                    }) {}
                    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) = Unit
                }
            }
            activity.setContentView(pager, ViewGroup.LayoutParams(width, 300))
            val snap = PageSnap(pager, 275f, 0.9f) {}
            val looper = shadowOf(Looper.getMainLooper())
            looper.idleFor(Duration.ofMillis(32))
            // The touches carry the test's own frame times, so the finger's speed is the same on every run.
            var now = 0L
            fun frame() { looper.idleFor(Duration.ofMillis(16)); now += 16 }
            fun touch(action: Int, x: Float) = MotionEvent.obtain(0L, now, action, x, 150f, 0).also {
                pager.dispatchTouchEvent(it); it.recycle()
            }
            touch(MotionEvent.ACTION_DOWN, 800f)
            for (i in 1..moveFrames) { frame(); touch(MotionEvent.ACTION_MOVE, 800f - by * i / moveFrames) }
            repeat(stillFrames) { frame(); touch(MotionEvent.ACTION_MOVE, 800f - by) }
            val atRelease = pager.computeHorizontalScrollOffset()
            touch(MotionEvent.ACTION_UP, 800f - by)
            val offsets = listOf(atRelease) + List(60) { frame(); pager.computeHorizontalScrollOffset() }
            return offsets to snap.page
        }
    }

    @Test
    fun aReleaseShortOfHalfAPageSpringsBackOverFrames() {
        val (offsets, page) = release(by = 320f, moveFrames = 20, stillFrames = 10)
        assertEquals(0, page)
        assertEquals(offsets.toString(), 0, offsets.last())
        // It glides back over several frames, never past its rest and never jumping.
        val moving = offsets.zipWithNext().count { (a, b) -> a != b }
        assertTrue(offsets.toString(), moving >= 8)
        assertTrue(offsets.toString(), offsets.zipWithNext().all { (a, b) -> b <= a + 1 && a - b < 120 })
    }

    @Test
    fun aReleaseWhileMovingKeepsTheFingersSpeed() {
        // The finger moves 24 px a frame when it lets go, too slow to fling but past half a page.
        val (offsets, page) = release(by = 600f, moveFrames = 25, stillFrames = 0)
        assertEquals(1, page)
        assertEquals(offsets.toString(), width, offsets.last())
        val first = offsets[1] - offsets[0]
        assertTrue(offsets.toString(), first in 12..40)
        assertTrue(offsets.toString(), offsets.zipWithNext().all { (a, b) -> b >= a - 1 && b <= width + 1 })
    }
}
