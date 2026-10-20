package surf.comma.android.chat.render

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.Layout
import android.text.Spanned
import android.text.TextPaint
import android.text.style.LineBackgroundSpan
import android.text.style.MetricAffectingSpan
import kotlin.math.max
import kotlin.math.min

/**
 * Inline code in a message: the body colour on a quiet rounded block, set a little smaller than
 * the text around it so a run of identifiers does not shout.
 *
 * The block is drawn by the layout itself, line by line, so every surface that draws a message
 * layout (cells, table cells, the select-text page) gets it without code of its own. The block is
 * placed by measuring the line up to the span with the layout's own paint and spans.
 */
class InlineCodeSpan(
    private val textColor: Int,
    private val backgroundColor: Int,
) : MetricAffectingSpan(), LineBackgroundSpan {
    /** How the layout aligns its lines; a table cell may centre or right-align. */
    var alignment: Layout.Alignment = Layout.Alignment.ALIGN_NORMAL

    private val measure = TextPaint()
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val bounds = RectF()
    /**
     * Where the block starts on each line it touches, and how wide it is, by line start. Measuring
     * shapes text, so a line is measured once: a cell that is bound again redraws from here.
     * A span belongs to one laid-out text, at one width and size, so the line starts are stable.
     */
    private val measured = HashMap<Long, FloatArray>()
    private val metrics = Paint.FontMetrics()

    override fun updateDrawState(paint: TextPaint) {
        paint.color = textColor
        paint.textSize *= SIZE_SCALE
    }

    override fun updateMeasureState(paint: TextPaint) {
        paint.textSize *= SIZE_SCALE
    }

    override fun drawBackground(
        canvas: Canvas,
        paint: Paint,
        left: Int,
        right: Int,
        top: Int,
        baseline: Int,
        bottom: Int,
        text: CharSequence,
        start: Int,
        end: Int,
        lineNumber: Int,
    ) {
        val spanned = text as? Spanned ?: return
        val from = max(spanned.getSpanStart(this), start)
        var to = min(spanned.getSpanEnd(this), end)
        while (to > from && text[to - 1].isWhitespace()) to--
        if (to <= from) return
        val key = (start.toLong() shl 32) or (paint.textSize.toRawBits().toLong() and 0xFFFFFFFFL)
        val spot = measured.getOrPut(key) {
            measure.set(paint)
            var lineEnd = end
            while (lineEnd > start && text[lineEnd - 1].isWhitespace()) lineEnd--
            val lead = Layout.getDesiredWidth(text, start, from, measure)
            val width = Layout.getDesiredWidth(text, from, to, measure)
            val lineStart = when (alignment) {
                Layout.Alignment.ALIGN_NORMAL -> 0f
                Layout.Alignment.ALIGN_CENTER -> (right - left - Layout.getDesiredWidth(text, start, lineEnd, measure)) / 2f
                Layout.Alignment.ALIGN_OPPOSITE -> right - left - Layout.getDesiredWidth(text, start, lineEnd, measure)
            }
            floatArrayOf(lineStart + lead, width)
        }
        val size = paint.textSize
        paint.getFontMetrics(metrics)
        val padH = size * PAD_H
        val padV = size * PAD_V
        bounds.set(
            left + spot[0] - padH,
            baseline + metrics.ascent * SIZE_SCALE - padV,
            left + spot[0] + spot[1] + padH,
            baseline + metrics.descent * SIZE_SCALE + padV,
        )
        fill.color = backgroundColor
        val radius = size * RADIUS
        canvas.drawRoundRect(bounds, radius, radius, fill)
    }

    companion object {
        /** Relative to the surrounding text: 16sp body gives 14.4sp code. */
        const val SIZE_SCALE = 0.9f
        /** Of the surrounding text size: about 4dp of rounding and 2dp of side padding at 16sp. */
        private const val RADIUS = 0.25f
        private const val PAD_H = 0.15f
        private const val PAD_V = 0.02f
    }
}
