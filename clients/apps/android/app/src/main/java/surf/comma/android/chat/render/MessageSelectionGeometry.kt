package surf.comma.android.chat.render

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.RectF
import android.text.Layout
import java.text.BreakIterator
import kotlin.math.abs

/** Selection coordinates use the layouts already on screen, including horizontal block offsets. */
internal class MessageSelectionGeometry(val item: PreparedChatMessage) {
    private val document = SelectableText.document(item.contents)
    val text = document.text.toString()
    private val characters = BreakIterator.getCharacterInstance().apply { setText(this@MessageSelectionGeometry.text) }
    private val scrolling = item.blocks.filter(ScrollableBlockSlot::scrolls).map { it.contentIndex }.distinct()
    private var lastColumn = Float.NaN
    private var lastOffsets = emptyList<Int>()
    private var cachedRuns = emptyList<Run>()

    data class Run(
        val layout: Layout?,
        val base: Int,
        val start: Int,
        val end: Int,
        val x: Float,
        val y: Float,
        val clip: RectF,
    ) {
        fun caret(offset: Int, trailing: Boolean): PointF {
            val local = (offset - base).coerceIn(start - base, end - base)
            val line = layout?.getLineForOffset(local)
            return if (layout != null && line != null) PointF(
                x + layout.getPrimaryHorizontal(local), y + layout.getLineBottom(line))
            else PointF(if (trailing) clip.right else clip.left, clip.bottom)
        }
    }

    fun runs(columnLeft: Float, scrollOffset: (Int) -> Int): List<Run> {
        val offsets = scrolling.map(scrollOffset)
        if (columnLeft != lastColumn || offsets != lastOffsets) {
            cachedRuns = buildRuns(columnLeft, scrollOffset)
            lastColumn = columnLeft
            lastOffsets = offsets
        }
        return cachedRuns
    }

    private fun buildRuns(columnLeft: Float, scrollOffset: (Int) -> Int): List<Run> = buildList {
        item.blocks.forEach { block ->
            val range = document.ranges.getOrNull(block.contentIndex) ?: return@forEach
            val piece = text.substring(range)
            val column = columnLeft + item.horizontalPaddingPx
            fun addLayout(layout: Layout, x: Float, y: Float, clip: RectF, searchFrom: Int = 0): Int {
                val source = layout.text.toString().trimEnd('\n')
                val offset = piece.indexOf(source, searchFrom).takeIf { it >= 0 } ?: return searchFrom
                val base = range.first + offset
                val start = (base + layout.getLineStart(0)).coerceAtMost(range.last + 1)
                val end = (base + layout.getLineEnd(layout.lineCount - 1)).coerceAtMost(range.last + 1)
                if (end > start) add(Run(layout, base, start, end, x, y, clip))
                return offset + source.length
            }
            when (block) {
                is PreparedContentBlock.Text -> {
                    val x = column + block.padPx + block.leftInsetPx
                    val y = (block.yOffsetPx + block.padPx).toFloat()
                    block.marker?.let { marker ->
                        val mx = column + marker.columnRightPx - marker.layout.width
                        addLayout(marker.layout, mx, y, RectF(mx, y, x, y + marker.layout.height))
                    }
                    addLayout(block.layout, x, y, RectF(x, y, x + block.layout.width, y + block.layout.height))
                }
                is PreparedContentBlock.Code -> {
                    val y = (block.yOffsetPx + block.headerHeightPx).toFloat()
                    val clip = RectF(column, y, column + block.viewportWidthPx, (block.yOffsetPx + block.heightPx).toFloat())
                    addLayout(block.layout, column + block.padPx - scrollOffset(block.contentIndex),
                        y + block.padPx, clip)
                }
                is PreparedContentBlock.Table -> {
                    val x = column + block.leftInsetPx
                    val y = block.yOffsetPx.toFloat()
                    val clip = RectF(x, y, x + minOf(block.viewportWidthPx, block.contentWidthPx), y + block.heightPx)
                    var offset = 0
                    for (cell in block.cells) {
                        offset = addLayout(cell.layout, x + cell.leftPx - scrollOffset(block.contentIndex),
                            y + cell.topPx, clip, offset)
                    }
                }
                is PreparedContentBlock.Math -> {
                    val x = column + block.leftInsetPx
                    val clip = RectF(x, block.yOffsetPx.toFloat(), x + minOf(block.viewportWidthPx, block.contentWidthPx),
                        (block.yOffsetPx + block.heightPx).toFloat())
                    add(Run(null, range.first, range.first, range.last + 1, x, clip.top, clip))
                }
                else -> Unit
            }
        }
    }

    fun offsetAt(runs: List<Run>, x: Float, y: Float): Int {
        val run = runs.minByOrNull {
            val bounds = it.layout?.let { layout -> RectF(it.x, it.y, it.x + layout.width, it.y + layout.height) }
                ?: RectF(it.clip)
            if (!bounds.intersect(it.clip)) return@minByOrNull Float.MAX_VALUE
            val dy = maxOf(bounds.top - y, 0f, y - bounds.bottom)
            val dx = maxOf(bounds.left - x, 0f, x - bounds.right)
            dy * dy + dx * dx
        } ?: return 0
        val layout = run.layout ?: return if (x < run.clip.centerX()) run.start else run.end
        val line = layout.getLineForVertical((y - run.y).toInt())
        val offset = run.base + layout.getOffsetForHorizontal(line, x - run.x)
        return boundary(offset.coerceIn(run.start, run.end))
    }

    fun wordAt(offset: Int): IntRange {
        if (text.isEmpty()) return IntRange.EMPTY
        val at = offset.coerceIn(0, text.lastIndex)
        val words = BreakIterator.getWordInstance().apply { setText(this@MessageSelectionGeometry.text) }
        val start = if (words.isBoundary(at)) at else words.preceding(at).coerceAtLeast(0)
        val end = words.following(at).takeIf { it != BreakIterator.DONE } ?: text.length
        return boundary(start) until boundary(end)
    }

    fun boundary(offset: Int): Int {
        val at = offset.coerceIn(0, text.length)
        if (characters.isBoundary(at)) return at
        val before = characters.preceding(at).coerceAtLeast(0)
        val after = characters.following(at).takeIf { it != BreakIterator.DONE } ?: text.length
        return if (abs(at - before) < abs(after - at)) before else after
    }

    fun caret(runs: List<Run>, offset: Int, trailing: Boolean): PointF? {
        val candidates = runs.filter { if (trailing) offset > it.start && offset <= it.end else offset >= it.start && offset < it.end }
        val run = candidates.firstOrNull() ?: if (trailing) runs.lastOrNull() else runs.firstOrNull()
        return run?.caret(offset.coerceIn(run.start, run.end), trailing)?.takeIf {
            it.x >= run.clip.left && it.x <= run.clip.right
        }
    }

    fun draw(canvas: Canvas, runs: List<Run>, start: Int, end: Int, paint: Paint) {
        val path = Path()
        val visible = RectF(canvas.clipBounds)
        for (run in runs) {
            val from = maxOf(start, run.start)
            val to = minOf(end, run.end)
            if (from >= to || !RectF.intersects(visible, run.clip)) continue
            val save = canvas.save()
            canvas.clipRect(run.clip)
            if (run.layout == null) canvas.drawRect(run.clip, paint)
            else {
                path.reset()
                run.layout.getSelectionPath(from - run.base, to - run.base, path)
                canvas.translate(run.x, run.y)
                canvas.drawPath(path, paint)
            }
            canvas.restoreToCount(save)
        }
    }
}
