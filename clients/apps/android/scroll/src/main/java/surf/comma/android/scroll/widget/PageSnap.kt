package surf.comma.android.scroll.widget

import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.animation.AnimationUtils
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Pages a horizontal [RecyclerView] whose items are each as wide as it. A fling moves one page from where the drag
 * began, in the fling's direction; a release without a fling settles on the nearest page. Either way the page leaves
 * the finger at the finger's speed and springs to rest; a touch catches it on the way. [onPage] hears the page under
 * the finger while it drags, then the page the pager goes to as soon as the finger lifts.
 */
class PageSnap(
    private val pager: RecyclerView,
    private val stiffness: Float,
    private val dampingRatio: Float,
    private val onPage: (Int) -> Unit,
) : RecyclerView.OnFlingListener() {
    /** The page the pager shows, or settles on once the finger has lifted. */
    var page = 0
        private set
    private var dragFrom = 0
    private var dragging = false
    /** The finger's speed, which a release too slow for [onFling] still hands to the settle. */
    private val tracker = VelocityTracker.obtain()
    /** The settle under way, stepped once a frame on the clock the list's own scrolling runs on. */
    private var settling: Settle? = null

    private inner class Settle(val from: Int, val to: Int, val curve: SpringCurve) : Runnable {
        /** The first frame's time: the settle runs on frame times alone, so its first step is a whole frame. */
        var start = -1L

        override fun run() {
            if (settling !== this) return
            val now = AnimationUtils.currentAnimationTimeMillis()
            if (start < 0) start = now - FRAME_MS
            val seconds = (now - start) / 1000.0
            if (curve.settled(seconds)) {
                settling = null
                scrollTo(to)
                return
            }
            scrollTo(from + ((to - from) * curve.at(seconds)).roundToInt())
            pager.postOnAnimation(this)
        }
    }

    init {
        pager.onFlingListener = this
        pager.addOnItemTouchListener(object : RecyclerView.SimpleOnItemTouchListener() {
            override fun onInterceptTouchEvent(rv: RecyclerView, e: MotionEvent): Boolean {
                if (e.actionMasked == MotionEvent.ACTION_DOWN) {
                    tracker.clear()
                    // The finger catches a settling page where it is.
                    settling = null
                }
                tracker.addMovement(e)
                // A touch that caught the page and let go without dragging settles it from where it stopped.
                val up = e.actionMasked == MotionEvent.ACTION_UP || e.actionMasked == MotionEvent.ACTION_CANCEL
                if (up && !dragging && settling == null && pager.width > 0 && offset() % pager.width != 0) {
                    pager.post { if (!dragging && settling == null) settle(nearest(), 0f) }
                }
                return false
            }
        })
        pager.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrollStateChanged(recyclerView: RecyclerView, newState: Int) {
                when (newState) {
                    RecyclerView.SCROLL_STATE_DRAGGING -> { dragFrom = page; dragging = true }
                    RecyclerView.SCROLL_STATE_IDLE -> if (dragging) {
                        // A release too slow to fling still moves at the finger's speed.
                        dragging = false
                        settle(nearest(), fingerVelocity())
                    }
                }
            }

            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                if (pager.scrollState == RecyclerView.SCROLL_STATE_DRAGGING) turnTo(nearest())
            }
        })
    }

    /** Shows [index] at once, as the page the pager opens on. */
    fun show(index: Int) {
        page = index.coerceIn(0, lastIndex())
        (pager.layoutManager as? LinearLayoutManager)?.scrollToPositionWithOffset(page, 0)
    }

    /** Goes to [index] the way a swipe settles. */
    fun go(index: Int) {
        if (pager.width > 0) settle(index.coerceIn(0, lastIndex()), 0f)
    }

    override fun onFling(velocityX: Int, velocityY: Int): Boolean {
        val width = pager.width
        if (width == 0 || pager.adapter == null) return false
        dragging = false
        settle(target(offset(), width, velocityX.toFloat(), dragFrom, lastIndex()), velocityX.toFloat())
        // The spring moves the page from here; the list itself comes to rest under it.
        pager.stopScroll()
        return true
    }

    /** The finger's speed in the scroll's direction, in pixels per second. */
    private fun fingerVelocity(): Float {
        tracker.computeCurrentVelocity(1000)
        return -tracker.xVelocity
    }

    private fun lastIndex() = ((pager.adapter?.itemCount ?: 1) - 1).coerceAtLeast(0)

    private fun offset() = pager.computeHorizontalScrollOffset()

    private fun scrollTo(x: Int) {
        val by = x - offset()
        if (by != 0) pager.scrollBy(by, 0)
    }

    private fun nearest() = if (pager.width == 0) page else (offset().toFloat() / pager.width).roundToInt().coerceIn(0, lastIndex())

    private fun turnTo(target: Int) {
        if (target == page) return
        page = target
        onPage(target)
    }

    private fun settle(target: Int, velocity: Float) {
        turnTo(target)
        val from = offset()
        val to = target * pager.width
        settling = null
        if (to == from) return
        val settle = Settle(from, to, SpringCurve(stiffness, dampingRatio, velocity / (to - from)))
        settling = settle
        pager.postOnAnimation(settle)
    }

    companion object {
        /** A frame at 60 a second, the first step of a settle, so the page moves on its first frame. */
        private const val FRAME_MS = 16L

        /**
         * The page a fling from [offset] at [velocity] goes to: the next page in its direction, never further than one
         * page from [from], where the drag began.
         */
        fun target(offset: Int, width: Int, velocity: Float, from: Int, lastIndex: Int): Int {
            val position = offset.toFloat() / width
            val next = when {
                velocity > 0 -> floor(position).toInt() + 1
                velocity < 0 -> floor(position).toInt().let { if (position - it < 0.001f) it - 1 else it }
                else -> position.roundToInt()
            }
            return next.coerceIn(from - 1, from + 1).coerceIn(0, lastIndex)
        }

    }
}

