package surf.comma.android.tasks.ui

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.view.View
import android.view.ViewGroup
import android.view.animation.AnimationUtils
import android.widget.FrameLayout
import androidx.core.view.NestedScrollingParent3
import androidx.core.view.NestedScrollingParentHelper
import androidx.core.view.ViewCompat
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import surf.comma.android.scroll.physics.RubberBand
import surf.comma.android.scroll.physics.ScrollPhysicsConfig
import surf.comma.android.scroll.physics.SpringBack
import surf.comma.android.tasks.TaskStatusBucket

/**
 * Pull to refresh for a fluid list. The list keeps its own rubber band at the bottom and for
 * flings; only a finger dragging down past the top is taken here, through nested scrolling,
 * and stretched with the same rubber-band curve so the two edges feel alike. Releasing past
 * the threshold holds the list open under a turning glyph until [setRefreshing] is false.
 */
@SuppressLint("ViewConstructor") // Built in code only, never inflated from XML.
class TaskRefreshLayout(context: Context, theme: TaskTheme) : FrameLayout(context), NestedScrollingParent3 {
    private val parentHelper = NestedScrollingParentHelper(this)
    private val density = theme.density
    private val indicatorTint = theme.fgQuaternary
    private val indicatorSize = theme.dpInt(20f)
    private val threshold = theme.dpInt(64f)
    private val holdOffset = theme.dpInt(52f)
    private val indicator = TaskStatusIconView(context).apply {
        setStatus(TaskStatusBucket.IN_PROGRESS, indicatorTint, spin = false)
        alpha = 0f
    }
    private var target: View? = null
    /** Raw finger travel past the top; the visible offset is its rubber-banded image. */
    private var pulled = 0f
    private var offset = 0f
    private val springBack = SpringBack()
    private var settleTarget = 0f
    private var settleStartMs = -1L
    private val settleFrame = Runnable { stepSettle() }
    private var refreshing = false

    var onRefresh: (() -> Unit)? = null

    init {
        addView(indicator, LayoutParams(indicatorSize, indicatorSize))
    }

    /** The scrolling child. It must be added before the first layout. */
    fun setTarget(view: View) {
        target = view
        addView(view, 0, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    fun setRefreshing(value: Boolean) {
        if (refreshing == value) return
        refreshing = value
        indicator.setStatus(TaskStatusBucket.IN_PROGRESS, indicatorTint, spin = value)
        animateTo(if (value) holdOffset.toFloat() else 0f)
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        val x = (width - indicatorSize) / 2
        val y = target?.paddingTop ?: 0
        indicator.layout(x, y + (holdOffset - indicatorSize) / 2, x + indicatorSize, y + (holdOffset + indicatorSize) / 2)
        applyOffset()
    }

    override fun onStartNestedScroll(child: View, target: View, axes: Int, type: Int): Boolean =
        axes and ViewCompat.SCROLL_AXIS_VERTICAL != 0 && type == ViewCompat.TYPE_TOUCH && isEnabled

    override fun onNestedScrollAccepted(child: View, target: View, axes: Int, type: Int) {
        parentHelper.onNestedScrollAccepted(child, target, axes, type)
        stopSettle()
        // Picking up a held or settling list: continue from where it is, not from zero.
        pulled = RubberBand.distance(offset, range())
    }

    override fun onNestedPreScroll(target: View, dx: Int, dy: Int, consumed: IntArray, type: Int) {
        // Finger moving up while the list is pulled down: close the gap before the list scrolls.
        if (dy > 0 && offset > 0f) {
            val take = min(dy.toFloat(), pulled)
            pulled -= take
            consumed[1] = take.roundToInt()
            updatePull()
        }
    }

    override fun onNestedScroll(
        target: View,
        dxConsumed: Int,
        dyConsumed: Int,
        dxUnconsumed: Int,
        dyUnconsumed: Int,
        type: Int,
        consumed: IntArray,
    ) {
        // Finger moving down with the list already at its top.
        if (dyUnconsumed < 0 && type == ViewCompat.TYPE_TOUCH) {
            pulled += -dyUnconsumed
            consumed[1] += dyUnconsumed
            updatePull()
        }
    }

    override fun onNestedScroll(target: View, dxConsumed: Int, dyConsumed: Int, dxUnconsumed: Int, dyUnconsumed: Int, type: Int) =
        onNestedScroll(target, dxConsumed, dyConsumed, dxUnconsumed, dyUnconsumed, type, IntArray(2))

    override fun onNestedPreFling(target: View, velocityX: Float, velocityY: Float): Boolean = offset > 0f

    override fun onStopNestedScroll(target: View, type: Int) {
        parentHelper.onStopNestedScroll(target, type)
        if (type != ViewCompat.TYPE_TOUCH) return
        when {
            refreshing -> animateTo(if (offset > 0f) holdOffset.toFloat() else 0f)
            offset >= threshold -> {
                refreshing = true
                indicator.setStatus(TaskStatusBucket.IN_PROGRESS, indicatorTint, spin = true)
                animateTo(holdOffset.toFloat())
                onRefresh?.invoke()
            }
            else -> animateTo(0f)
        }
    }

    override fun getNestedScrollAxes(): Int = parentHelper.nestedScrollAxes

    private fun range(): Float = max(1f, height.toFloat())

    private fun updatePull() {
        offset = RubberBand.offset(pulled, range())
        applyOffset()
    }

    private fun applyOffset() {
        target?.translationY = offset
        indicator.alpha = min(1f, offset / threshold)
        if (!refreshing) indicator.rotation = offset / threshold * 270f
    }

    /**
     * Settles on [value] with the list's own edge spring, released exactly as the list
     * releases its rubber band: from the current stretch, with the same small start velocity.
     */
    private fun animateTo(value: Float) {
        stopSettle()
        settleTarget = value
        val stretchDp = (offset - value) / density
        if (!ValueAnimator.areAnimatorsEnabled() || abs(stretchDp) < ScrollPhysicsConfig.SPRING_VALUE_THRESHOLD) {
            setSettled(value)
            return
        }
        springBack.absorb(-stretchDp / ScrollPhysicsConfig.RELEASE_VELOCITY_DIVISOR, stretchDp)
        settleStartMs = AnimationUtils.currentAnimationTimeMillis()
        postOnAnimation(settleFrame)
    }

    private fun stepSettle() {
        if (settleStartMs < 0) return
        val step = springBack.value((AnimationUtils.currentAnimationTimeMillis() - settleStartMs).toFloat())
        if (step.isFinished) {
            setSettled(settleTarget)
            return
        }
        offset = settleTarget + step.value * density
        pulled = RubberBand.distance(offset.coerceAtLeast(0f), range())
        applyOffset()
        postOnAnimation(settleFrame)
    }

    private fun setSettled(value: Float) {
        settleStartMs = -1L
        offset = value
        pulled = RubberBand.distance(value, range())
        applyOffset()
    }

    private fun stopSettle() {
        settleStartMs = -1L
        removeCallbacks(settleFrame)
    }

    override fun onDetachedFromWindow() {
        stopSettle()
        super.onDetachedFromWindow()
    }
}
