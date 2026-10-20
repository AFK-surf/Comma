package surf.comma.android.tasks.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Typeface
import android.graphics.text.LineBreaker
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import android.util.TypedValue
import android.widget.TextView
import androidx.annotation.ColorRes
import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import androidx.core.content.ContextCompat
import androidx.core.graphics.withTranslation
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.max
import surf.comma.android.R
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignLabelColors
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level

/** A text role on the task surfaces: a shared type-scale level plus a weight. */
data class TaskTextStyle(val level: DesignTypography.Level, val weight: Int)

/** Which shared level and weight each task text role uses. Sizes come from [DesignTypography]. */
object TaskType {
    val cardTitle = TaskTextStyle(Level.REGULAR, DesignFonts.medium)
    val body = TaskTextStyle(Level.REGULAR, DesignFonts.regular)
    val meta = TaskTextStyle(Level.SMALL, DesignFonts.regular)
    val metaMedium = TaskTextStyle(Level.SMALL, DesignFonts.medium)
    val sectionHeader = TaskTextStyle(Level.SMALL, DesignFonts.semibold)
    val pill = TaskTextStyle(Level.MINI, DesignFonts.regular)
    val pageTitle = TaskTextStyle(Level.TITLE3, DesignFonts.semibold)
    /** The title in a task page's bar: the large step (18/28) at medium weight. */
    val barTitle = TaskTextStyle(Level.LARGE, DesignFonts.medium)
}

/**
 * Colors, metrics and faces resolved once on the main thread. Immutable afterwards, so
 * layout preparation on a background thread can read it freely.
 */
class TaskTheme(context: Context) {
    private val appContext = context.applicationContext
    private val resources = context.resources
    /** Read once, so every row laid out by this theme uses the same scale. */
    private val promote = DesignTypography.promoteOneStep
    private val metrics = resources.displayMetrics
    val density: Float = metrics.density
    val locale: Locale = resources.configuration.locales[0]

    val bgPrimary = color(context, R.color.token_bg_primary)
    val bgSecondary = color(context, R.color.token_bg_secondary)
    val bgTertiary = color(context, R.color.token_bg_tertiary)
    val bgQuaternary = color(context, R.color.token_bg_quaternary)
    val bgOverlay = color(context, R.color.token_bg_overlay)
    val textPrimary = color(context, R.color.token_text_primary)
    val textSecondary = color(context, R.color.token_text_secondary)
    val textTertiary = color(context, R.color.token_text_tertiary)
    val textQuaternary = color(context, R.color.token_text_quaternary)
    val borderPrimary = color(context, R.color.token_border_primary)
    val borderSecondary = color(context, R.color.token_border_secondary)
    val fgQuaternary = color(context, R.color.token_fg_quaternary)

    /** A 0.5dp design hairline, drawn as one physical pixel (DESIGN.md §4). */
    val hairlinePx: Float = 1f

    private val statusTints = TaskStatusBucket.entries.associateWith { color(context, statusTintRes(it)) }
    private val statusLabels = TaskStatusBucket.entries.associateWith { context.getString(statusLabelRes(it)) }

    fun dp(value: Float): Float = value * density

    fun dpInt(value: Float): Int = (value * density + 0.5f).toInt()

    fun sp(value: Float): Float =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, value, metrics)

    fun statusTint(bucket: TaskStatusBucket): Int = statusTints.getValue(bucket)

    fun statusLabel(bucket: TaskStatusBucket): String = statusLabels.getValue(bucket)

    /**
     * What a task's own status says, for the card and the detail line. Failures fold into the
     * cancelled group like everywhere else, but are not called cancelled.
     */
    fun statusText(bucket: TaskStatusBucket, failed: Boolean): String = if (failed) failedLabel else statusLabel(bucket)

    private val failedLabel = context.getString(R.string.task_status_failed)

    /** A label's `color` field as a color: preset name, `#rrggbb`, or gray for anything else. */
    fun labelColor(color: String?): Int = DesignLabelColors.resolve(appContext, color)

    fun size(style: TaskTextStyle): DesignTypography.Size = DesignTypography.size(style.level, promote)

    /** A fresh paint per call: layouts built on different threads must not share one. */
    fun paint(style: TaskTextStyle, color: Int): TextPaint =
        TextPaint(TextPaint.ANTI_ALIAS_FLAG).apply {
            val size = size(style)
            typeface = typeface(style.weight)
            textSize = sp(size.sp)
            letterSpacing = size.letterSpacingEm
            this.color = color
            textLocale = locale
        }

    fun typeface(weight: Int): Typeface = DesignFonts.inter(appContext, weight)

    /** Shared font, size, line height and letter spacing for a plain TextView. */
    fun applyTo(view: TextView, style: TaskTextStyle, color: Int) {
        DesignTypography.applyTo(view, style.level, style.weight, promote)
        view.setTextColor(color)
    }

    private companion object {

        fun color(context: Context, @ColorRes id: Int): Int = ContextCompat.getColor(context, id)
    }
}