/**
 * A unit-mass spring's way from 0 to 1, leaving 0 at [startVelocity] (in distances per second), so a settle keeps the
 * finger's speed. A start faster than the spring's own pace would carry the page past its rest and back, so such a
 * start gets a critically damped spring of that pace instead, which glides in.
 */
internal class SpringCurve(stiffness: Float, dampingRatio: Float, startVelocity: Float) {
    private val quick = startVelocity > sqrt(stiffness)
    private val omega = if (quick) startVelocity.toDouble() else sqrt(stiffness.toDouble())
    private val zeta = if (quick) 1.0 else dampingRatio.toDouble()
    private val velocity = startVelocity.toDouble()

    /** Where the spring is after [t] seconds. */
    fun at(t: Double): Double {
        val v = velocity
        return when {
            zeta < 1 -> {
                val damped = omega * sqrt(1 - zeta * zeta)
                1 + exp(-zeta * omega * t) * (-cos(damped * t) + (v - zeta * omega) / damped * sin(damped * t))
            }
            zeta == 1.0 -> 1 + exp(-omega * t) * (-1 + (v - omega) * t)
            else -> {
                val root = omega * sqrt(zeta * zeta - 1)
                val fast = -zeta * omega - root
                val slow = -zeta * omega + root
                // y = a e^(fast t) + b e^(slow t), y(0) = -1, y'(0) = v
                val a = (v + slow) / (fast - slow)
                1 + a * exp(fast * t) + (-1 - a) * exp(slow * t)
            }
        }
    }

    /** Whether the spring has come to rest, within a thousandth of the way and nearly still, by [t] seconds. */
    fun settled(t: Double): Boolean {
        val step = 0.001
        return abs(1 - at(t)) < 0.001 && abs(at(t + step) - at(t)) / step < 0.01 * omega || t > 2
    }
}
