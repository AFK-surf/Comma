package surf.comma.android.tasks.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import android.view.MotionEvent
import android.view.ViewGroup
import android.widget.TextView
import androidx.dynamicanimation.animation.DynamicAnimation
import kotlin.math.ceil
import kotlin.math.min
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.render.ChatCardHeights
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography

/** Card geometry, shared by the layout pass and the view so they cannot disagree. */
class TaskRefCardMetrics(theme: TaskTheme) {
    val padH = theme.dpInt(14f)
    val padV = theme.dpInt(12f)
    val icon = theme.dpInt(16f)
    val gap = theme.dpInt(10f)
    val lineGap = theme.dpInt(2f)
    val radius = theme.dp(12f)
    val titleLine = theme.lineHeightPx(TaskType.cardTitle)
    val metaLine = theme.lineHeightPx(TaskType.meta)

    fun heightPx(titleLines: Int): Int = padV * 2 + titleLines * titleLine + lineGap + metaLine

    /** Title lines that fit a card of [heightPx]: one or two. */
    fun titleLinesFor(heightPx: Int): Int =
        ((heightPx - padV * 2 - lineGap - metaLine) / titleLine.coerceAtLeast(1)).coerceIn(1, MAX_TITLE_LINES)

    companion object {
        const val MAX_TITLE_LINES = 2
    }
}

/**
 * Heights for task cards in a chat, measured ahead of time from the title the message carries,
 * so a card never changes height when the task's own summary arrives. Background-thread safe:
 * it reads only the immutable [TaskTheme].
 */
class TaskRefCardLayout(
    private val theme: TaskTheme,
    /** Shown while a reference has no title of its own. */
    private val placeholder: String,
    /** The face of the message text around the card, for punctuation that follows it. */
    private val bodyTypeface: Typeface,
) : ChatCardHeights {
    val metrics = TaskRefCardMetrics(theme)

    override fun bodyHeightPx(message: ChatMessage, rowWidthPx: Int, sideMarginPx: Int): Int? {
        if (message.cardKind != LiveRowKinds.TASK_REF) return null
        val ref = LiveRowKinds.decodeTask(message.cardPayload)
        val width = cardWidth(rowWidthPx, sideMarginPx, ref.suffix)
        return metrics.heightPx(titleLines(ref.title?.takeIf { it.isNotBlank() } ?: placeholder, width))
    }

    /** The card's width: the reply's text column, less any punctuation that follows it. */
    fun cardWidth(rowWidthPx: Int, sideMarginPx: Int, suffix: String): Int =
        (rowWidthPx - sideMarginPx * 2 - suffixWidth(suffix)).coerceAtLeast(metrics.icon * 4)

    fun titleLines(title: String, cardWidthPx: Int): Int {
        val width = (cardWidthPx - metrics.padH * 2 - metrics.icon - metrics.gap).coerceAtLeast(1)
        val paint = theme.paint(TaskType.cardTitle, 0)
        if (paint.measureText(title) <= width) return 1
        val layout = StaticLayout.Builder.obtain(title, 0, title.length, paint, width)
            .setMaxLines(TaskRefCardMetrics.MAX_TITLE_LINES)
            .setIncludePad(false)
            .build()
        return min(layout.lineCount, TaskRefCardMetrics.MAX_TITLE_LINES).coerceAtLeast(1)
    }

    private fun suffixWidth(suffix: String): Int {
        if (suffix.isEmpty()) return 0
        val paint = TextPaint(TextPaint.ANTI_ALIAS_FLAG).apply {
            typeface = bodyTypeface
            textSize = theme.sp(BODY_TEXT_SP * DesignTypography.chatScale())
        }
        return ceil(Layout.getDesiredWidth(suffix, paint)).toInt()
    }

    companion object {
        /** The message body size before the chat scale; see MessageLayoutPrecomputer. */
        const val BODY_TEXT_SP = 16f
    }
}

/**
 * A task in a chat reply: status glyph (turning while the task runs), the title on up to two
 * lines, and one quiet line under it with the status and the latest progress, or when it was
 * last updated. A light rounded card as wide as the reply's text.
 *
 * The parent sizes it; the title gets as many lines as the height was laid out for.
 */
// Built in code only, never inflated from XML. The touch override only adds press feedback;
// clicks still go through super and performClick.
@SuppressLint("ViewConstructor", "ClickableViewAccessibility")
class TaskRefCardView(context: Context, private val theme: TaskTheme = TaskTheme(context)) : ViewGroup(context) {
    private val metrics = TaskRefCardMetrics(theme)
    private val strings = TaskStrings(context)
    private val icon = TaskStatusIconView(context)
    private val title = TextView(context).apply {
        theme.applyTo(this, TaskType.cardTitle, theme.textPrimary)
        ellipsize = TextUtils.TruncateAt.END
        includeFontPadding = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private val meta = TextView(context).apply {
        theme.applyTo(this, TaskType.meta, theme.textTertiary)
        maxLines = 1
        isSingleLine = true
        ellipsize = TextUtils.TruncateAt.END
        includeFontPadding = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = theme.bgSecondary }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = theme.hairlinePx
        color = theme.borderPrimary
    }
    private val bounds = RectF()
    private val pressX = DesignSpring(this, DynamicAnimation.SCALE_X, DesignMotion.springScale)
    private val pressY = DesignSpring(this, DynamicAnimation.SCALE_Y, DesignMotion.springScale)

