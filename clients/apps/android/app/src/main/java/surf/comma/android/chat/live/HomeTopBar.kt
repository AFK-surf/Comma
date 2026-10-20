package surf.comma.android.chat.live

import android.content.Context
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.core.graphics.ColorUtils
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography
import kotlin.math.roundToInt

/**
 * What floats over the top of the chat, with no bar behind it: the sidebar button on the left,
 * the Call button on the right (only while the workspace can take calls; otherwise that side is
 * empty), and between them Comma's mark over a capsule. The account lives in the sidebar.
 *
 * The capsule always just says "Comma"; a lost connection shows in its own notice under the bar
 * ([ConnectionNoticeView]).
 *
 * Only the buttons and the capsule take touches; a drag that starts anywhere else goes through to
 * the conversation, which scrolls up behind all of it under a frosted band.
 */
internal class HomeTopBar(
    context: Context,
    /**
     * The router chat over the tabs, as the iOS app draws it: a close chevron on the left, Comma's mark alone in
     * the middle at a navigation bar's size, and the Call button on the right. Without it, the full-page chat's
     * large mark and capsule.
     */
    private val compact: Boolean = false,
) : FrameLayout(context) {
    private val density = resources.displayMetrics.density
    private val fill = ColorUtils.setAlphaComponent(context.getColor(R.color.token_bg_primary), CHROME_FILL_ALPHA)
    private val stroke = context.getColor(R.color.token_border_primary)

    val menuButton = FrameLayout(context).apply {
        id = R.id.chat_sidebar_button
        contentDescription = context.getString(if (compact) R.string.shell_close_chat else R.string.chat_open_sidebar)
        isClickable = true
        isFocusable = true
        background = circle(inset = (TOUCH_TARGET_DP - BUTTON_DP) / 2)
        addView(ImageView(context).apply {
            setImageDrawable(ContextCompat.getDrawable(context, if (compact) R.drawable.ic_nav_chevron_down else R.drawable.ic_chat_menu)?.mutate()?.apply {
                setTint(context.getColor(R.color.token_fg_primary))
            })
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LayoutParams(dp(ICON_DP), dp(ICON_DP), Gravity.CENTER))
    }

    private val callCircle = GradientDrawable().apply { shape = GradientDrawable.OVAL }
    private val callIcon = ImageView(context).apply {
        setImageDrawable(ContextCompat.getDrawable(context, R.drawable.ic_chat_call)?.mutate())
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** Starts a voice call, or opens the one in progress. Hidden while calls are unavailable. */
    val callButton = FrameLayout(context).apply {
        id = R.id.chat_call_button
        contentDescription = context.getString(R.string.call_open)
        isClickable = true
        isFocusable = true
        visibility = GONE
        background = InsetDrawable(callCircle, dp((TOUCH_TARGET_DP - BUTTON_DP) / 2))
        addView(callIcon, LayoutParams(dp(ICON_DP), dp(ICON_DP), Gravity.CENTER))
    }

    /**
     * Comma's mark: the black logo on a white circle, the brand's own colours in both themes. The
     * hairline keeps the circle from melting into the white page.
     */
    val avatar = ImageView(context).apply {
        setImageDrawable(ContextCompat.getDrawable(context, R.drawable.ic_cue_mark)?.mutate()?.apply {
            setTint(context.getColor(R.color.token_mark_fg))
        })
        scaleType = ImageView.ScaleType.FIT_CENTER
        val inset = if (compact) dp((COMPACT_AVATAR_DP - COMPACT_MARK_BOX_DP) / 2) else dp((AVATAR_DP - MARK_BOX_DP) / 2)
        setPadding(inset, inset, inset, inset)
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(context.getColor(R.color.token_mark_bg))
            setStroke(HAIRLINE_PX, stroke)
        }
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** One centred line under the mark that always says "Comma"; a tap opens the sidebar. */
    val capsule = TextView(context).apply {
        id = R.id.chat_status_capsule
        DesignTypography.applyTo(this, DesignTypography.Level.REGULAR, DesignFonts.semibold)
        gravity = Gravity.CENTER
        maxLines = 1
        includeFontPadding = false
        setPadding(dp(CAPSULE_PADDING_DP), 0, dp(CAPSULE_PADDING_DP), 0)
        text = context.getString(R.string.chat_brand_name)
        setTextColor(ColorUtils.setAlphaComponent(context.getColor(R.color.token_text_primary), CAPSULE_TEXT_ALPHA))
        background = GradientDrawable().apply {
            cornerRadius = dp(CAPSULE_DP) / 2f
            setColor(fill)
            setStroke(HAIRLINE_PX, stroke)
        }
        isClickable = true
        isFocusable = true
        if (compact) visibility = GONE
    }

    private var insetTop = 0

    init {
        setCall(available = false, live = false)
        clipChildren = false
        clipToPadding = false
        val avatarSize = dp(if (compact) COMPACT_AVATAR_DP else AVATAR_DP)
        val avatarTop = if (compact) dp(COMPACT_TOP_GAP_DP) + (dp(TOUCH_TARGET_DP) - avatarSize) / 2 else dp(TOP_GAP_DP)
        // The side buttons' circles are centred on the mark.
        val sideTop = avatarTop + (avatarSize - dp(TOUCH_TARGET_DP)) / 2
        addView(menuButton, LayoutParams(dp(TOUCH_TARGET_DP), dp(TOUCH_TARGET_DP), Gravity.TOP or Gravity.START).apply {
            marginStart = dp(SIDE_DP)
            topMargin = sideTop
        })
        addView(callButton, LayoutParams(dp(TOUCH_TARGET_DP), dp(TOUCH_TARGET_DP), Gravity.TOP or Gravity.END).apply {
            marginEnd = dp(SIDE_DP)
            topMargin = sideTop
        })
        addView(avatar, LayoutParams(avatarSize, avatarSize, Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply {
            topMargin = avatarTop
        })
        addView(capsule, LayoutParams(LayoutParams.WRAP_CONTENT, dp(CAPSULE_DP), Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply {
            topMargin = dp(TOP_GAP_DP) + dp(AVATAR_DP) - dp(CAPSULE_OVERLAP_DP)
        })
    }

    /**
     * The Call button shows while calls are [available] or one is [live] (a call in progress keeps
     * its way back even if availability drops). A live call fills it with the brand colour.
     */
    fun setCall(available: Boolean, live: Boolean) {
        callButton.visibility = if (available || live) VISIBLE else GONE
        if (live) {
            callCircle.setColor(context.getColor(R.color.token_bg_brand_solid))
            callCircle.setStroke(0, 0)
            callIcon.drawable?.setTint(android.graphics.Color.WHITE)
        } else {
            callCircle.setColor(fill)
            callCircle.setStroke(HAIRLINE_PX, stroke)
            callIcon.drawable?.setTint(context.getColor(R.color.token_fg_primary))
        }
    }

    /** The bar's top edge sits under the status bar, which the bar pads for. */
    fun setStatusBarInset(px: Int) {
        if (px == insetTop) return
        insetTop = px
        setPadding(0, px, 0, 0)
    }

    /** A piece of the chrome that wants the content behind it frosted, in the bar's coordinates. */
    class FrostPatch(val key: String, val bounds: Rect, val radius: Float)

    /**
     * The frosted patches for the bar as it is laid out now: the capsule and the side circles. A
     * hidden Call button's patch has empty bounds, which takes it away.
     */
    fun frostPatches(): List<FrostPatch> {
        val inset = dp((TOUCH_TARGET_DP - BUTTON_DP) / 2)
        fun circle(view: android.view.View) =
            if (view.visibility != VISIBLE) Rect() else Rect(view.left + inset, view.top + inset, view.right - inset, view.bottom - inset)
        return listOf(
            FrostPatch("capsule", Rect(capsule.left, capsule.top, capsule.right, capsule.bottom), dp(CAPSULE_DP) / 2f),
            FrostPatch("menu", circle(menuButton), dp(BUTTON_DP) / 2f),
            FrostPatch("call", circle(callButton), dp(BUTTON_DP) / 2f),
        )
    }

    /** Where the frosted band has thinned out: a little below the bar, so it has no edge. */
    val frostBottom: Int get() = heightFor(insetTop) + dp(FROST_TAIL_DP)

    /** How far down the frosted band stays at full strength before it starts to thin out. */
    val frostSolid: Int get() = (heightFor(insetTop) - dp(FROST_LEAD_DP)).coerceAtLeast(insetTop)

    /** The bar's height under a status bar of [statusBarPx]; it does not depend on what it shows. */
    fun heightFor(statusBarPx: Int): Int = if (compact) statusBarPx + dp(COMPACT_TOP_GAP_DP) + dp(TOUCH_TARGET_DP) + dp(COMPACT_TOP_GAP_DP)
        else statusBarPx + dp(TOP_GAP_DP) + dp(AVATAR_DP) - dp(CAPSULE_OVERLAP_DP) + dp(CAPSULE_DP) + dp(BOTTOM_GAP_DP)

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        super.onMeasure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(heightFor(paddingTop), MeasureSpec.EXACTLY))
    }

    private fun circle(inset: Int) = InsetDrawable(GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(fill)
        setStroke(HAIRLINE_PX, stroke)
    }, dp(inset))

    private fun dp(value: Int) = (value * density).roundToInt()

    companion object {
        const val TOUCH_TARGET_DP = 48
        /** The side buttons' visible circles inside their touch targets. */
        const val BUTTON_DP = 40
        const val ICON_DP = 24
        /** Comma's mark, the page's face. */
        const val AVATAR_DP = 60
        /**
         * The logo's box inside the mark. The logo fills 16 of its 20 units, so it spans 33.6 dp,
         * 56 % of the circle: the prod app icon's proportion, with room around it on a small circle.
         */
        const val MARK_BOX_DP = 42
        /** The router chat's mark, the size of the iOS navigation bar's (26 pt) on its circle. */
        const val COMPACT_AVATAR_DP = 32
        const val COMPACT_MARK_BOX_DP = 24
        /** Above and below the router chat's 48 dp row. */
        const val COMPACT_TOP_GAP_DP = 4
        /** One line of `regular` text and a hair of room; the ends are half circles. */
        const val CAPSULE_DP = 26
        const val CAPSULE_PADDING_DP = 14
        /** The capsule laps over the bottom of the mark by this much. */
        const val CAPSULE_OVERLAP_DP = 5
        /** From the status bar to the top of the mark. */
        const val TOP_GAP_DP = 12
        const val BOTTOM_GAP_DP = 12
        /** Page gutter less the touch target's slack, so the circles sit 16 dp from the edges. */
        const val SIDE_DP = 12
        /** The frosted band starts to thin out this far above the bar's bottom edge... */
        const val FROST_LEAD_DP = 68
        /** ...and is gone this far below it, half strength falling just above the edge. */
        const val FROST_TAIL_DP = 28
        /** The capsule's line, a touch lighter than primary text (of 255). */
        const val CAPSULE_TEXT_ALPHA = 0xE6
        /** The design's 0.5 dp line, drawn as one physical pixel (DESIGN.md §4). */
        const val HAIRLINE_PX = 1
        /** The chrome's fill over its frosted backdrop: the page colour at 60 %. */
        const val CHROME_FILL_ALPHA = 0x99
    }
}
