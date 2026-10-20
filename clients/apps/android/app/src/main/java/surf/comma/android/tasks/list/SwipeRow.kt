package surf.comma.android.tasks.list

import android.content.Context
import android.content.res.ColorStateList
import android.view.Gravity
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import androidx.annotation.ColorInt
import androidx.annotation.DrawableRes
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.rounded
import surf.comma.android.ui.kit.selectionTick
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography.Level
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** One swipe action: its title and glyph on a capsule of [fill], drawn in [ink]. */
data class SwipeAction(
    val title: CharSequence,
    @DrawableRes val icon: Int,
    @ColorInt val fill: Int,
    @ColorInt val ink: Int,
    val enabled: Boolean = true,
    val perform: () -> Unit,
)

/**
 * A list row with swipe actions, as iOS lists have them: dragging sideways slides the row and reveals the
 * actions of that edge on capsules behind it; letting go past half their width leaves them open, a tap on one
 * acts, and a tap anywhere else or another row's swipe closes them. With [fullSwipe] on an edge, dragging most of
 * the way across performs its first action outright. Vertical drags stay with the list.
 */
class SwipeRow(context: Context, val row: View) : FrameLayout(context) {
    private val leadingTray = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
    private val trailingTray = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
    private val slide = DesignSpring(row, DynamicAnimation.TRANSLATION_X, DesignMotion.springSpatial)
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private var leading: List<SwipeAction> = emptyList()
    private var trailing: List<SwipeAction> = emptyList()
    private var fullLeading = false
    private var fullTrailing = false
    private var downX = 0f
    private var downY = 0f
    private var startX = 0f
    private var dragging = false
    private var velocity: VelocityTracker? = null
    private var armed = false

    init {
        addView(leadingTray, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT, Gravity.START))
        addView(trailingTray, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT, Gravity.END))
        addView(row, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        // The actions show only while the row is moved off them.
        row.viewTreeObserver.addOnPreDrawListener {
            leadingTray.visibility = if (row.translationX > 0.5f) VISIBLE else INVISIBLE
            trailingTray.visibility = if (row.translationX < -0.5f) VISIBLE else INVISIBLE
            true
        }
        leadingTray.visibility = INVISIBLE
        trailingTray.visibility = INVISIBLE
    }

    fun setActions(leading: List<SwipeAction>, trailing: List<SwipeAction>, fullLeading: Boolean = false, fullTrailing: Boolean = false) {
        this.leading = leading
        this.trailing = trailing
        this.fullLeading = fullLeading
        this.fullTrailing = fullTrailing
        fill(leadingTray, leading)
        fill(trailingTray, trailing)
        close(animate = false)
    }

    private fun fill(tray: LinearLayout, actions: List<SwipeAction>) {
        tray.removeAllViews()
        actions.forEach { action ->
            tray.addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                background = rounded(action.fill, context.dp(22).toFloat())
                alpha = if (action.enabled) 1f else 0.4f
                setPadding(context.dp(12), 0, context.dp(12), 0)
                addView(ImageView(context).apply {
                    setImageResource(action.icon)
                    imageTintList = ColorStateList.valueOf(action.ink)
                }, LinearLayout.LayoutParams(context.dp(16), context.dp(16)))
                addView(context.label(Level.MINI, android.R.color.white).apply {
                    setTextColor(action.ink)
                    text = action.title
                }, LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = context.dp(2) })
                contentDescription = action.title
                setOnClickListener {
                    if (!action.enabled) return@setOnClickListener
                    close()
                    action.perform()
                }
            }, LinearLayout.LayoutParams(context.dp(ACTION_DP), LayoutParams.MATCH_PARENT).apply {
                setMargins(context.dp(3), context.dp(3), context.dp(3), context.dp(3))
            })
        }
        tray.setPadding(context.dp(7), 0, context.dp(7), 0)
    }

    private fun trayWidth(actions: List<SwipeAction>) = if (actions.isEmpty()) 0 else actions.size * context.dp(ACTION_DP + 6) + context.dp(14)

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x; downY = event.y; startX = row.translationX; dragging = false
                velocity?.recycle(); velocity = VelocityTracker.obtain()
                if (open !== this) open?.close()
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.x - downX
                val dy = event.y - downY
                if (!dragging && abs(dx) > slop && abs(dx) > abs(dy) * 1.5f && (leading.isNotEmpty() || trailing.isNotEmpty() || startX != 0f)) {
                    dragging = true
                    downX = event.x
                    slide.cancel()
                    parent?.requestDisallowInterceptTouchEvent(true)
                    row.isPressed = false
                    (row as? TaskRowView)?.setPressedLook(false)
                    row.cancelLongPress()
                    return true
                }
            }
        }
        velocity?.addMovement(event)
        return false
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        velocity?.addMovement(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_MOVE -> if (dragging) {
                val maxRight = if (leading.isEmpty()) 0f else if (fullLeading) width.toFloat() else trayWidth(leading) * 1.3f
                val maxLeft = if (trailing.isEmpty()) 0f else if (fullTrailing) width.toFloat() else trayWidth(trailing) * 1.3f
                val x = (startX + event.x - downX).coerceIn(-maxLeft, maxRight)
                row.translationX = x
                val past = (x > 0 && fullLeading && x > width * FULL) || (x < 0 && fullTrailing && -x > width * FULL)
                if (past != armed) { armed = past; selectionTick() }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> if (dragging) {
                dragging = false
                velocity?.computeCurrentVelocity(1000)
                settle(velocity?.xVelocity ?: 0f)
            }
        }
        return dragging || super.onTouchEvent(event)
    }

    private fun settle(speed: Float) {
        val x = row.translationX
        armed = false
        when {
            x > 0 && fullLeading && x > width * FULL -> perform(leading.first(), width.toFloat())
            x < 0 && fullTrailing && -x > width * FULL -> perform(trailing.first(), -width.toFloat())
            x > 0 && (x > trayWidth(leading) / 2f || speed > FLING) && speed > -FLING -> openTo(trayWidth(leading).toFloat(), speed)
            x < 0 && (-x > trayWidth(trailing) / 2f || speed < -FLING) && speed < FLING -> openTo(-trayWidth(trailing).toFloat(), speed)
            else -> close(speed = speed)
        }
    }

    private fun perform(action: SwipeAction, to: Float) {
        if (!action.enabled) return close()
        slide.animateTo(to)
        postDelayed({ action.perform(); close(animate = false) }, PERFORM_DELAY_MS)
    }

    private fun openTo(x: Float, speed: Float) {
        open = this
        slide.animateTo(x, speed)
    }

    fun close(animate: Boolean = true, speed: Float = 0f) {
        if (open === this) open = null
        if (animate) slide.animateTo(0f, speed) else { slide.cancel(); row.translationX = 0f }
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        close(animate = false)
    }

    private companion object {
        const val ACTION_DP = 74
        /** How far across a full swipe has to go to act. */
        const val FULL = 0.6f
        const val FLING = 800f
        const val PERFORM_DELAY_MS = 180L
        /** The row whose actions are open; only one is open at a time. */
        var open: SwipeRow? = null
    }
}
