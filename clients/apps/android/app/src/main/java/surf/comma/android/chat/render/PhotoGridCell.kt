package surf.comma.android.chat.render

import android.content.Context
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import surf.comma.android.media.TimelineImageView
import surf.comma.android.media.localViewerImage
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible
import surf.comma.android.R
import surf.comma.android.ui.theme.NDotTypeface
import surf.comma.android.ui.theme.UiSansTypeface

internal const val PHOTO_CARD_BODY_HEIGHT_DP = 330f

/** Fixed 1–4 tile photo surface. Bitmap completion changes pixels, never timeline geometry. */
internal class PhotoGridCell(context: Context) : FrameLayout(context), TimelineMediaCell {
    private val density = resources.displayMetrics.density
    private val card = LinearLayout(context)
    private val cardParams = LayoutParams(
        LayoutParams.MATCH_PARENT,
        dp(PHOTO_CARD_BODY_HEIGHT_DP.toInt()),
        Gravity.TOP or Gravity.CENTER_HORIZONTAL,
    )
    private val mosaic = FrameLayout(context)
    private val footer = TextView(context)
    private val tiles = List(MAX_TILES) { createTile() }
    private val more = TextView(context)
    private var prepared: PreparedChatMessage? = null
    private var sources: List<String> = emptyList()
    var onImageClick: ((String) -> Unit)? = null

    init {
        card.orientation = LinearLayout.VERTICAL
        card.background = GradientDrawable().apply {
            setColor(ContextCompat.getColor(context, R.color.card_white))
            cornerRadius = dp(28).toFloat()
        }
        card.clipToOutline = true
        addView(card, cardParams)

        card.addView(
            mosaic,
            LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, dp(MOSAIC_HEIGHT_DP)),
        )
        tiles.forEach(mosaic::addView)

        more.apply {
            gravity = Gravity.CENTER
            typeface = NDotTypeface
            textSize = 20f
            setTextColor(ContextCompat.getColor(context, R.color.on_black))
            setBackgroundColor(0x66000000)
            isClickable = true
            isFocusable = true
            setOnClickListener {
                sources.getOrNull(MAX_TILES - 1)?.let { source -> onImageClick?.invoke(source) }
            }
            visibility = GONE
        }
        mosaic.addView(more)

        footer.apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), 0, dp(16), 0)
            typeface = UiSansTypeface
            textSize = 14f
            setTextColor(ContextCompat.getColor(context, R.color.text_primary))
            maxLines = 2
        }
        card.addView(
            footer,
            LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f),
        )
    }

    fun bind(item: PreparedChatMessage) {
        prepared = item
        sources = MessageLayoutPrecomputer.cardImages(item.message)
        footer.text = item.message.text.ifBlank {
            resources.getQuantityString(R.plurals.photo_count, sources.size, sources.size)
        }
        tiles.forEachIndexed { index, tile ->
            val source = sources.getOrNull(index)
            tile.isVisible = source != null
            tile.tag = source
            tile.setBackgroundColor(ContextCompat.getColor(context, R.color.image_placeholder))
            tile.contentDescription = source?.let { "Photo ${index + 1}" }
            tile.bind(source?.let(::localViewerImage))
        }
        val hiddenCount = (sources.size - MAX_TILES).coerceAtLeast(0)
        more.isVisible = hiddenCount > 0
        more.text = context.getString(R.string.photo_more_count, hiddenCount)
        contentDescription = footer.text
        requestLayout()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val bodyHeight = dp(PHOTO_CARD_BODY_HEIGHT_DP.toInt())
        val desiredHeight = prepared?.cellHeightPx ?: bodyHeight
        val top = (desiredHeight - bodyHeight).coerceAtLeast(0)
        cardParams.width = (width - dp(40)).coerceAtLeast(dp(160))
        cardParams.height = bodyHeight
        cardParams.topMargin = top
        setMeasuredDimension(width, resolveSize(desiredHeight, heightMeasureSpec))
        card.measure(
            MeasureSpec.makeMeasureSpec(cardParams.width, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(bodyHeight, MeasureSpec.EXACTLY),
        )
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        layoutTiles(mosaic.width, mosaic.height)
    }

    private fun layoutTiles(width: Int, height: Int) {
        val count = sources.size.coerceIn(0, MAX_TILES)
        val gap = dp(2)
        val halfWidth = (width - gap) / 2
        val halfHeight = (height - gap) / 2
        fun place(index: Int, left: Int, top: Int, right: Int, bottom: Int) {
            tiles[index].layout(left, top, right, bottom)
        }
        when (count) {
            1 -> place(0, 0, 0, width, height)
            2 -> {
                place(0, 0, 0, halfWidth, height)
                place(1, halfWidth + gap, 0, width, height)
            }
            3 -> {
                place(0, 0, 0, halfWidth, height)
                place(1, halfWidth + gap, 0, width, halfHeight)
                place(2, halfWidth + gap, halfHeight + gap, width, height)
            }
            4 -> {
                place(0, 0, 0, halfWidth, halfHeight)
                place(1, halfWidth + gap, 0, width, halfHeight)
                place(2, 0, halfHeight + gap, halfWidth, height)
                place(3, halfWidth + gap, halfHeight + gap, width, height)
            }
        }
        if (count == MAX_TILES && more.isVisible) {
            val last = tiles.last()
            more.layout(last.left, last.top, last.right, last.bottom)
        }
    }

    private fun createTile(): TimelineImageView = TimelineImageView(context).apply {
        onOpen = { (tag as? String)?.let { onImageClick?.invoke(it) } }
    }

    override fun setMediaVisible(visible: Boolean) { tiles.forEach { it.setVisible(visible) } }
    override fun releaseMedia() { tiles.forEach { it.release() } }

    private fun dp(value: Int): Int = (value * density).toInt()

    private companion object {
        const val MAX_TILES = 4
        const val MOSAIC_HEIGHT_DP = 270
    }
}
