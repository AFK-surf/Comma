package surf.comma.android.ui.composer

import android.content.Context
import android.graphics.Outline
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
 * The rounded input surface: a white card raised off the page by a soft elevation shadow (drawn
 * by the render thread from the outline, so moving or typing never redraws it) and a faint edge.
 * Its height Its height follows its content through [DesignMotion.springSize],
 * so a new line of text or the thumbnail row eases in instead of jumping.
 *
 * Children are bottom-anchored: while the spring catches up, the top of the content is what
 * gets revealed or clipped, and the buttons on the bottom row never move.
 */
internal class ComposerPill(context: Context, private val style: ComposerStyle) : LinearLayout(context) {

    private val fill = GradientDrawable().apply {
        setColor(style.composerBg)
        setStroke(style.dp(BORDER_DP).roundToInt().coerceAtLeast(1), style.composerBorder)
        cornerRadius = style.dp(CORNER_DP.toFloat())
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

    init {
        orientation = VERTICAL
        gravity = Gravity.BOTTOM
        background = fill
        clipToOutline = true
        // The outline is the only clip: a field travelling between rows leaves its row's bounds.
        clipChildren = false
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setRoundRect(0, 0, view.width, view.height, style.dp(CORNER_DP.toFloat()))
            }
        }
        elevation = style.dp(ELEVATION_DP.toFloat())
        outlineAmbientShadowColor = style.composerShadowAmbient
        outlineSpotShadowColor = style.composerShadowSpot
    }

    /** Surface colour; hold-to-talk tints it while the finger is in the cancel zone. */
    fun setFillColor(color: Int) {
        fill.setColor(color)
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
        /** DESIGN radius 4xl; with the 48dp resting height this makes a full pill. */
        const val CORNER_DP = 24
        /** Low enough that the shadow stays a soft halo rather than a floating panel. */
        const val ELEVATION_DP = 6
        /** The edge: two physical pixels at 3x, where a one-pixel line vanishes on the dark page. */
        const val BORDER_DP = 2f / 3f
    }
}