/** The glyph of [bucket]; null, a task whose status is not known, draws the neutral dashed ring. */
@DrawableRes
fun statusIconRes(bucket: TaskStatusBucket?): Int = when (bucket) {
    null -> R.drawable.ic_task_neutral
    TaskStatusBucket.IN_PROGRESS -> R.drawable.ic_task_in_progress
    TaskStatusBucket.NEEDS_REVIEW -> R.drawable.ic_task_needs_review
    TaskStatusBucket.DONE -> R.drawable.ic_task_done
    TaskStatusBucket.CANCELLED -> R.drawable.ic_task_cancelled
    TaskStatusBucket.ARCHIVED -> R.drawable.ic_task_archived
}

@ColorRes
fun statusTintRes(bucket: TaskStatusBucket): Int = when (bucket) {
    TaskStatusBucket.NEEDS_REVIEW -> R.color.token_fg_attention
    TaskStatusBucket.DONE -> R.color.token_fg_success
    TaskStatusBucket.CANCELLED -> R.color.token_fg_error
    TaskStatusBucket.IN_PROGRESS,
    TaskStatusBucket.ARCHIVED,
    -> R.color.token_fg_quaternary
}

@StringRes
fun statusLabelRes(bucket: TaskStatusBucket): Int = when (bucket) {
    TaskStatusBucket.IN_PROGRESS -> R.string.task_status_in_progress
    TaskStatusBucket.NEEDS_REVIEW -> R.string.task_status_needs_review
    TaskStatusBucket.DONE -> R.string.task_status_done
    TaskStatusBucket.CANCELLED -> R.string.task_status_cancelled
    TaskStatusBucket.ARCHIVED -> R.string.task_status_archived
}

/**
 * A laid-out run of text on a fixed line rhythm. Every line box is exactly [lineHeightPx]
 * tall, so a block's height is known from its line count alone and rows never shift when
 * a fallback face (CJK, emoji) is taller than the primary one.
 */
class TextBlock(
    val layout: StaticLayout,
    val lineHeightPx: Int,
    /** Offset that centres the glyphs inside each line box. */
    private val glyphShiftPx: Float,
) {
    val heightPx: Int get() = layout.lineCount * lineHeightPx

    /** Widest line actually drawn, which may be narrower than the layout width. */
    val contentWidthPx: Int = run {
        var widest = 0f
        for (line in 0 until layout.lineCount) widest = max(widest, layout.getLineWidth(line))
        ceil(widest).toInt()
    }

    fun draw(canvas: Canvas, left: Float, top: Float) {
        canvas.withTranslation(left, top + glyphShiftPx) { layout.draw(this) }
    }

    companion object {
        /** Safe off the main thread as long as [paint] is not shared with another thread. */
        fun build(
            text: CharSequence,
            paint: TextPaint,
            lineHeightPx: Int,
            widthPx: Int,
            maxLines: Int = 1,
        ): TextBlock {
            val width = max(1, widthPx)
            val metrics = paint.fontMetricsInt
            val natural = metrics.descent - metrics.ascent
            val extra = lineHeightPx - natural
            val layout = StaticLayout.Builder.obtain(text, 0, text.length, paint, width)
                .setAlignment(Layout.Alignment.ALIGN_NORMAL)
                .setIncludePad(false)
                .setUseLineSpacingFromFallbacks(false)
                .setLineSpacing(extra.toFloat(), 1f)
                .setMaxLines(maxLines)
                .setEllipsize(TextUtils.TruncateAt.END)
                .setBreakStrategy(LineBreaker.BREAK_STRATEGY_SIMPLE)
                .build()
            return TextBlock(layout, lineHeightPx, extra / 2f)
        }

        /** One line, as wide as the text needs up to [maxWidthPx]. */
        fun singleLine(text: CharSequence, paint: TextPaint, lineHeightPx: Int, maxWidthPx: Int): TextBlock {
            val natural = ceil(paint.measureText(text, 0, text.length)).toInt()
            return build(text, paint, lineHeightPx, minOf(natural, maxWidthPx))
        }
    }
}

/** Builds text blocks from a [TaskTextStyle] with the theme's metrics. */
fun TaskTheme.block(
    text: CharSequence,
    style: TaskTextStyle,
    color: Int,
    widthPx: Int,
    maxLines: Int = 1,
): TextBlock = TextBlock.build(text, paint(style, color), lineHeightPx(style), widthPx, maxLines)

fun TaskTheme.line(text: CharSequence, style: TaskTextStyle, color: Int, maxWidthPx: Int): TextBlock =
    TextBlock.singleLine(text, paint(style, color), lineHeightPx(style), maxWidthPx)

fun TaskTheme.lineHeightPx(style: TaskTextStyle): Int = (sp(size(style).lineHeightSp) + 0.5f).toInt()
