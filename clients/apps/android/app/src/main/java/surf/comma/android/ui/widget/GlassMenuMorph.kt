package surf.comma.android.ui.widget

import android.graphics.Outline
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.RenderEffect
import android.graphics.Shader
import android.view.View
import android.view.ViewOutlineProvider
import androidx.dynamicanimation.animation.FloatPropertyCompat
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import kotlin.math.min
import kotlin.math.roundToInt

/** The menu's shape on its way between [start] and [end], with each axis at its own point of the way. */
internal fun glassMorphRect(start: RectF, end: RectF, wide: Float, tall: Float, out: RectF) {
    out.set(
        start.left + (end.left - start.left) * wide,
        start.top + (end.top - start.top) * tall,
        start.right + (end.right - start.right) * wide,
        start.bottom + (end.bottom - start.bottom) * tall,
    )
}

/**
 * A glass control turning into its menu, on the path measured frame by frame from iOS, without its bounce: a macOS menu has none
 * and members found one too lively. Opening, a drop grows out of the control nearly as wide as it was and spreads into the card,
 * staying round until the end, while the rows sharpen from larger than the shape that clips them. Closing, the drop narrows a
 * little past the control's own width and is drawn back up into the control, which the glass melts it into. The card [list] keeps
 * its final layout: this moves the clip on [rows] and the glass, in the card's own coordinates. The glass draws the shadow from
 * the same shape in the same frame: an elevation shadow lags it and steps.
 */
internal class GlassMenuMorph(
    private val list: View,
    private val rows: View,
    private val anchor: View,
    private val backdrop: GlassBackdrop,
    private val start: RectF,
    private val end: RectF,
    private val radius: Float,
) : ViewOutlineProvider() {
    private val density = list.resources.displayMetrics.density
    private val shown = anchor.alpha
    private val capsule = GlassShape(Rect(), min(start.width(), start.height()) / 2f)
    private val shape = RectF()
    private var wide = 0f
    private var tall = 0f
    private var corner = 0f
    private var closed: (() -> Unit)? = null
    private val openWide = DesignSpring(this, WIDE, OPEN_WIDE, THRESHOLD)
    private val openTall = DesignSpring(this, TALL, OPEN_TALL, THRESHOLD)
    private val closeWide = DesignSpring(this, WIDE, CLOSE_WIDE, THRESHOLD)
    private val closeTall = DesignSpring(this, TALL, CLOSE_TALL, THRESHOLD)
    private val spread = Runnable { openWide.animateTo(1f) }
    private val draw = Runnable { closeTall.animateTo(0f) }

    init {
        start.roundOut(capsule.bounds)
    }

    /** Waits out the frame that first draws the glass, the slowest of all: a spring runs on the clock, and would jump it. */
    fun open() {
        anchor.alpha = 0f
        update()
        list.viewTreeObserver.registerFrameCommitCallback {
            if (closed == null) {
                openTall.animateTo(1f)
                list.postDelayed(spread, SPREAD_DELAY_MS)
            }
        }
    }

    /** Back into the control, from wherever the shape has got to. */
    fun close(done: () -> Unit) {
        closed = done
        list.removeCallbacks(spread)
        openWide.cancel()
        openTall.cancel()
        closeWide.animateTo(NARROW)
        list.postDelayed(draw, DRAW_DELAY_MS)
    }

    /** The clip on the rows, which are themselves scaled: it is drawn back to the shape's size. */
    override fun getOutline(view: View, outline: Outline) {
        val scale = rows.scaleX
        val x = view.width / 2f
        val y = view.height / 2f
        outline.setRoundRect(
            (x + (shape.left - x) / scale).roundToInt(),
            (y + (shape.top - y) / scale).roundToInt(),
            (x + (shape.right - x) / scale).roundToInt(),
            (y + (shape.bottom - y) / scale).roundToInt(),
            corner / scale,
        )
    }

    private fun update() {
        glassMorphRect(start, end, wide, tall, shape)
        val away = wide.coerceIn(0f, 1f)
        val closing = closed != null
        val round = min(shape.width(), shape.height()) / 2f
        corner = min(round + (radius - round) * away * away * away, round)
        backdrop.setShadow(GlassBackdrop.REST_SHADOW + (GlassBackdrop.CARD_SHADOW - GlassBackdrop.REST_SHADOW) * tall.coerceIn(0f, 1f))
        backdrop.setShape(shape, corner, capsule.takeIf { closing }, BLEND_DP * density)
        val rise = if (closing) (away - ROWS_GONE) / (1f - ROWS_GONE) else (away - ROWS_FROM) / (1f - ROWS_FROM)
        rows.alpha = rise.coerceIn(0f, 1f)
        // Past 1 the width overshoots, and the rows ride the bounce with it.
        rows.scaleX = (1f + ROWS_GROWTH * (1f - wide)).coerceAtLeast(0.5f)
        rows.scaleY = rows.scaleX
        rows.invalidateOutline()
        val left = BLUR_DP * density * (1f - away)
        rows.setRenderEffect(if (left >= 1f) RenderEffect.createBlurEffect(left, left, Shader.TileMode.DECAL) else null)
        if (closing) {
            val back = (1f - tall / HANDOVER).coerceIn(0f, 1f)
            list.alpha = 1f - back
            anchor.alpha = shown * back
            if (tall <= THRESHOLD) finish()
        }
    }

    private fun finish() {
        val done = closed ?: return
        closed = NOTHING
        anchor.alpha = shown
        done()
    }

    private companion object {
        val NOTHING = {}
        const val THRESHOLD = 0.002f
        const val BLUR_DP = 8f
        const val BLEND_DP = 14f
        const val ROWS_FROM = 0.2f
        const val ROWS_GONE = 0.7f
        const val ROWS_GROWTH = 0.6f
        const val SPREAD_DELAY_MS = 16L
        const val DRAW_DELAY_MS = 20L

        /** How far past the control's own width the drop narrows as it closes. */
        const val NARROW = -0.12f

        /** How much of the height is left when the control takes over from the glass. */
        const val HANDOVER = 0.12f
        val OPEN_TALL = DesignMotion.SpringToken(1600f, 0.92f)
        val OPEN_WIDE = DesignMotion.SpringToken(1200f, 0.95f)
        val CLOSE_WIDE = DesignMotion.SpringToken(1500f, 1f)
        val CLOSE_TALL = DesignMotion.SpringToken(1100f, 1f)
        val WIDE = object : FloatPropertyCompat<GlassMenuMorph>("glassMenuWide") {
            override fun getValue(morph: GlassMenuMorph) = morph.wide
            override fun setValue(morph: GlassMenuMorph, value: Float) {
                morph.wide = value
                morph.update()
            }
        }
        val TALL = object : FloatPropertyCompat<GlassMenuMorph>("glassMenuTall") {
            override fun getValue(morph: GlassMenuMorph) = morph.tall
            override fun setValue(morph: GlassMenuMorph, value: Float) {
                morph.tall = value
                morph.update()
            }
        }
    }
}
