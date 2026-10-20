package surf.comma.android.tasks.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.animation.AnimationUtils
import androidx.core.view.ViewCompat
import androidx.dynamicanimation.animation.FloatPropertyCompat
import kotlin.math.abs
import kotlin.math.hypot
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring

/**
 * A task card of the full list: status glyph, title, progress or failure, label pills,
 * updated time. Everything but the glyph is drawn from a [PreparedTaskRow.Card]; the glyph is
 * a child view so its rotation stays a render-node property.
 */
// Built in code only, never inflated from XML. The touch override only cancels a tap that turned
// into a drag; clicks still go through super and performClick.
@SuppressLint("ViewConstructor", "ClickableViewAccessibility")
class TaskCardView(
    context: Context,
    private val theme: TaskTheme,
    private val metrics: TaskCardMetrics,
) : ViewGroup(context) {
    private val icon = TaskStatusIconView(context)
    private val archiveLabel = context.getString(R.string.task_action_archive)
    private val cardPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = theme.hairlinePx
        color = theme.borderPrimary
    }
    private val pillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = theme.hairlinePx
        color = theme.borderPrimary
    }
    private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rect = RectF()

    var card: PreparedTaskRow.Card? = null
        private set

    var onOpenTask: ((String) -> Unit)? = null

    /** Archive without a swipe, offered to accessibility services on cards that may go. */
    var onArchive: ((String) -> Unit)? = null
    private var archiveAction = View.NO_ID

    // Swipe-to-archive release motion. The finger drives translationX directly while dragging;
    // after release this spring takes over, starting at the finger's speed.
    private val swipe = DesignSpring(this, SWIPE_X, DesignMotion.springSpatial)
    private var swipeTarget: Float? = null
    private var afterSwipeOut: (() -> Unit)? = null
    private var lastDragX = 0f
    private var lastDragMs = 0L
    private var dragVelocity = 0f
    private val touchSlop = android.view.ViewConfiguration.get(context).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var dragged = false

    init {
        setWillNotDraw(false)
        isClickable = true
        isFocusable = true
        addView(icon)
        setOnClickListener { card?.let { onOpenTask?.invoke(it.task.id) } }
    }

    /**
     * A finger that travels past the touch slop is a drag, not a tap: a sideways drag on a card
     * that cannot be archived must not open the task.
     */
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
                dragged = false
            }
            MotionEvent.ACTION_MOVE -> if (!dragged && hypot(event.x - downX, event.y - downY) > touchSlop) {
                dragged = true
                val cancel = MotionEvent.obtain(event).apply { action = MotionEvent.ACTION_CANCEL }
                super.onTouchEvent(cancel)
                cancel.recycle()
            }
        }
        return if (dragged) true else super.onTouchEvent(event)
    }

    /** Follows the finger during a swipe and remembers how fast it was moving. */
    fun dragTo(x: Float) {
        swipe.cancel()
        swipeTarget = null
        val now = AnimationUtils.currentAnimationTimeMillis()
        val elapsed = now - lastDragMs
        // The first sample of a drag, or one after a long pause, carries no speed.
        dragVelocity = if (lastDragMs == 0L || elapsed > MAX_SAMPLE_GAP_MS) 0f
        else if (elapsed > 0) (x - lastDragX) * 1000f / elapsed else dragVelocity
        lastDragX = x
        lastDragMs = now
        translationX = x
    }

    /** After release: spring to [target] (0 to come back, off screen to leave). */
    fun releaseTo(target: Float) {
        if (swipeTarget == target) return
        swipeTarget = target
        swipe.animateTo(target, initialVelocity = dragVelocity)
    }

    /** Runs [action] once the row has left the screen, or right away if it already has. */
    fun whenSwipedOut(action: () -> Unit) {
        val target = swipeTarget
        if (target != null && target != 0f && !swipe.isRunning) action() else afterSwipeOut = action
    }

    /** A rebound row starts in place with no motion pending. */
    fun resetSwipe() {
        swipe.cancel()
        swipeTarget = null
        afterSwipeOut = null
        dragVelocity = 0f
        lastDragMs = 0L
        translationX = 0f
    }

    private fun onSwipeStep(value: Float) {
        translationX = value
        // The list draws the archive backdrop behind this row; it must redraw with the row.
        (parent as? View)?.invalidate()
        val target = swipeTarget ?: return
        // The spring may pass the edge slightly; once the row is fully off screen it has left.
        if (target != 0f && abs(value) >= abs(target) - 1f) {
            afterSwipeOut?.let { action ->
                afterSwipeOut = null
                swipe.cancel()
                action()
            }
        }
    }

    fun bind(row: PreparedTaskRow.Card) {
        val previous = card
        card = row
        icon.setStatus(row.bucket, theme.statusTint(row.bucket))
        contentDescription = row.contentDescription
        if (archiveAction != View.NO_ID) ViewCompat.removeAccessibilityAction(this, archiveAction)
        archiveAction = if (!row.archivable) View.NO_ID else ViewCompat.addAccessibilityAction(this, archiveLabel) { _, _ ->
            onArchive?.invoke(row.task.id)
            true
        }
        if (previous?.heightPx != row.heightPx) requestLayout()
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val size = MeasureSpec.makeMeasureSpec(metrics.icon, MeasureSpec.EXACTLY)
        icon.measure(size, size)
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), card?.heightPx ?: 0)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val left = metrics.gutter + metrics.pad
        val top = metrics.pad + (metrics.titleLineHeight - metrics.icon) / 2
        icon.layout(left, top, left + metrics.icon, top + metrics.icon)
    }

    override fun drawableStateChanged() {
        super.drawableStateChanged()
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val row = card ?: return
        val m = metrics
        val inset = theme.hairlinePx / 2f
        rect.set(
            m.gutter + inset,
            inset,
            width - m.gutter - inset,
            row.cardHeightPx - inset,
        )
        cardPaint.color = if (isPressed) theme.bgTertiary else theme.bgSecondary
        canvas.drawRoundRect(rect, m.radius, m.radius, cardPaint)
        canvas.drawRoundRect(rect, m.radius, m.radius, strokePaint)

        val textLeft = (m.gutter + m.pad + m.icon + m.iconGap).toFloat()
        row.title.draw(canvas, textLeft, m.pad.toFloat())
        row.status?.draw(canvas, textLeft, row.statusTop.toFloat())
        for (pill in row.pills) drawPill(canvas, pill)
        row.footer?.draw(canvas, textLeft, row.footerTop.toFloat())
    }

    private fun drawPill(canvas: Canvas, pill: PreparedPill) {
        val m = metrics
        val left = (m.gutter + pill.left).toFloat()
        val top = pill.top.toFloat()
        val inset = theme.hairlinePx / 2f
        rect.set(left + inset, top + inset, left + pill.width - inset, top + pill.height - inset)
        val radius = pill.height / 2f
        canvas.drawRoundRect(rect, radius, radius, pillPaint)
        val x = left + m.pillPadH
        dotPaint.color = pill.dotColor
        canvas.drawCircle(x + m.dot / 2f, top + pill.height / 2f, m.dot / 2f, dotPaint)
        pill.text.draw(canvas, x + m.dot + m.dotGap, top + m.pillPadV)
    }

    private companion object {
        const val MAX_SAMPLE_GAP_MS = 100L

        val SWIPE_X = object : FloatPropertyCompat<TaskCardView>("swipeX") {
            override fun getValue(view: TaskCardView): Float = view.translationX
            override fun setValue(view: TaskCardView, value: Float) = view.onSwipeStep(value)
        }
    }
}

