package surf.comma.android.tasks.ui

import android.annotation.SuppressLint
import android.content.Context
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.widget.FrameLayout
import androidx.core.view.NestedScrollingParent3
import androidx.core.view.NestedScrollingParentHelper
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.dynamicanimation.animation.FloatPropertyCompat
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring

/**
 * A bottom sheet that opens part way up the screen ([openFraction], half by default) and can be
 * dragged to full height or down to dismiss. The sheet moves by translation only, so dragging never re-lays out its content.
 *
 * A drag that starts on the sheet's grip area moves the sheet directly. A drag that starts
 * in its scrolling list is shared through nested scrolling: the sheet expands before the list
 * scrolls up, and collapses once the list is back at its top.
 */
// Built in code only, never inflated from XML. Its own touch handling is a drag, never a
// click; the scrim carries the close click.
@SuppressLint("ViewConstructor", "ClickableViewAccessibility")
class TaskSheetLayout(
    context: Context,
    theme: TaskTheme,
    /** How much of the screen the sheet covers when it opens. */
    private val openFraction: Float = 0.5f,
) : FrameLayout(context), NestedScrollingParent3 {
    private val parentHelper = NestedScrollingParentHelper(this)
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val flingVelocity = theme.dp(FLING_DP_PER_SECOND)
    private val scrim = View(context).apply {
        setBackgroundColor(theme.bgOverlay)
        alpha = 0f
        setOnClickListener { close() }
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private var sheet: View? = null
    private var gripHeight = 0
    private var topInset = 0
    /** Sheet translation; starts past the bottom edge and is clamped to it on layout. */
    private var offset = Float.MAX_VALUE
    /** Created on first use, once the offset is a real position rather than "off screen". */
    private var spring: DesignSpring<TaskSheetLayout>? = null
    private var closing = false
    private var velocity: VelocityTracker? = null
    private var draggingDirectly = false
    private var downOnGrip = false
    private var movedByNestedScroll = false
    private var downY = 0f
    private var lastY = 0f

    /** Fires once the sheet has fully left the screen. */
    var onClosed: (() -> Unit)? = null

    val isOpen: Boolean get() = isVisible && settleTarget != hiddenOffset()

    /** Open at full height, or on its way there. */
    val isExpanded: Boolean get() = isOpen && settleTarget == 0f

    /** How far the sheet's top is below where it rests at full height, in pixels. */
    val offsetPx: Float get() = offset

    private var settleTarget = 0f
    private var pendingOpen = false

    init {
        visibility = GONE
        addView(scrim, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            topInset = insets.getInsets(WindowInsetsCompat.Type.statusBars()).top
            requestLayout()
            insets
        }
    }

    /**
     * [content] is the sheet body. Touches in its top [gripHeightPx] drag the sheet directly;
     * below that they belong to the content's scrolling list.
     */
    fun setSheet(content: View, gripHeightPx: Int) {
        sheet?.let(::removeView)
        sheet = content
        gripHeight = gripHeightPx
        // Taps on the sheet's empty areas must not fall through to the scrim and close it.
        content.isClickable = true
        addView(content, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
    }

    fun open() {
        if (isOpen) return
        visibility = VISIBLE
        if (!isLaidOut || height == 0) {
            // Not measured yet: the layout pass places the sheet off screen, then opens it.
            pendingOpen = true
            requestLayout()
            return
        }
        animateTo(halfOffset())
    }

    fun close() {
        if (visibility != VISIBLE) return
        animateTo(hiddenOffset())
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        super.onMeasure(widthMeasureSpec, heightMeasureSpec)
        val content = sheet ?: return
        val sheetHeight = measuredHeight - topInset
        content.measure(
            MeasureSpec.makeMeasureSpec(measuredWidth, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(max(0, sheetHeight), MeasureSpec.EXACTLY),
        )
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        scrim.layout(0, 0, width, height)
        val content = sheet ?: return
        content.layout(0, topInset, width, height)
        // A running spring owns the offset, overshoot included; only a resting sheet is clamped.
        if (spring?.isRunning != true) offset = offset.coerceIn(0f, hiddenOffset())
        applyOffset()
        if (pendingOpen) {
            pendingOpen = false
            animateTo(halfOffset())
        }
    }

    // --- Direct drag on the grip -------------------------------------------------------------

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        // Every touch feeds the tracker, including those the list consumes, so a release after
        // a nested drag still has a velocity to settle with.
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            velocity?.recycle()
            velocity = VelocityTracker.obtain()
            movedByNestedScroll = false
        }
        velocity?.addMovement(event)
        return super.dispatchTouchEvent(event)
    }

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        val content = sheet ?: return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downY = event.y
                lastY = event.y
                draggingDirectly = false
                val sheetTop = content.top + offset
                downOnGrip = event.y >= sheetTop && event.y < sheetTop + gripHeight
                if (downOnGrip) stopSpring()
            }
            MotionEvent.ACTION_MOVE -> if (downOnGrip && abs(event.y - downY) > touchSlop) {
                draggingDirectly = true
                lastY = event.y
                return true
            }
        }
        return false
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            // Reached only when no child took the touch: the grip area, or the sheet's body.
            MotionEvent.ACTION_DOWN -> return event.y >= (sheet?.top ?: 0) + offset
            MotionEvent.ACTION_MOVE -> {
                if (!draggingDirectly && downOnGrip && abs(event.y - downY) > touchSlop) {
                    draggingDirectly = true
                    lastY = event.y
                }
                if (draggingDirectly) {
                    moveBy(event.y - lastY)
                    lastY = event.y
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> if (draggingDirectly) {
                draggingDirectly = false
                settleWithVelocity()
            }
        }
        return true
    }

    // --- Nested scrolling with the list ------------------------------------------------------

    override fun onStartNestedScroll(child: View, target: View, axes: Int, type: Int): Boolean =
        axes and ViewCompat.SCROLL_AXIS_VERTICAL != 0

    override fun onNestedScrollAccepted(child: View, target: View, axes: Int, type: Int) {
        parentHelper.onNestedScrollAccepted(child, target, axes, type)
        if (type == ViewCompat.TYPE_TOUCH) stopSpring()
    }

    override fun onNestedPreScroll(target: View, dx: Int, dy: Int, consumed: IntArray, type: Int) {
        // Finger up: expand the sheet before the list scrolls.
        if (dy > 0 && offset > 0f && type == ViewCompat.TYPE_TOUCH) {
            val take = min(dy.toFloat(), offset)
            moveBy(-take)
            consumed[1] = take.toInt()
            movedByNestedScroll = true
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
        // Finger down with the list at its top: the sheet follows the finger.
        if (dyUnconsumed < 0 && type == ViewCompat.TYPE_TOUCH) {
            moveBy(-dyUnconsumed.toFloat())
            consumed[1] += dyUnconsumed
            movedByNestedScroll = true
        }
    }

    override fun onNestedScroll(target: View, dxConsumed: Int, dyConsumed: Int, dxUnconsumed: Int, dyUnconsumed: Int, type: Int) =
        onNestedScroll(target, dxConsumed, dyConsumed, dxUnconsumed, dyUnconsumed, type, IntArray(2))

    /** While the sheet is not fully open, a fling settles the sheet instead of the list. */
    override fun onNestedPreFling(target: View, velocityX: Float, velocityY: Float): Boolean =
        offset > 0f || movedByNestedScroll

    override fun onStopNestedScroll(target: View, type: Int) {
        parentHelper.onStopNestedScroll(target, type)
        if (type == ViewCompat.TYPE_TOUCH && movedByNestedScroll) {
            movedByNestedScroll = false
            settleWithVelocity()
        }
    }

    override fun getNestedScrollAxes(): Int = parentHelper.nestedScrollAxes

    // --- Geometry ----------------------------------------------------------------------------

    private fun sheetHeight(): Float = max(1, height - topInset).toFloat()

    private fun hiddenOffset(): Float = sheetHeight()

    /** Sheet top where it opens: [openFraction] of the screen. */
    private fun halfOffset(): Float = max(0f, sheetHeight() - height * openFraction)

    private fun moveBy(delta: Float) {
        offset = (offset + delta).coerceIn(0f, hiddenOffset())
        applyOffset()
    }

    private fun applyOffset() {
        sheet?.translationY = offset
        val half = halfOffset()
        val hidden = hiddenOffset()
        // Full scrim from half height up; fades out over the last half of the way down.
        val progress = if (offset <= half) 1f else 1f - (offset - half) / max(1f, hidden - half)
        scrim.alpha = SCRIM_ALPHA * progress.coerceIn(0f, 1f)
    }

    private fun settleWithVelocity() {
        val tracker = velocity
        tracker?.computeCurrentVelocity(1000)
        val v = tracker?.yVelocity ?: 0f
        val half = halfOffset()
        val hidden = hiddenOffset()
        val target = when {
            v > flingVelocity -> if (offset < half - touchSlop) half else hidden
            v < -flingVelocity -> 0f
            offset < half / 2f -> 0f
            offset < half + (hidden - half) / 2f -> half
            else -> hidden
        }
        // The finger's speed carries into the spring, so a flick keeps its momentum.
        animateTo(target, initialVelocity = v)
    }

    private fun animateTo(target: Float, initialVelocity: Float? = null) {
        settleTarget = target
        closing = target >= hiddenOffset()
        val motion = spring ?: DesignSpring(this, OFFSET, DesignMotion.springSpatial).also { spring = it }
        motion.animateTo(target, initialVelocity)
    }

    private fun stopSpring() {
        spring?.cancel()
        closing = false
    }

    /** Called for every spring step, and once directly when animations are off. */
    private fun onSpringOffset(value: Float) {
        offset = value
        applyOffset()
        // The spring may pass the edge slightly; once the sheet is off screen it is closed.
        if (closing && value >= hiddenOffset() - CLOSE_EPSILON_PX) {
            closing = false
            spring?.cancel()
            visibility = GONE
            onClosed?.invoke()
        }
    }

    private companion object {
        const val SCRIM_ALPHA = 0.4f
        const val CLOSE_EPSILON_PX = 1f

        val OFFSET = object : FloatPropertyCompat<TaskSheetLayout>("sheetOffset") {
            override fun getValue(sheet: TaskSheetLayout): Float = sheet.offset
            override fun setValue(sheet: TaskSheetLayout, value: Float) = sheet.onSpringOffset(value)
        }
        const val FLING_DP_PER_SECOND = 900f
    }
}
