package surf.comma.android.scroll.widget

import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import surf.comma.android.scroll.physics.RubberBand
import surf.comma.android.scroll.physics.VelocityTracker
import surf.comma.android.scroll.physics.VelocityTrackerFactory
import kotlin.math.abs

/**
 * A sideways drag that pulls content open toward the leading edge to uncover a strip of [range] px beside it, as
 * Messages' drag to show times: it starts only for a leftward, mostly horizontal drag past the touch slop, then
 * follows the finger one to one until the strip is open and rubber-bands past it. The host owns where the content is
 * ([travel], set through [moveTo]) and how it returns: [onRelease] hands it the travel's speed as the finger let go, in
 * px/s (negative while the finger was closing it).
 *
 * The host's `onInterceptTouchEvent` asks [intercepts] first and its `onTouchEvent` asks [onTouch] first.
 */
class RevealDrag(
    private val host: View,
    private val range: Float,
    /** Whether a drag may start now, e.g. only while the list is not scrolling. */
    private val canStart: () -> Boolean,
    /** Where the content is now, in px toward the leading edge. */
    private val travel: () -> Float,
    /** Puts the content at the given travel; called on every move. */
    private val moveTo: (Float) -> Unit,
    private val onRelease: (travelVelocity: Float) -> Unit,
) {
    private val slop = ViewConfiguration.get(host.context).scaledTouchSlop
    private val velocity: VelocityTracker = VelocityTrackerFactory.create(host.context)
    private var downX = 0f
    private var downY = 0f
    private var dragging = false

    /** Whether the drag takes over the touch, from the host's intercept. */
    fun intercepts(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x; downY = event.y; dragging = false
                velocity.clear()
            }
            MotionEvent.ACTION_MOVE -> if (!dragging) {
                val dx = event.x - downX
                val dy = event.y - downY
                if (dx < -slop && abs(dx) > abs(dy) * 1.6f && canStart()) {
                    dragging = true
                    // Tracking starts here and from where the content is: content grabbed on its way back stays under
                    // the finger.
                    downX = event.x + pull(travel())
                    host.parent?.requestDisallowInterceptTouchEvent(true)
                }
            }
        }
        velocity.addMovement(event)
        return dragging
    }

    /** Moves the content with the finger once the drag owns the touch; false when it does not. */
    fun onTouch(event: MotionEvent): Boolean {
        if (!dragging) return false
        velocity.addMovement(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_MOVE -> moveTo(travelFor((downX - event.x).coerceAtLeast(0f)))
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                dragging = false
                velocity.computeCurrentVelocity(1000, Float.MAX_VALUE)
                // The travel grows as the finger moves left.
                val speed = -velocity.getXVelocity(0)
                // Samples all at one instant give no speed.
                onRelease(if (event.actionMasked == MotionEvent.ACTION_UP && speed.isFinite()) speed else 0f)
                velocity.clear()
            }
        }
        return true
    }

    /** One to one until the strip is open, then rubber-banded. */
    private fun travelFor(pull: Float): Float =
        if (pull <= range) pull else range + RubberBand.offset(pull - range, range)

    /** The pull that puts the content at [travel]: [travelFor]'s inverse. */
    private fun pull(travel: Float): Float =
        if (travel <= range) travel else range + RubberBand.distance(travel - range, range)
}
