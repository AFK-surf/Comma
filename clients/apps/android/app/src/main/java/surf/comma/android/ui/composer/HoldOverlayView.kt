package surf.comma.android.ui.composer

import android.content.Context
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignTypography

/**
 * Covers the page while holding to talk: a dimmed backdrop, the live transcript centred in a bubble
 * styled like the user message it is about to become, and a caption above the composer saying
 * what releasing will do. The composer underneath keeps showing the voice bars and elapsed time.
 */
internal class HoldOverlayView(context: Context, private val style: ComposerStyle) : FrameLayout(context) {

    val bubble = TextView(context)
    private val caption = TextView(context)
    private val bubbleFill = GradientDrawable().apply {
        setColor(style.brand)
        cornerRadius = style.dp(20f)
    }

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        background = ColorDrawable(context.getColor(R.color.token_bg_overlay)).apply { alpha = SCRIM_ALPHA }
        bubble.apply {
            background = bubbleFill
            gravity = Gravity.CENTER
            setTextColor(style.onBrand)
            style.applyText(this, DesignTypography.Level.TITLE3)
            setPadding(style.dp(22), style.dp(16), style.dp(22), style.dp(16))
            minWidth = style.dp(120)
            minHeight = style.dp(64)
            maxLines = MAX_LINES
        }
        addView(bubble, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER).apply {
            leftMargin = style.dp(SIDE_MARGIN_DP)
            rightMargin = style.dp(SIDE_MARGIN_DP)
        })
        caption.apply {
            gravity = Gravity.CENTER
            style.applyText(this, DesignTypography.Level.REGULAR)
        }
        addView(caption, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL))
        reset()
    }

    fun reset() {
        setTranscript("")
        setCancelZone(false)
        setAutoEndSeconds(null)
    }

    fun setTranscript(text: String) {
        listening = text.isEmpty()
        // Long dictation keeps its newest words in view; the start scrolls away.
        bubble.text = when {
            listening -> context.getString(R.string.composer_listening)
            text.length > MAX_SHOWN_CHARS -> "…" + text.takeLast(MAX_SHOWN_CHARS)
            else -> text
        }
        applyColors()
    }

    fun showRecognizing() {
        if (listening) bubble.text = context.getString(R.string.composer_recognizing)
        caption.visibility = INVISIBLE
    }

    /** Keeps the caption just above the composer, which stays under the backdrop. */
    fun setBottomClearance(px: Int) {
        val params = caption.layoutParams as LayoutParams
        val margin = px + style.dp(CAPTION_GAP_DP)
        if (params.bottomMargin == margin) return
        params.bottomMargin = margin
        caption.layoutParams = params
    }

    private var listening = true
    private var inCancelZone = false
    private var autoEndSeconds: Int? = null

    fun setCancelZone(inZone: Boolean) {
        inCancelZone = inZone
        applyColors()
        updateCaption()
    }

    /** Last seconds before the time limit sends by itself; null hides the countdown. */
    fun setAutoEndSeconds(seconds: Int?) {
        if (autoEndSeconds == seconds) return
        autoEndSeconds = seconds
        updateCaption()
    }

    private fun applyColors() {
        bubbleFill.setColor(if (inCancelZone) style.bgTertiary else style.brand)
        val text = if (inCancelZone) style.textTertiary else style.onBrand
        bubble.setTextColor(if (listening) (text and 0x00FFFFFF) or (0xB8 shl 24) else text)
    }

    private fun updateCaption() {
        caption.visibility = VISIBLE
        val seconds = autoEndSeconds
        caption.text = when {
            inCancelZone -> context.getString(R.string.composer_hold_cancel_hint)
            seconds != null -> context.getString(R.string.composer_hold_auto_end, seconds)
            else -> context.getString(R.string.composer_hold_hint)
        }
        caption.setTextColor(if (inCancelZone) style.textError else onScrim(SECONDARY_ALPHA))
    }

    /** The backdrop is dark in both themes, so copy on it is light in both. */
    private fun onScrim(alpha: Int): Int = (style.onBrand and 0x00FFFFFF) or (alpha shl 24)

    companion object {
        /** The bubble may grow to the screen width less this on each side. */
        const val SIDE_MARGIN_DP = 24
        /** 90% of the overlay token: the page behind recedes without competing with the caption. */
        private const val SCRIM_ALPHA = 0xE6
        private const val SECONDARY_ALPHA = 0xB3
        private const val MAX_LINES = 8
        private const val MAX_SHOWN_CHARS = 160
        private const val CAPTION_GAP_DP = 24
    }
}
