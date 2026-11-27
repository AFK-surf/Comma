package surf.comma.android.dynamicui

import android.content.Context
import android.content.res.ColorStateList
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.max
import kotlin.math.roundToInt
import surf.comma.android.R
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.chat.live.QuestionText
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatCardHeights
import surf.comma.android.chat.render.ChatCardRenderer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.settings.color
import surf.comma.android.settings.roundRect
import surf.comma.android.ui.kit.tactile
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level

/**
 * The card's type and geometry, shared by the view and [DynamicUiCardLayout] so they cannot disagree. Read the
 * typography when it is made: a page makes its own after the scale is configured.
 */
internal class DynamicUiCardStyle(context: Context) {
    private val metrics = context.resources.displayMetrics
    private fun dp(value: Float): Int = (value * metrics.density).roundToInt()

    val summary: QuestionText = DesignTypography.size(Level.REGULAR).let { size ->
        QuestionText(
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, size.sp, metrics),
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, size.lineHeightSp, metrics).roundToInt(),
            DesignFonts.inter(context, DesignFonts.regular),
        )
    }
    val padH = context.resources.getDimensionPixelSize(R.dimen.spacing_xl)
    val padV = dp(12f)
    val chevron = dp(20f)
    val chevronGap = dp(4f)
    val minHeight = dp(MIN_HEIGHT_DP)

    /** The summary's width in a card [cardWidthPx] wide. */
    fun textWidth(cardWidthPx: Int): Int = (cardWidthPx - padH * 2 - chevron - chevronGap).coerceAtLeast(1)

    /** The summary's height on its lines; the card is at least [minHeight] and centres a short summary in it. */
    fun textHeight(text: CharSequence, cardWidthPx: Int): Int = summary.height(text, textWidth(cardWidthPx))

    fun cardHeight(textHeight: Int): Int = max(minHeight, textHeight + padV * 2)

    private companion object {
        const val MIN_HEIGHT_DP = 72f
    }
}

/** Card heights measured ahead of time from the summary, so a long summary shows whole, as on iOS. */
internal class DynamicUiCardLayout(context: Context) : ChatCardHeights {
    private val style = DynamicUiCardStyle(context)

    override fun bodyHeightPx(message: ChatMessage, rowWidthPx: Int, sideMarginPx: Int): Int? {
        if (message.cardKind != LiveRowKinds.INTERACTIVE_SUMMARY) return null
        val width = (rowWidthPx - sideMarginPx * 2).coerceAtLeast(1)
        return style.cardHeight(style.textHeight(message.text, width))
    }
}

/**
 * A message's generated UI in the transcript: its whole summary and a chevron. It starts no WebView; a press opens
 * the widget in its own sheet. A widget the core gave no content for shows its summary and does nothing.
 */
internal class DynamicUiCardRenderer(override val viewType: Int) : ChatCardRenderer {
    override val kind = LiveRowKinds.INTERACTIVE_SUMMARY

    /** Used only where a page measures no [DynamicUiCardLayout]. */
    override fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float) = CARD_HEIGHT_DP

    override fun create(context: Context): View = DynamicUiChatRow(context)

    override fun bind(view: View, item: PreparedChatMessage) = (view as DynamicUiChatRow).bind(item)

    private companion object {
        const val CARD_HEIGHT_DP = 72f
    }
}

internal class DynamicUiChatRow(context: Context) : FrameLayout(context) {
    /** What a press does on this page; null leaves the card inert. */
    var hostOf: () -> ((DynamicUiTarget) -> Unit)? = { null }
    private val style = DynamicUiCardStyle(context)
    private val card = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        // Top, with the padding centring the text block: the chevron stays on the first line of a long summary.
        gravity = Gravity.TOP
        background = roundRect(context.color(R.color.token_bg_secondary), context.resources.getDimension(R.dimen.card_corner))
        setPadding(style.padH, 0, style.padH, 0)
        tactile()
    }
    private val summary = TextView(context).apply {
        style.summary.applyTo(this)
        setTextColor(context.color(R.color.token_text_primary))
    }
    private var item: PreparedChatMessage? = null
    private var target: DynamicUiTarget? = null

    init {
        card.addView(summary, LinearLayout.LayoutParams(0, -2, 1f))
        card.addView(ImageView(context).apply {
            setImageResource(R.drawable.ic_settings_chevron)
            imageTintList = ColorStateList.valueOf(context.color(R.color.token_fg_quaternary))
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(style.chevron, style.chevron).apply {
            marginStart = style.chevronGap
            // Centred on the first line.
            topMargin = (style.summary.fontHeight - style.chevron) / 2
        })
        card.setOnClickListener { target?.let { hostOf()?.invoke(it) } }
        addView(card)
    }

    fun bind(item: PreparedChatMessage) {
        this.item = item
        target = DynamicUiTarget.decode(item.message.cardPayload)
        summary.text = item.message.text
        card.isClickable = target != null
        card.isEnabled = target != null
        requestLayout()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val current = item
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = current?.cellHeightPx ?: 0
        setMeasuredDimension(width, height)
        val side = current?.sideMarginPx ?: 0
        val cardWidth = (width - side * 2).coerceAtLeast(0)
        val cardHeight = (height - (current?.topMarginPx ?: 0)).coerceAtLeast(0)
        val widthSpec = MeasureSpec.makeMeasureSpec(cardWidth, MeasureSpec.EXACTLY)
        val heightSpec = MeasureSpec.makeMeasureSpec(cardHeight, MeasureSpec.EXACTLY)
        card.measure(widthSpec, heightSpec)
        // Centre the text block from its own layout, whose height a recycled row's larger padding cannot clip. The
        // width is unchanged, so measuring again reuses that layout instead of laying the text out a second time.
        val text = summary.layout?.height ?: summary.measuredHeight
        val top = ((cardHeight - text) / 2).coerceAtLeast(0)
        if (top != card.paddingTop) {
            card.setPadding(style.padH, top, style.padH, 0)
            card.measure(widthSpec, heightSpec)
        }
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val current = item ?: return
        val left = if (current.message.role == ChatRole.USER) width - current.sideMarginPx - card.measuredWidth else current.sideMarginPx
        card.layout(left, current.topMarginPx, left + card.measuredWidth, current.topMarginPx + card.measuredHeight)
    }
}
