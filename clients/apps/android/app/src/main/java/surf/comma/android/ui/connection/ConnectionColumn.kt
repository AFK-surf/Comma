package surf.comma.android.ui.connection

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.isInvisible
import androidx.core.view.isVisible
import surf.comma.android.R
import surf.comma.android.scroll.widget.ScrollContainer
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography
import kotlin.math.roundToInt

/**
 * The column the connecting page and the connection error page share: the mark, a title, then
 * whatever the page adds.
 *
 * The mark starts a fixed fraction of the way down the page instead of the column being
 * centred. Both pages then draw the mark and the title in the same place whatever follows
 * them, and the content as a whole sits a little above the middle. A page too short for that
 * moves the mark up, and scrolls once there is no room left.
 */
@SuppressLint("ViewConstructor")
internal class ConnectionColumn(context: Context) : LinearLayout(context) {
    private val lead = Lead(context)
    val mark = ImageView(context).apply {
        setImageResource(R.drawable.ic_cue_mark)
        imageTintList = ColorStateList.valueOf(context.getColor(R.color.token_fg_primary))
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    /** Sits on the mark's upper corner, clear of the ring in its lower one; hidden until a page gives it an icon. */
    val badge = ImageView(context).apply {
        background = circle(R.color.token_bg_quaternary)
        imageTintList = ColorStateList.valueOf(context.getColor(R.color.token_text_tertiary))
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        setPadding(dp(5), dp(5), dp(5), dp(5))
    }
    private val badgeRing = FrameLayout(context).apply {
        background = circle(R.color.token_bg_primary)
        setPadding(dp(2), dp(2), dp(2), dp(2))
        visibility = INVISIBLE
        addView(badge, FrameLayout.LayoutParams(-1, -1))
        // Hangs off the mark's corner without changing where the mark is laid out.
        translationY = -dp(BADGE_OVERHANG).toFloat()
    }
    val title = TextView(context).apply {
        gravity = Gravity.CENTER_HORIZONTAL
        setTextColor(context.getColor(R.color.token_text_primary))
        DesignTypography.applyTo(this, DesignTypography.Level.TITLE2, DesignFonts.medium)
        isAccessibilityHeading = true
    }

    var badgeVisible: Boolean
        get() = badgeRing.isVisible
        set(value) { badgeRing.isInvisible = !value }

    init {
        orientation = VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        clipChildren = false
        clipToPadding = false
        setPadding(dp(24), 0, dp(24), dp(16))
        addView(lead, LayoutParams(0, 0))
        addView(FrameLayout(context).apply {
            clipChildren = false
            addView(mark, FrameLayout.LayoutParams(-1, -1))
            addView(badgeRing, FrameLayout.LayoutParams(dp(28), dp(28), Gravity.TOP or Gravity.END))
        }, LayoutParams(dp(MARK_SIZE), dp(MARK_SIZE)))
        addView(title, row(24))
    }

    fun row(top: Int) = LayoutParams(-1, -2).apply { topMargin = dp(top) }

    /** Takes the space that is left, so what follows sits at the bottom of the page. */
    fun addSpace() = addView(View(context), LayoutParams(0, 0, 1f))

    /** Scrolls when the column is taller than the page, and centres it when the page is wider. */
    fun scrolling() = ScrollContainer(context).apply {
        isFillViewport = true
        isVerticalScrollBarEnabled = false
        clipChildren = false
        addView(FrameLayout(context).apply {
            clipChildren = false
            addView(this@ConnectionColumn, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER_HORIZONTAL))
        }, FrameLayout.LayoutParams(-1, -2))
    }

    override fun onRtlPropertiesChanged(layoutDirection: Int) {
        super.onRtlPropertiesChanged(layoutDirection)
        val outward = if (layoutDirection == LAYOUT_DIRECTION_RTL) -1 else 1
        badgeRing.translationX = outward * dp(BADGE_OVERHANG).toFloat()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.makeMeasureSpec(minOf(MeasureSpec.getSize(widthMeasureSpec), dp(MAX_WIDTH)), MeasureSpec.EXACTLY)
        lead.size = dp(MIN_TOP)
        if (MeasureSpec.getMode(heightMeasureSpec) != MeasureSpec.EXACTLY) {
            super.onMeasure(width, heightMeasureSpec)
            return
        }
        // Measure once for the height the content needs, then place the mark.
        super.onMeasure(width, MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
        val page = MeasureSpec.getSize(heightMeasureSpec)
        val spare = (page - measuredHeight).coerceAtLeast(0)
        lead.size = (page * MARK_TOP_FRACTION).roundToInt().coerceIn(dp(MIN_TOP), dp(MIN_TOP) + spare)
        super.onMeasure(width, heightMeasureSpec)
    }

    private fun circle(color: Int) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(context.getColor(color))
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    /** Empty space above the mark; its height is set while the column is measured. */
    private class Lead(context: Context) : View(context) {
        var size = 0
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) = setMeasuredDimension(0, size)
    }

    companion object {
        /** Where the mark's top edge sits, as a fraction of the page height. */
        const val MARK_TOP_FRACTION = 0.28f
        private const val MIN_TOP = 40
        private const val MARK_SIZE = 48
        private const val BADGE_OVERHANG = 8
        private const val MAX_WIDTH = 360
    }
}
