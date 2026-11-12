package surf.comma.android.ui.composer

import android.content.Context
import android.graphics.Outline
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.LinearLayout
import androidx.dynamicanimation.animation.FloatPropertyCompat
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import kotlin.math.roundToInt

/**
 * The rounded input surface: a card with a faint edge. [ComposerView] draws the soft shadow
 * outside this view so the expanded outline does not clip it.
 * Its height follows its content through [DesignMotion.springSize],
 * so a new line of text or the thumbnail row eases in instead of jumping.
 *
 * Children are bottom-anchored: while the spring catches up, the top of the content is what
 * gets revealed or clipped, and the buttons on the bottom row never move.
 */
internal class ComposerPill(context: Context, private val style: ComposerStyle) : LinearLayout(context) {

    private val fill = GradientDrawable().apply {
        setColor(style.composerSurface)
        setStroke(style.dp(BORDER_DP).roundToInt().coerceAtLeast(1), style.composerBorder)
        cornerRadius = style.dp(22f)
    }
    /** Height currently drawn, in px; the spring moves it toward the content's natural height. */
    private var shownHeight = 0f
    private val heightSpring = DesignSpring(
        this,
        object : FloatPropertyCompat<ComposerPill>("composerPillHeight") {
            override fun getValue(pill: ComposerPill) = pill.shownHeight
            override fun setValue(pill: ComposerPill, value: Float) {
                pill.shownHeight = value
                pill.requestLayout()
            }
        },
        DesignMotion.springSize,
    )
    private var naturalHeight = -1

    private var surfaceInset = style.dp(52)
    private var surfaceInsetRight = 0
    private var surfaceRadius = style.dp(22f)

    private var expandedSurface = false

    init {
        orientation = VERTICAL
        gravity = Gravity.BOTTOM
        background = InsetDrawable(fill, style.dp(52), 0, 0, 0)
        setPadding(0, 0, 0, 0)
        clipToOutline = false
        // The separate attachment button sits outside the field outline.
        clipChildren = false
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setRoundRect(surfaceInset, 0, view.width - surfaceInsetRight, view.height, surfaceRadius)
            }
        }
    }

    override fun onRtlPropertiesChanged(layoutDirection: Int) {
        super.onRtlPropertiesChanged(layoutDirection)
        if (background != null) setExpanded(expandedSurface)
    }

    fun setExpanded(expanded: Boolean) {
        expandedSurface = expanded
        val rtl = layoutDirection == LAYOUT_DIRECTION_RTL
        val inset = if (expanded || rtl) 0 else style.dp(52)
        val rightInset = if (!expanded && rtl) style.dp(52) else 0
        val radius = style.dp(if (expanded) 24f else 22f)
        if (inset == surfaceInset && rightInset == surfaceInsetRight && radius == surfaceRadius) return
        clipToOutline = expanded
        surfaceInset = inset
        surfaceInsetRight = rightInset
        surfaceRadius = radius
        fill.cornerRadius = radius
        background = InsetDrawable(fill, inset, 0, rightInset, 0)
        setPadding(0, 0, 0, 0)
        invalidateOutline()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        super.onMeasure(widthMeasureSpec, heightMeasureSpec)
        val measured = measuredHeight
        if (measured != naturalHeight) {
            val first = naturalHeight < 0
            naturalHeight = measured
            if (first || !isLaidOut) {
                heightSpring.cancel()
                shownHeight = measured.toFloat()
            } else {
                heightSpring.animateTo(measured.toFloat())
            }
        }
        setMeasuredDimension(measuredWidth, shownHeight.toInt().coerceAtLeast(0))
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        invalidateOutline()
    }

    companion object {
        /** The edge: two physical pixels at 3x, where a one-pixel line vanishes on the dark page. */
        const val BORDER_DP = 2f / 3f
    }
}
