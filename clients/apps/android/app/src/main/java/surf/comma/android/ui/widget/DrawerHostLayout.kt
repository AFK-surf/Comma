package surf.comma.android.ui.widget

import android.content.Context
import android.util.AttributeSet
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import androidx.customview.widget.ViewDragHelper
import androidx.dynamicanimation.animation.FloatPropertyCompat
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import kotlin.math.abs
import kotlin.math.roundToInt

/** Custom-drawn cells reserve their code/table regions before the parent takes MOVE. */
interface HorizontalDragRegion {
    fun ownsHorizontalDragAt(x: Float, y: Float): Boolean
}

/**
 * A start-side drawer over full-page content. A sideways drag anywhere on the page pulls it (no
 * private-field reflection, so it survives R8), except where a child owns horizontal drags:
 * an [EditText], anything that can scroll sideways, or a [HorizontalDragRegion]. On release the
 * drawer settles on `springSpatial` with the finger's speed (DESIGN.md §6.1).
 */
class DrawerHostLayout @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null, defStyleAttr: Int = 0,
) : FrameLayout(context, attrs, defStyleAttr) {
    private var drawer: View? = null
    private var scrim: View? = null
    private var pages: List<View> = emptyList()
    private var visibilityChanged: (Boolean) -> Unit = {}
    var canStartDrag: () -> Boolean = { true }
    /** Page areas, in this layout's coordinates, whose drags never move a closed drawer. */
    var excludesDragAt: (x: Float, y: Float) -> Boolean = { _, _ -> false }
    var drawerProgress = 0f
        private set
    private var targetOpen = false
    private var dragging = false
    private var candidate = false
    private var allowCapture = false
    private var downX = 0f
    private var downY = 0f
    private var pointerId = MotionEvent.INVALID_POINTER_ID
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private val direction: Int get() = if (layoutDirection == LAYOUT_DIRECTION_RTL) -1 else 1
    val isOpen: Boolean get() = targetOpen || dragging && drawerProgress > 0f
    /** Settles [drawerProgress]; a progress unit is one drawer width. */
    private val spring = DesignSpring(this, PROGRESS, DesignMotion.springSpatial, minimumVisibleChange = 1f / 1000f)

    private val dragger: ViewDragHelper by lazy {
        ViewDragHelper.create(this, 1f, object : ViewDragHelper.Callback() {
            override fun tryCaptureView(child: View, activePointerId: Int) = child === drawer && allowCapture
            override fun getViewHorizontalDragRange(child: View) = if (child === drawer) child.width else 0
            override fun clampViewPositionHorizontal(child: View, left: Int, dx: Int) =
                left.coerceIn(minOf(closedLeft(child), openLeft(child)), maxOf(closedLeft(child), openLeft(child)))
            override fun clampViewPositionVertical(child: View, top: Int, dy: Int) = child.top
            override fun onViewCaptured(capturedChild: View, activePointerId: Int) {
                spring.cancel()
                dragging = true
                capturedChild.visibility = VISIBLE
                visibilityChanged(true)
            }
            override fun onViewPositionChanged(changedView: View, left: Int, top: Int, dx: Int, dy: Int) {
                applyProgress(((left - closedLeft(changedView)) * direction).toFloat() / changedView.width.coerceAtLeast(1))
            }
            override fun onViewReleased(releasedChild: View, xvel: Float, yvel: Float) {
                val velocity = xvel * direction
                targetOpen = if (velocity != 0f) velocity > 0f else drawerProgress > 0.5f
                dragging = false
                // The finger's speed carries into the spring, in drawer widths per second.
                spring.animateTo(if (targetOpen) 1f else 0f, velocity / releasedChild.width.coerceAtLeast(1))
            }
            override fun onViewDragStateChanged(state: Int) {
                if (state == ViewDragHelper.STATE_IDLE) {
                    dragging = false
                    applyProgress(drawerProgress)
                }
            }
        }).apply { minVelocity = 400f * resources.displayMetrics.density }
    }

    fun bind(drawer: View, scrim: View, pages: List<View>, onVisibilityChanged: (Boolean) -> Unit) {
        this.drawer = drawer
        this.scrim = scrim
        this.pages = pages
        visibilityChanged = onVisibilityChanged
        drawer.visibility = INVISIBLE
        applyProgress(0f)
    }

    fun open() = settle(true)
    fun close() = settle(false)

    fun restoreOpen() {
        targetOpen = true
        spring.cancel()
        dragger.abort()
        applyProgress(1f)
        requestLayout()
    }

    private fun settle(open: Boolean) {
        val panel = drawer ?: return
        targetOpen = open
        allowCapture = false
        dragging = false
        dragger.abort()
        panel.visibility = VISIBLE
        if (open) visibilityChanged(true)
        if (panel.width == 0) {
            spring.cancel()
            applyProgress(if (open) 1f else 0f)
            requestLayout()
            return
        }
        // Retargeting keeps the current position and speed, even when reversing a settle.
        spring.animateTo(if (open) 1f else 0f)
    }

    /** Moves the drawer to [value] of its width; the spring may carry it slightly past the ends. */
    private fun moveTo(value: Float) {
        drawer?.let { panel ->
            val progress = value.coerceIn(0f, 1f)
            panel.offsetLeftAndRight(closedLeft(panel) + (panel.width * progress * direction).roundToInt() - panel.left)
        }
        applyProgress(value)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        drawer?.layoutParams?.width = minOf(
            (MeasureSpec.getSize(widthMeasureSpec) * 0.84f).roundToInt(),
            (320 * resources.displayMetrics.density).roundToInt(),
        )
        super.onMeasure(widthMeasureSpec, heightMeasureSpec)
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val progress = drawerProgress
        super.onLayout(changed, left, top, right, bottom)
        // Position is kept as a fraction of the drawer, so a resize mid-settle lands on the new anchor.
        moveTo(progress)
    }

    private fun openLeft(panel: View) = if (direction == 1) 0 else width - panel.width
    private fun closedLeft(panel: View) = if (direction == 1) -panel.width else width

    private fun applyProgress(value: Float) {
        val previous = drawerProgress
        drawerProgress = value.coerceIn(0f, 1f)
        val visible = drawerProgress > 0f || targetOpen || dragging
        drawer?.visibility = if (visible) VISIBLE else INVISIBLE
        scrim?.apply {
            visibility = if (visible) VISIBLE else GONE
            alpha = drawerProgress
        }
        pages.forEach { page ->
            page.translationX = (drawer?.width ?: 0) * drawerProgress * direction / 3f
            page.importantForAccessibility = if (visible) IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                else IMPORTANT_FOR_ACCESSIBILITY_AUTO
        }
        visibilityChanged(visible)
        if ((previous < 0.9f && drawerProgress >= 0.9f) || (previous > 0.1f && drawerProgress <= 0.1f)) {
            performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        }
    }

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            pointerId = event.getPointerId(0)
            downX = event.x
            downY = event.y
            allowCapture = false
            candidate = canStartDrag() && !ownsHorizontalDrag(downX, downY)
        }
        if (!candidate) return false
        dragger.shouldInterceptTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_MOVE && !dragging) {
            val index = event.findPointerIndex(pointerId)
            if (index < 0) return false
            val dx = event.getX(index) - downX
            val dy = event.getY(index) - downY
            if (abs(dy) > slop && abs(dy) >= abs(dx)) candidate = false
            if (abs(dx) > slop && abs(dx) > abs(dy) * 1.5f &&
                (drawerProgress > 0f || dx * direction > 0f)
            ) {
                allowCapture = true
                drawer?.let { dragger.captureChildView(it, pointerId) }
            }
        }
        return dragging
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!candidate && !dragging) return false
        if (event.actionMasked == MotionEvent.ACTION_MOVE && !dragging) onInterceptTouchEvent(event)
        dragger.processTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
            allowCapture = false
            candidate = false
        }
        return true
    }

    /**
     * Closed, anything on the page may own the drag. Open, only what is inside the drawer can
     * (its filter strip, say); a drag on the scrim beside it always moves the drawer.
     */
    private fun ownsHorizontalDrag(x: Float, y: Float): Boolean {
        if (drawerProgress == 0f && !targetOpen) return excludesDragAt(x, y) || horizontalChildAt(this, x, y)
        val panel = drawer ?: return false
        val panelX = x - panel.left - panel.translationX
        val panelY = y - panel.top - panel.translationY
        return panelX >= 0 && panelX < panel.width && panelY >= 0 && panelY < panel.height &&
            horizontalChildAt(panel, panelX, panelY)
    }

    private fun horizontalChildAt(view: View, x: Float, y: Float): Boolean {
        if (view is HorizontalDragRegion && view.ownsHorizontalDragAt(x, y)) return true
        if (view is EditText || view.canScrollHorizontally(-1) || view.canScrollHorizontally(1)) return true
        if (view is ViewGroup) for (i in view.childCount - 1 downTo 0) {
            val child = view.getChildAt(i)
            if (child.visibility != VISIBLE) continue
            val childX = x + view.scrollX - child.left - child.translationX
            val childY = y + view.scrollY - child.top - child.translationY
            if (childX >= 0 && childX < child.width && childY >= 0 && childY < child.height &&
                horizontalChildAt(child, childX, childY)
            ) return true
        }
        return false
    }

    private companion object {
        val PROGRESS = object : FloatPropertyCompat<DrawerHostLayout>("drawerProgress") {
            override fun getValue(host: DrawerHostLayout) = host.drawerProgress
            override fun setValue(host: DrawerHostLayout, value: Float) = host.moveTo(value)
        }
    }
}