/** Section header: status glyph, bucket name, count. */
@SuppressLint("ViewConstructor") // Built in code only, never inflated from XML.
class TaskSectionHeaderView(
    context: Context,
    private val metrics: TaskCardMetrics,
    private val theme: TaskTheme,
) : ViewGroup(context) {
    private val icon = TaskStatusIconView(context)
    private var header: PreparedTaskRow.Header? = null

    init {
        setWillNotDraw(false)
        addView(icon)
        isFocusable = false
        isAccessibilityHeading = true
    }

    fun bind(row: PreparedTaskRow.Header) {
        header = row
        // The section glyph never turns; one moving glyph per running card is enough.
        icon.setStatus(row.bucket, theme.statusTint(row.bucket), spin = false)
        contentDescription = "${row.label.layout.text}, ${row.count.layout.text}"
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val size = MeasureSpec.makeMeasureSpec(metrics.icon, MeasureSpec.EXACTLY)
        icon.measure(size, size)
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), header?.heightPx ?: metrics.headerHeight)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val left = metrics.gutter + metrics.pad
        val top = (measuredHeight - metrics.icon) / 2
        icon.layout(left, top, left + metrics.icon, top + metrics.icon)
    }

    override fun onDraw(canvas: Canvas) {
        val row = header ?: return
        val left = (metrics.gutter + metrics.pad + metrics.icon + metrics.iconGap).toFloat()
        val top = (height - row.label.heightPx) / 2f
        row.label.draw(canvas, left, top)
        row.count.draw(canvas, left + row.label.contentWidthPx + metrics.iconGap, (height - row.count.heightPx) / 2f)
    }
}
