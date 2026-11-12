package surf.comma.android.dynamicui

import android.content.Context
import android.content.res.ColorStateList
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import surf.comma.android.R
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatCardRenderer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.roundRect
import surf.comma.android.settings.text
import surf.comma.android.ui.kit.tactile
import surf.comma.android.ui.theme.DesignTypography.Level

/**
 * A message's generated UI in the transcript: its summary and a chevron. It starts no WebView; a press opens the
 * widget in its own sheet. A widget the core gave no content for shows its summary and does nothing.
 */
internal class DynamicUiCardRenderer(override val viewType: Int) : ChatCardRenderer {
    override val kind = LiveRowKinds.INTERACTIVE_SUMMARY

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
    private val card = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = roundRect(context.color(R.color.token_bg_secondary), context.resources.getDimension(R.dimen.card_corner))
        val margin = context.resources.getDimensionPixelSize(R.dimen.spacing_xl)
        setPadding(margin, 0, margin, 0)
        tactile()
    }
    private val summary = context.text(Level.REGULAR, R.color.token_text_primary).apply {
        maxLines = 2
        ellipsize = TextUtils.TruncateAt.END
    }
    private var item: PreparedChatMessage? = null
    private var target: DynamicUiTarget? = null

    init {
        card.addView(summary, LinearLayout.LayoutParams(0, -2, 1f))
        card.addView(ImageView(context).apply {
            setImageResource(R.drawable.ic_settings_chevron)
            imageTintList = ColorStateList.valueOf(context.color(R.color.token_fg_quaternary))
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(context.dp(20), context.dp(20)).apply { marginStart = context.dp(4) })
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
        card.measure(MeasureSpec.makeMeasureSpec((width - side * 2).coerceAtLeast(0), MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec((height - (current?.topMarginPx ?: 0)).coerceAtLeast(0), MeasureSpec.EXACTLY))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val current = item ?: return
        val left = if (current.message.role == ChatRole.USER) width - current.sideMarginPx - card.measuredWidth else current.sideMarginPx
        card.layout(left, current.topMarginPx, left + card.measuredWidth, current.topMarginPx + card.measuredHeight)
    }
}
