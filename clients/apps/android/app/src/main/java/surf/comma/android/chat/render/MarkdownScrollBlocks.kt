package surf.comma.android.chat.render

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.View
import android.widget.FrameLayout
import androidx.core.content.ContextCompat
import androidx.core.graphics.withTranslation
import surf.comma.android.R
import surf.comma.android.scroll.widget.ScrollContainer

/**
 * Where each code block's and table's sideways scroll stands, by message id and block. It lives
 * outside the recycled cells, so a block scrolled away and back keeps its place, and a cell
 * reused for another message never shows that message at someone else's offset.
 */
internal class BlockScrollBook(private val capacity: Int = DEFAULT_CAPACITY) {
    private val offsets = object : LinkedHashMap<Key, Int>(capacity, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, Int>) = size > capacity
    }

    data class Key(val messageId: Long, val contentIndex: Int)

    operator fun get(key: Key): Int = offsets[key] ?: 0

    operator fun set(key: Key, offset: Int) {
        if (offset == 0) offsets.remove(key) else offsets[key] = offset
    }

    val size: Int get() = offsets.size

    private companion object {
        const val DEFAULT_CAPACITY = 128
    }
}

/**
 * The part of a code block, table or display formula that scrolls sideways, drawn at its natural
 * width. A code block's header and copy button are drawn by the cell above it and stay put.
 */
internal class ScrollableBlockBody(context: Context) : View(context) {
    var block: PreparedContentBlock? = null
        set(value) {
            if (field === value) return
            field = value
            invalidate()
        }
    private val rulePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val bounds = RectF()
    private val density = resources.displayMetrics.density

    override fun onDraw(canvas: Canvas) {
        when (val block = block) {
            is PreparedContentBlock.Code ->
                canvas.withTranslation(block.padPx.toFloat(), block.padPx.toFloat()) { block.layout.draw(this) }
            is PreparedContentBlock.Table -> drawTable(canvas, block)
            is PreparedContentBlock.Math -> block.box.draw(canvas, block.padHPx.toFloat(), block.padVPx.toFloat(), block.color)
            else -> Unit
        }
    }

    /**
     * 表格：表头下一条实线，行与行之间一条细线，列之间留白不画竖线——
     * 表格靠留白和字重分栏，不是靠网格线。外框和行线跟着内容一起滚。
     */
    private fun drawTable(canvas: Canvas, block: PreparedContentBlock.Table) {
        rulePaint.color = ContextCompat.getColor(context, R.color.token_markdown_border_table)
        val hairline = (1f * density).coerceAtLeast(1f)
        val radius = TABLE_CORNER_DP * density
        rulePaint.style = Paint.Style.STROKE
        rulePaint.strokeWidth = hairline
        bounds.set(hairline / 2f, hairline / 2f, block.contentWidthPx - hairline / 2f, block.heightPx - hairline / 2f)
        canvas.drawRoundRect(bounds, radius, radius, rulePaint)
        rulePaint.style = Paint.Style.FILL
        block.rowEdges.forEachIndexed { index, edge ->
            if (index == 0 || index == block.rowEdges.lastIndex) return@forEachIndexed
            canvas.drawRect(0f, edge.toFloat(), block.contentWidthPx.toFloat(), edge + hairline, rulePaint)
        }
        block.cells.forEach { cell ->
            canvas.withTranslation(cell.leftPx.toFloat(), cell.topPx.toFloat()) { cell.layout.draw(this) }
        }
    }

    companion object {
        const val TABLE_CORNER_DP = 6f
    }
}

/**
 * One sideways-scrolling region of a message: a `:scroll` [ScrollContainer] over the block's
 * body. Drags, flings, overscroll and the choice between this and the vertical timeline all
 * belong to the container; the slot only places it and remembers its offset.
 */
internal class ScrollableBlockSlot(context: Context, private val book: () -> BlockScrollBook) {
    val body = ScrollableBlockBody(context)
    val container = ScrollContainer(context).apply {
        orientation = ScrollContainer.HORIZONTAL
        // A block that fits leaves taps, long presses and page drags to the cell around it.
        yieldsWhenContentFits = true
        isHorizontalScrollBarEnabled = false
        addView(body, FrameLayout.LayoutParams(0, 0))
        onScrollOffsetChanged = { offset -> key?.let { book()[it] = offset } }
    }
    var key: BlockScrollBook.Key? = null
        private set
    /** Where the scrolling region sits in the cell, before the cell's column offset. */
    var top = 0
        private set
    var leftInset = 0
        private set
    var viewportWidth = 0
        private set
    var viewportHeight = 0
        private set
    var contentWidth = 0
        private set
    var blockIndex = -1
    private var forcedLeftToRight = false

    fun bind(messageId: Long, index: Int, block: PreparedContentBlock, horizontalPaddingPx: Int) {
        val nextKey = BlockScrollBook.Key(messageId, block.contentIndex)
        blockIndex = index
        when (block) {
            is PreparedContentBlock.Code -> {
                top = block.yOffsetPx + block.headerHeightPx
                leftInset = horizontalPaddingPx
                viewportWidth = block.viewportWidthPx
                viewportHeight = block.heightPx - block.headerHeightPx
                contentWidth = block.contentWidthPx
            }
            is PreparedContentBlock.Table -> {
                top = block.yOffsetPx
                leftInset = horizontalPaddingPx + block.leftInsetPx
                viewportWidth = minOf(block.contentWidthPx, block.viewportWidthPx)
                viewportHeight = block.heightPx
                contentWidth = block.contentWidthPx
            }
            is PreparedContentBlock.Math -> {
                top = block.yOffsetPx
                leftInset = horizontalPaddingPx + block.leftInsetPx
                viewportWidth = minOf(block.contentWidthPx, block.viewportWidthPx)
                viewportHeight = block.heightPx
                contentWidth = block.contentWidthPx
            }
            else -> error("Only code blocks, tables and formulas scroll sideways")
        }
        // A formula reads left to right on any page, so it starts scrolled to its left edge.
        val leftToRight = block is PreparedContentBlock.Math
        if (forcedLeftToRight != leftToRight) {
            forcedLeftToRight = leftToRight
            container.layoutDirection = if (leftToRight) View.LAYOUT_DIRECTION_LTR else View.LAYOUT_DIRECTION_INHERIT
            // The same offset counts from the other edge now.
            key = null
        }
        body.block = block
        val lp = body.layoutParams
        if (lp.width != contentWidth || lp.height != viewportHeight) {
            lp.width = contentWidth
            lp.height = viewportHeight
            body.layoutParams = lp
        }
        if (nextKey != key) {
            key = nextKey
            // A different block: take up where this one was left, or at its start.
            container.scrollOffset = book()[nextKey]
        }
    }

    /**
     * The cell's new message has fewer scrolling blocks than this slot can hold. A fling stops
     * where it is (the book already has that offset), and the old layout is let go. With no key,
     * nothing more is written to the book, and the next [bind] restores from it.
     */
    fun release() {
        container.stopScroll()
        key = null
        blockIndex = -1
        body.block = null
    }

    companion object {
        fun scrolls(block: PreparedContentBlock): Boolean =
            block is PreparedContentBlock.Code || block is PreparedContentBlock.Table ||
                block is PreparedContentBlock.Math
    }
}
