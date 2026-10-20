package surf.comma.android.chat.live

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.TextPaint
import android.view.View
import androidx.core.content.ContextCompat
import androidx.core.graphics.ColorUtils
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.render.ChatCardRenderer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.ui.AppearanceStore
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography
import kotlin.math.roundToInt

/** A finished call in the chat; see [LiveRowKinds.CALL_LOG]. */
internal class CallLogCardRenderer(override val viewType: Int) : ChatCardRenderer {
    override val kind = LiveRowKinds.CALL_LOG
    override fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float) = CallLogRow.HEIGHT_DP.toFloat()
    override fun create(context: Context): View = CallLogRow(context)
    override fun bind(view: View, item: PreparedChatMessage) = (view as CallLogRow).bind(item)
}

/**
 * A capsule on the user's side, like their bubbles but lighter: a hung-up handset and "2:13 ·
 * Call ended" in the brand colour on a pale brand tint.
 */
internal class CallLogRow(context: Context) : View(context) {
    private val density = resources.displayMetrics.density
    private val brand = context.getColor(R.color.token_bg_brand_solid)
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ColorUtils.compositeColors(
            ColorUtils.setAlphaComponent(brand, if (AppearanceStore.isNight(context)) TINT_DARK else TINT_LIGHT),
            context.getColor(R.color.token_bg_primary),
        )
    }
    private val label = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = brand
        typeface = DesignFonts.inter(context, DesignFonts.medium)
        textSize = android.util.TypedValue.applyDimension(android.util.TypedValue.COMPLEX_UNIT_SP,
            DesignTypography.regular.sp, resources.displayMetrics)
        fontFeatureSettings = "tnum"
    }
    private val icon = ContextCompat.getDrawable(context, R.drawable.ic_call_end)!!.mutate().apply { setTint(brand) }
    private val pill = RectF()
    private var item: PreparedChatMessage? = null

    fun bind(item: PreparedChatMessage) {
        this.item = item
        contentDescription = item.message.text
        requestLayout()
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), item?.cellHeightPx ?: 0)

    override fun onDraw(canvas: Canvas) {
        val current = item ?: return
        val text = current.message.text
        val iconSize = dp(ICON_DP)
        val width = dp(PAD_DP) * 2 + iconSize + dp(GAP_DP) + label.measureText(text)
        val right = this.width - current.sideMarginPx.toFloat()
        val top = current.topMarginPx.toFloat()
        val height = dp(HEIGHT_DP)
        pill.set(right - width, top, right, top + height)
        canvas.drawRoundRect(pill, height / 2f, height / 2f, fill)
        val iconLeft = (pill.left + dp(PAD_DP)).roundToInt()
        val iconTop = (pill.centerY() - iconSize / 2f).roundToInt()
        icon.setBounds(iconLeft, iconTop, iconLeft + iconSize.roundToInt(), iconTop + iconSize.roundToInt())
        icon.draw(canvas)
        val metrics = label.fontMetrics
        val baseline = pill.centerY() - (metrics.ascent + metrics.descent) / 2f
        canvas.drawText(text, iconLeft + iconSize + dp(GAP_DP), baseline, label)
    }

    private fun dp(value: Int) = value * density

    companion object {
        const val HEIGHT_DP = 44
        const val PAD_DP = 16
        const val ICON_DP = 20
        const val GAP_DP = 8
        /** The brand colour over the page: 10 % light, 18 % dark (of 255). */
        const val TINT_LIGHT = 0x1A
        const val TINT_DARK = 0x2E
    }
}
