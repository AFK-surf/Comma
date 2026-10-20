package surf.comma.android.chat.live

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.ImageView
import surf.comma.android.R
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.ui.composer.ButtonScale
import surf.comma.android.ui.theme.DesignMotion

/**
 * The round "back to the latest message" button that floats centred above the composer.
 *
 * It is an overlay: it never takes space from the list. It shows once the reader has scrolled
 * more than a screen up from where the list was following and hides when they are back at the end (see [scrollToLatestVisible]), so it
 * is never over the last message of a list resting at the bottom. Showing and hiding scale on
 * [DesignMotion.springScale] and fade on the duration tokens; both go straight to the end when
 * the system removes animations.
 */
internal class ScrollToLatestButton(context: Context) : FrameLayout(context) {
    private val density = resources.displayMetrics.density
    // Nullable: the platform constructor may touch pressed state before this class initialises.
    private var scale: ButtonScale? = null
    private val circle = ImageView(context).apply {
        setImageResource(R.drawable.ic_chat_arrow_down)
        imageTintList = ColorStateList.valueOf(context.getColor(R.color.token_fg_primary))
        scaleType = ImageView.ScaleType.CENTER_INSIDE
        val inset = dp(CIRCLE_DP - ICON_DP) / 2
        setPadding(inset, inset, inset, inset)
        // An opaque surface with a hairline reads over bubbles and images in both themes.
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(context.getColor(R.color.token_bg_primary))
            setStroke(1, context.getColor(R.color.token_border_primary))
        }
    }

    /** Whether the button is (or is becoming) shown. */
    var shown = false
        private set

    init {
        addView(circle, LayoutParams(dp(CIRCLE_DP), dp(CIRCLE_DP), Gravity.CENTER))
        minimumWidth = dp(TOUCH_TARGET_DP)
        minimumHeight = dp(TOUCH_TARGET_DP)
        contentDescription = context.getString(R.string.chat_scroll_to_latest)
        isFocusable = true
        isClickable = false
        alpha = 0f
        visibility = GONE
        scale = ButtonScale(this, action = true).apply { setShown(false, animated = false) }
    }

    fun setShown(value: Boolean) {
        if (shown == value) return
        shown = value
        isClickable = value
        animate().cancel()
        if (value) {
            visibility = VISIBLE
            animate().alpha(1f).setDuration(DesignMotion.durationMillis(DesignMotion.feedbackIn))
                .setInterpolator(DesignMotion.smoothOut)
        } else {
            animate().alpha(0f).setDuration(DesignMotion.durationMillis(DesignMotion.feedbackOut))
                .setInterpolator(DesignMotion.softInOut).withEndAction { if (!shown) visibility = GONE }
        }
        scale?.setShown(value, animated = true)
    }

    /**
     * Takes over [timeline]'s overflow and follow-mode callbacks; [onBottomOverflow] still gets
     * every overflow change. A tap goes back to the end through the list's own smooth scroll
     * (see [ChatTimelineView.jumpToLatest]) and resumes following there, so a reply that is
     * still streaming is followed as it grows.
     */
    fun bindTo(timeline: ChatTimelineView, onBottomOverflow: (Int) -> Unit = {}) {
        // Measured from where following stopped, in exact scroll steps: the overflow below the
        // list stops counting once the last row is off screen, and a tall reply can rest with
        // more than a screen of itself below.
        var scrolledUp = 0
        fun update() {
            val viewport = timeline.height - timeline.paddingTop - timeline.paddingBottom
            setShown(scrollToLatestVisible(shown, scrolledUp, timeline.bottomOverflowPx(), viewport,
                readingHistory = !timeline.isPinnedToEnd()))
        }
        timeline.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                if (timeline.isPinnedToEnd()) return
                scrolledUp = (scrolledUp - dy).coerceAtLeast(0)
                update()
            }
        })
        timeline.onBottomOverflowChanged = { overflow ->
            onBottomOverflow(overflow)
            update()
        }
        timeline.onReadingHistoryChanged = { reading ->
            if (reading) scrolledUp = 0
            update()
        }
        setOnClickListener {
            setShown(false)
            timeline.jumpToLatest()
        }
    }

    override fun setPressed(pressed: Boolean) {
        val changed = pressed != isPressed
        super.setPressed(pressed)
        if (changed) scale?.setPressed(pressed)
    }

    private fun dp(value: Int) = (value * density).toInt()

    companion object {
        const val CIRCLE_DP = 40
        const val ICON_DP = 20
        const val TOUCH_TARGET_DP = 48
    }
}

/**
 * Shown once the reader has gone more than a screen ([viewportPx]) up ([scrolledUpPx]) from where
 * the list was following, hidden once back at the end (no [overflowPx] left below the list's
 * resting bottom line, or following again); in between it keeps its [current] state, so it
 * does not flicker around the threshold.
 */
internal fun scrollToLatestVisible(
    current: Boolean,
    scrolledUpPx: Int,
    overflowPx: Int,
    viewportPx: Int,
    readingHistory: Boolean,
): Boolean = when {
    !readingHistory || overflowPx <= 0 -> false
    scrolledUpPx > viewportPx -> true
    else -> current
}
