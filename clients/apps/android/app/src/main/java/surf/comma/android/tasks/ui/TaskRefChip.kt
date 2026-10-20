package surf.comma.android.tasks.ui

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import android.view.ViewTreeObserver
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring

/**
 * A task referenced from a chat message, laid out ahead of time. Everything a cell needs to
 * draw it is here, so the message layout precomputer can build it on its background thread
 * and the cell only draws: status glyph, title, status text, on one compact line.
 */
class PreparedTaskRef(
    /** Null when there is nothing to open, e.g. an unavailable reference. */
    val taskId: String?,
    val bucket: TaskStatusBucket,
    val title: TextBlock,
    /** Null while the status is not known, e.g. before the task's summary arrives. */
    val status: TextBlock?,
    val widthPx: Int,
    val heightPx: Int,
    val contentDescription: String,
    /** Changes whenever anything drawn changes; a cell can skip redraws on an equal key. */
    val cacheKey: String,
    /** Not a known task state: the glyph is drawn quiet and never turns. */
    val neutral: Boolean = false,
)

/** Chip geometry, shared by the layout pass and the renderer so they cannot disagree. */
private class ChipMetrics(theme: TaskTheme) {
    val padH = theme.dpInt(10f)
    val padV = theme.dpInt(8f)
    val icon = theme.dpInt(16f)
    val gap = theme.dpInt(8f)
    val radius = theme.dp(10f)
    val lineHeight = theme.lineHeightPx(TaskType.meta)
    val height = lineHeight + padV * 2
}

/** Background-thread safe: reads only the immutable [TaskTheme] and [TaskStrings]. */
class TaskRefChipLayout(private val theme: TaskTheme, private val strings: TaskStrings) {
    private val metrics = ChipMetrics(theme)

    fun prepare(task: TaskSummary, maxWidthPx: Int): PreparedTaskRef {
        val bucket = task.bucket
        val title = strings.title(task)
        val statusText = theme.statusLabel(bucket)
        val fixed = metrics.padH * 2 + metrics.icon + metrics.gap * 2
        val status = theme.line(statusText, TaskType.meta, theme.textQuaternary, maxWidthPx / 3)
        val titleBlock = theme.line(
            title,
            TaskType.metaMedium,
            theme.textPrimary,
            (maxWidthPx - fixed - status.contentWidthPx).coerceAtLeast(metrics.icon),
        )
        val width = fixed + titleBlock.contentWidthPx + status.contentWidthPx
        return PreparedTaskRef(
            taskId = task.id,
            bucket = bucket,
            title = titleBlock,
            status = status,
            widthPx = width,
            heightPx = metrics.height,
            contentDescription = "$title, $statusText",
            cacheKey = "${task.id}|$title|${bucket.wireName}|$maxWidthPx",
        )
    }

    /** A chip without a known state: [title] alone, with the quiet neutral glyph. */
    fun preparePlaceholder(taskId: String?, title: String, maxWidthPx: Int): PreparedTaskRef {
        val fixed = metrics.padH * 2 + metrics.icon + metrics.gap
        val titleBlock = theme.line(
            title,
            TaskType.metaMedium,
            theme.textTertiary,
            (maxWidthPx - fixed).coerceAtLeast(metrics.icon),
        )
        return PreparedTaskRef(
            taskId = taskId,
            bucket = TaskStatusBucket.IN_PROGRESS,
            title = titleBlock,
            status = null,
            widthPx = fixed + titleBlock.contentWidthPx,
            heightPx = metrics.height,
            contentDescription = title,
            cacheKey = "placeholder|$taskId|$title|$maxWidthPx",
            neutral = true,
        )
    }
}

/**
 * Draws a [PreparedTaskRef] at any origin on any canvas. A chat cell holds one renderer and
 * calls [draw] for each task block; while [needsFrames] is true for a visible block, the
 * cell keeps requesting animation frames so the glyph turns.
 */
class TaskRefChipRenderer(context: Context, private val theme: TaskTheme) {
    private val metrics = ChipMetrics(theme)
    private val glyphs = TaskStatusGlyphs(context)
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = theme.bgSecondary }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = theme.hairlinePx
        color = theme.borderPrimary
    }
    private val bounds = RectF()

    fun needsFrames(chip: PreparedTaskRef): Boolean =
        !chip.neutral && chip.bucket == TaskStatusBucket.IN_PROGRESS && ValueAnimator.areAnimatorsEnabled()

    fun draw(canvas: Canvas, chip: PreparedTaskRef, left: Float, top: Float, animate: Boolean) {
        val inset = theme.hairlinePx / 2f
        bounds.set(left + inset, top + inset, left + chip.widthPx - inset, top + chip.heightPx - inset)
        canvas.drawRoundRect(bounds, metrics.radius, metrics.radius, fill)
        canvas.drawRoundRect(bounds, metrics.radius, metrics.radius, stroke)
        var x = left + metrics.padH
        glyphs.draw(
            canvas,
            chip.bucket.takeUnless { chip.neutral },
            if (chip.neutral) theme.fgQuaternary else theme.statusTint(chip.bucket),
            x,
            top + (chip.heightPx - metrics.icon) / 2f,
            metrics.icon,
            spin = animate,
        )
        x += metrics.icon + metrics.gap
        val textTop = top + metrics.padV
        chip.title.draw(canvas, x, textTop)
        x += chip.title.contentWidthPx + metrics.gap
        chip.status?.draw(canvas, x, textTop)
    }
}

