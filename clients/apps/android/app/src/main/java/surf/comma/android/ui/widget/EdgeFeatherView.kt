package surf.comma.android.ui.widget

import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat
import androidx.core.graphics.ColorUtils
import surf.comma.android.R
import kotlin.math.roundToInt

/**
 * The timeline's bottom edge, dissolved instead of cut.
 *
 * A sibling laid over the list, not a shadow: what it paints is `canvas_grey`, the same
 * colour the window, the root and the RecyclerView itself are painted with in both themes.
 * Against a flat backdrop, "fade to the background colour" and "erase to transparent" are
 * the same pixels, so this costs one gradient rect instead of a per-frame `saveLayer`.
 *
 * It has to live outside the RecyclerView. the scroll module translates the whole canvas
 * by the rubber-band distance inside `RecyclerView.draw()`, so a mask drawn within the list
 * — a fading edge, or a `DST_OUT` pass in `onDrawForeground` — would ride the overscroll
 * instead of staying pinned to the composer.
 *
 * Geometry: the view is bottom-aligned in the timeline host and [setComposerGutter] sizes it
 * to the floating composer. The top [R.dimen.chat_edge_feather] of it is the ramp; everything
 * below is solid, which is what keeps half-clipped text from showing in the strip between the
 * composer card and the bottom of the screen.
 */
class EdgeFeatherView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : View(context, attrs, defStyleAttr) {

    private val paint = Paint()
    private val canvasColor = ContextCompat.getColor(context, R.color.token_bg_primary)

    /** Ramp length, and also the scroll distance the feather fades itself out over. */
    val featherPx: Int = resources.getDimensionPixelSize(R.dimen.chat_edge_feather)

    private var gutterPx = -1

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        paint.alpha = 0
    }

    /**
     * [px] is the height of the floating composer including its own bottom padding, i.e. the
     * distance from the bottom of the host to the top edge of the composer card. The ramp is
     * stacked on top of it, so full opacity lands exactly where the card starts occluding.
     */
    fun setComposerGutter(px: Int) {
        val gutter = px.coerceAtLeast(0)
        if (gutter == gutterPx) return
        gutterPx = gutter
        val params = layoutParams ?: return
        val target = featherOverlayHeight(gutter, featherPx)
        if (params.height != target) {
            params.height = target
            layoutParams = params
        }
    }

    /**
     * How much content is still below the timeline's resting bottom line. Android's own
     * fading edges do the same thing in `getBottomFadingEdgeStrength()`: an edge with nothing
     * beyond it is not an edge, so the feather has to be gone by the time the last reply comes
     * to rest above the composer, or it would wash out the line the user just read.
     */
    fun setBottomOverflow(px: Int) {
        val alpha = (featherStrengthFor(px, featherPx) * 255f).roundToInt()
        if (alpha == paint.alpha) return
        paint.alpha = alpha
        invalidate()
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        paint.shader = if (width <= 0 || height <= 0) null else buildRamp(height)
    }

    override fun onDraw(canvas: Canvas) {
        if (paint.alpha == 0 || paint.shader == null) return
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
    }

    /**
     * A straight linear ramp leaves a seam the eye can find: the exact row where the fade
     * starts reads as a line of its own. Sampling a smoothstep flattens the curve at both
     * ends, so neither the start nor the finish has an edge to see.
     */
    private fun buildRamp(height: Int): Shader {
        val ramp = (featherPx.toFloat() / height).coerceIn(0f, 1f)
        val colors = ArrayList<Int>(RAMP_STOPS + 2)
        val stops = ArrayList<Float>(RAMP_STOPS + 2)
        for (index in 0..RAMP_STOPS) {
            val fraction = index / RAMP_STOPS.toFloat()
            colors += ColorUtils.setAlphaComponent(
                canvasColor,
                (featherAlphaAt(fraction) * 255f).roundToInt(),
            )
            stops += fraction * ramp
        }
        if (ramp < 1f) {
            // Below the ramp the overlay is the canvas itself. Content that has already
            // dissolved must not reappear beneath the composer card.
            colors += canvasColor
            stops += 1f
        }
        return LinearGradient(
            0f,
            0f,
            0f,
            height.toFloat(),
            colors.toIntArray(),
            stops.toFloatArray(),
            Shader.TileMode.CLAMP,
        )
    }

    private companion object {
        const val RAMP_STOPS = 24
    }
}

/** Ramp on top of the composer gutter: the two stack, they do not overlap. */
internal fun featherOverlayHeight(gutterPx: Int, featherPx: Int): Int =
    gutterPx.coerceAtLeast(0) + featherPx.coerceAtLeast(0)

/** Opacity along the ramp, 0 where content is untouched and 1 where the composer takes over. */
internal fun featherAlphaAt(fraction: Float): Float {
    val t = fraction.coerceIn(0f, 1f)
    return t * t * (3f - 2f * t)
}

/** The feather's overall strength: full while there is a screenful below, none at the end. */
internal fun featherStrengthFor(overflowPx: Int, featherPx: Int): Float {
    if (featherPx <= 0) return 0f
    return (overflowPx.toFloat() / featherPx).coerceIn(0f, 1f)
}