    /** What tapping opens; null when the card is inert. */
    var taskId: String? = null
        private set

    /** The task as the card shows it, when it is known; handed to whatever the tap opens. */
    var task: TaskSummary? = null
        private set

    var onOpenTask: ((String) -> Unit)? = null

    val titleText: CharSequence get() = title.text
    val metaText: CharSequence get() = meta.text
    val titleMaxLines: Int get() = title.maxLines
    val isSpinning: Boolean get() = icon.isSpinning
    /** The status the glyph shows; null for the neutral glyph of a task whose status is not known. */
    val glyphBucket: TaskStatusBucket? get() = icon.bucket

    init {
        setWillNotDraw(false)
        isFocusable = true
        addView(icon)
        addView(title)
        addView(meta)
    }

    /** The task as the server last described it. */
    fun bind(task: TaskSummary) {
        val bucket = task.bucket
        val status = theme.statusLabel(bucket)
        val detail = task.progress?.takeIf { bucket == TaskStatusBucket.IN_PROGRESS && it.isNotBlank() }
            ?: strings.updatedAt(task.updatedAt)
        show(task.id, task, bucket, theme.statusTint(bucket), strings.title(task), "$status · $detail", spin = true)
    }

    /**
     * A reference whose task is not confirmed: its own [title] and no state, since what the
     * message said may be stale; the glyph stays quiet. [taskId] null makes the card inert.
     */
    fun bindPlaceholder(taskId: String?, title: String) {
        show(taskId, null, null, theme.fgQuaternary, title, "", spin = false)
    }

    private fun show(id: String?, known: TaskSummary?, bucket: TaskStatusBucket?, tint: Int, titleText: String, metaText: String, spin: Boolean) {
        taskId = id
        task = known
        isClickable = id != null
        icon.setStatus(bucket, tint, spin)
        if (title.text.toString() != titleText) title.text = titleText
        if (meta.text.toString() != metaText) meta.text = metaText
        contentDescription = if (metaText.isEmpty()) titleText else "$titleText, $metaText"
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = MeasureSpec.getSize(heightMeasureSpec)
        setMeasuredDimension(width, height)
        val lines = metrics.titleLinesFor(height)
        if (title.maxLines != lines) title.maxLines = lines
        val textWidth = (width - metrics.padH * 2 - metrics.icon - metrics.gap).coerceAtLeast(0)
        val exactIcon = MeasureSpec.makeMeasureSpec(metrics.icon, MeasureSpec.EXACTLY)
        icon.measure(exactIcon, exactIcon)
        title.measure(MeasureSpec.makeMeasureSpec(textWidth, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(lines * metrics.titleLine, MeasureSpec.AT_MOST))
        meta.measure(MeasureSpec.makeMeasureSpec(textWidth, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(metrics.metaLine, MeasureSpec.EXACTLY))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val rtl = layoutDirection == LAYOUT_DIRECTION_RTL
        fun place(view: android.view.View, left: Int, top: Int) {
            val x = if (rtl) width - left - view.measuredWidth else left
            view.layout(x, top, x + view.measuredWidth, top + view.measuredHeight)
        }
        // The glyph sits on the title's first line.
        place(icon, metrics.padH, metrics.padV + (metrics.titleLine - metrics.icon) / 2)
        val textLeft = metrics.padH + metrics.icon + metrics.gap
        place(title, textLeft, metrics.padV)
        place(meta, textLeft, metrics.padV + title.measuredHeight + metrics.lineGap)
    }

    /** Where the status line's text sits, so punctuation after the card can line up with it. */
    val metaBaseline: Int get() = meta.top + meta.baseline

    override fun onDraw(canvas: Canvas) {
        val inset = theme.hairlinePx / 2f
        bounds.set(inset, inset, width - inset, height - inset)
        canvas.drawRoundRect(bounds, metrics.radius, metrics.radius, fill)
        canvas.drawRoundRect(bounds, metrics.radius, metrics.radius, stroke)
    }

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

    override fun onDetachedFromWindow() {
        pressX.cancel()
        pressY.cancel()
        scaleX = 1f
        scaleY = 1f
        super.onDetachedFromWindow()
    }

    private fun animatePress(scale: Float) {
        if (!isClickable) return
        pressX.animateTo(scale)
        pressY.animateTo(scale)
    }
}