/**
 * Standalone host for one task chip. Chat cells embed the renderer directly; this view is
 * for surfaces that are not a message cell, and for the demo.
 */
class TaskRefChipView(context: Context) : View(context) {
    private val theme = TaskTheme(context)
    private val chipLayout = TaskRefChipLayout(theme, TaskStrings(context))
    private val renderer = TaskRefChipRenderer(context, theme)
    private val visibleRect = Rect()
    private var content: Content? = null
    private var chip: PreparedTaskRef? = null
    private var aggregatedVisible = false
    private val pressX = DesignSpring(this, DynamicAnimation.SCALE_X, DesignMotion.springScale)
    private val pressY = DesignSpring(this, DynamicAnimation.SCALE_Y, DesignMotion.springScale)
    private val scrollListener = ViewTreeObserver.OnScrollChangedListener { resumeFramesIfShown() }

    var onOpenTask: ((String) -> Unit)? = null

    init {
        isClickable = true
        isFocusable = true
    }

    /** The task as the server last described it. */
    fun bind(task: TaskSummary) = show(Content.Task(task))

    /**
     * A reference whose task is not confirmed: [title] only, no state. [taskId] null makes the
     * chip inert, for references that cannot be opened.
     */
    fun bindPlaceholder(taskId: String?, title: String) = show(Content.Placeholder(taskId, title))

    /** What tapping would open; null when the chip is inert. */
    val taskId: String? get() = when (val current = content) {
        is Content.Task -> current.task.id
        is Content.Placeholder -> current.taskId
        null -> null
    }

    private fun show(next: Content) {
        if (content == next) return
        content = next
        chip = null
        isClickable = taskId != null
        requestLayout()
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val available = MeasureSpec.getSize(widthMeasureSpec).takeIf {
            MeasureSpec.getMode(widthMeasureSpec) != MeasureSpec.UNSPECIFIED
        } ?: resources.displayMetrics.widthPixels
        val current = content?.let { bound ->
            chip?.takeIf { it.cacheKey.endsWith("|$available") } ?: when (bound) {
                is Content.Task -> chipLayout.prepare(bound.task, available)
                is Content.Placeholder -> chipLayout.preparePlaceholder(bound.taskId, bound.title, available)
            }.also { chip = it }
        }
        contentDescription = current?.contentDescription
        setMeasuredDimension(
            resolveSize(current?.widthPx ?: 0, widthMeasureSpec),
            resolveSize(current?.heightPx ?: 0, heightMeasureSpec),
        )
    }

    override fun onDraw(canvas: Canvas) {
        val current = chip ?: return
        val animate = renderer.needsFrames(current) && isShownOnScreen()
        renderer.draw(canvas, current, 0f, 0f, animate)
        if (animate) postInvalidateOnAnimation()
    }

    // Only adds press feedback; clicks still go through super and performClick.
    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> animatePress(DesignMotion.pressScale())
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> animatePress(1f)
        }
        return super.onTouchEvent(event)
    }

    override fun performClick(): Boolean {
        super.performClick()
        taskId?.let { onOpenTask?.invoke(it) }
        return true
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        viewTreeObserver.addOnScrollChangedListener(scrollListener)
    }

    override fun onDetachedFromWindow() {
        pressX.cancel()
        pressY.cancel()
        scaleX = 1f
        scaleY = 1f
        viewTreeObserver.removeOnScrollChangedListener(scrollListener)
        super.onDetachedFromWindow()
    }

    override fun onVisibilityAggregated(isVisible: Boolean) {
        super.onVisibilityAggregated(isVisible)
        aggregatedVisible = isVisible
        if (isVisible) invalidate()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        if (visibility == VISIBLE) invalidate()
    }

    /** A chip scrolled back into view needs one draw to restart its frame loop. */
    private fun resumeFramesIfShown() {
        val current = chip ?: return
        if (renderer.needsFrames(current) && isShownOnScreen()) invalidate()
    }

    private fun isShownOnScreen(): Boolean =
        isAttachedToWindow && aggregatedVisible && windowVisibility == VISIBLE &&
            getGlobalVisibleRect(visibleRect)

    private fun animatePress(scale: Float) {
        if (!isClickable) return
        pressX.animateTo(scale)
        pressY.animateTo(scale)
    }

    private sealed interface Content {
        data class Task(val task: TaskSummary) : Content
        data class Placeholder(val taskId: String?, val title: String) : Content
    }
}
