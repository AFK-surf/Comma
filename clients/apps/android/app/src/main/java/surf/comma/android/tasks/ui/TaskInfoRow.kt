package surf.comma.android.tasks.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextUtils
import android.text.style.ReplacementSpan
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatCardRenderer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.tasks.TaskLabel
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary

/**
 * The line at the top of a task's page: status, labels, updated time. It is the list's first row,
 * so it scrolls away with the messages. Everything it shows travels in the row's payload, so a
 * change to the task reaches it through the same diff as the messages.
 */
object TaskInfoRow {
    const val KIND = "task.info"

    /** Fixed: the row is above every message and never in a page of history. */
    const val ROW_ID = Long.MIN_VALUE + 1

    private const val FIELD = '\u001F'
    private const val PAIR = '\u001E'

    data class Info(val bucket: TaskStatusBucket, val failed: Boolean, val labels: List<TaskLabel>, val updated: String)

    fun message(task: TaskSummary, catalog: List<TaskLabel>, strings: TaskStrings): ChatMessage {
        val byId = catalog.associateBy { it.id }
        val info = Info(task.bucket, task.failed, task.labelIds.mapNotNull { byId[it] }, strings.updated(task.updatedAt).orEmpty())
        return ChatMessage(
            id = ROW_ID, conversationId = task.id, role = ChatRole.AGENT, text = "", createdAt = 0L,
            cardKind = KIND, cardPayload = encode(info),
        )
    }

    fun encode(info: Info): String = buildString {
        append(info.bucket.wireName).append(if (info.failed) "!" else "").append(FIELD).append(info.updated.clean())
        info.labels.forEach { label ->
            append(FIELD).append(label.name.clean()).append(PAIR).append(label.color.clean())
        }
    }

    fun decode(payload: String?): Info {
        val fields = payload.orEmpty().split(FIELD)
        val labels = fields.drop(2).mapIndexedNotNull { index, field ->
            val pair = field.split(PAIR)
            pair.getOrNull(0)?.takeIf { it.isNotEmpty() }?.let { TaskLabel(id = "$index", name = it, color = pair.getOrNull(1).orEmpty()) }
        }
        val status = fields.getOrNull(0).orEmpty()
        return Info(TaskStatusBucket.of(status.removeSuffix("!")), status.endsWith("!"), labels, fields.getOrNull(1).orEmpty())
    }

    /** What the row says, in order: status, each label, then the updated time when it is known. */
    fun parts(info: Info, theme: TaskTheme): List<String> =
        listOf(theme.statusText(info.bucket, info.failed)) + info.labels.map { it.name } + listOfNotNull(info.updated.ifEmpty { null })

    private fun String.clean() = replace(FIELD, ' ').replace(PAIR, ' ')
}

internal class TaskInfoCardRenderer(override val viewType: Int) : ChatCardRenderer {
    override val kind = TaskInfoRow.KIND

    override fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float) = BODY_HEIGHT_DP

    override fun create(context: Context): View = TaskInfoRowView(context)

    override fun bind(view: View, item: PreparedChatMessage) = (view as TaskInfoRowView).bind(item)

    private companion object {
        /** One small line (20dp) and the space below it before the first message. */
        const val BODY_HEIGHT_DP = 34f
    }
}

/**
 * Status glyph, then "Done · ● Work · ● Research" on one line that is cut short with an ellipsis,
 * then " · Updated 1 Oct", which always shows.
 */
@SuppressLint("ViewConstructor")
class TaskInfoRowView(context: Context) : ViewGroup(context) {
    private val theme = TaskTheme(context)
    private val icon = TaskStatusIconView(context)
    private val summary = line()
    private val updated = line()
    private val iconSize = theme.dpInt(16f)
    private val iconGap = theme.dpInt(6f)
    private var item: PreparedChatMessage? = null

    /** Status, labels and time as the row shows them, for tests. */
    var shownParts: List<String> = emptyList()
        private set

    init {
        addView(icon)
        addView(summary)
        addView(updated)
    }

    private fun line() = TextView(context).apply {
        theme.applyTo(this, TaskType.meta, theme.textTertiary)
        maxLines = 1
        isSingleLine = true
        ellipsize = TextUtils.TruncateAt.END
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    fun bind(next: PreparedChatMessage) {
        item = next
        val info = TaskInfoRow.decode(next.message.cardPayload)
        val bucket = info.bucket
        icon.setStatus(bucket, theme.statusTint(bucket))
        val separator = SEPARATOR
        summary.text = SpannableStringBuilder().apply {
            append(theme.statusText(info.bucket, info.failed))
            info.labels.forEach { label ->
                append(separator)
                val dot = length
                append(DOT_PLACEHOLDER)
                setSpan(LabelDot(theme.labelColor(label.color), theme.dp(6f), theme.dp(4f)), dot, length,
                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                append(label.name)
            }
        }
        updated.text = if (info.updated.isEmpty()) "" else separator + info.updated
        shownParts = TaskInfoRow.parts(info, theme)
        contentDescription = shownParts.joinToString(", ")
        requestLayout()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val current = item
        setMeasuredDimension(width, current?.cellHeightPx ?: 0)
        val side = current?.sideMarginPx ?: 0
        val exact = MeasureSpec.makeMeasureSpec(iconSize, MeasureSpec.EXACTLY)
        icon.measure(exact, exact)
        val unbounded = MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED)
        val available = (width - side * 2 - iconSize - iconGap).coerceAtLeast(0)
        updated.measure(MeasureSpec.makeMeasureSpec(available, MeasureSpec.AT_MOST), unbounded)
        summary.measure(MeasureSpec.makeMeasureSpec((available - updated.measuredWidth).coerceAtLeast(0), MeasureSpec.AT_MOST),
            unbounded)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val current = item ?: return
        val top = current.topMarginPx
        val lineHeight = summary.measuredHeight
        val rtl = layoutDirection == LAYOUT_DIRECTION_RTL
        var x = current.sideMarginPx
        fun place(view: View, viewTop: Int) {
            val left = if (rtl) width - x - view.measuredWidth else x
            view.layout(left, viewTop, left + view.measuredWidth, viewTop + view.measuredHeight)
            x += view.measuredWidth
        }
        place(icon, top + (lineHeight - iconSize) / 2)
        x += iconGap
        place(summary, top)
        place(updated, top)
    }

    /** A label's colour dot, with the gap after it; drawn on the text's centre line. */
    private class LabelDot(private val color: Int, private val size: Float, private val gap: Float) : ReplacementSpan() {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

        override fun getSize(paint: Paint, text: CharSequence?, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int =
            (size + gap).toInt()

        override fun draw(canvas: Canvas, text: CharSequence?, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int,
                          paint: Paint) {
            val metrics = paint.fontMetrics
            val centre = y + (metrics.ascent + metrics.descent) / 2f
            this.paint.color = color
            canvas.drawCircle(x + size / 2f, centre, size / 2f, this.paint)
        }
    }

    private companion object {
        const val SEPARATOR = " · "
        /** Stands in for a label's dot; replaced by [LabelDot] when drawn. */
        const val DOT_PLACEHOLDER = "•"
    }
}
