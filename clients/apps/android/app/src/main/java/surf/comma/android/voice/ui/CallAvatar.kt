package surf.comma.android.voice.ui

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View
import androidx.core.content.ContextCompat
import androidx.core.graphics.ColorUtils
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignMotion
import kotlin.math.roundToInt

/**
 * Comma's half-size mark on a neutral [AVATAR_DP] circle inside [BOX_DP], and the ring
 * that breathes around it while Comma speaks. The ring only changes opacity; the call surface
 * scales the whole view as it folds into its card.
 */
internal class CallAvatar(context: Context, private val ringColor: Int) : View(context) {
    private val density = resources.displayMetrics.density
    private val mark = ContextCompat.getDrawable(context, R.drawable.ic_cue_mark)!!.mutate().apply {
        setTint(context.getColor(R.color.token_text_primary))
    }
    private val surface = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = context.getColor(R.color.token_bg_tertiary) }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = RING_STROKE_DP * density
    }
    private var ringAlpha = 0f
    private var breathing: ValueAnimator? = null

    var speaking = false
        set(value) {
            if (field == value) return
            field = value
            breathing?.cancel()
            breathing = if (value && ValueAnimator.areAnimatorsEnabled()) {
                ValueAnimator.ofFloat(ringAlpha, 1f, RING_LOW).apply {
                    duration = BREATH_MS
                    interpolator = DesignMotion.softInOut
                    repeatCount = ValueAnimator.INFINITE
                    repeatMode = ValueAnimator.REVERSE
                    addUpdateListener { setRing(it.animatedValue as Float) }
                    start()
                }
            } else if (value) {
                setRing(1f)
                null
            } else {
                ValueAnimator.ofFloat(ringAlpha, 0f).apply {
                    duration = DesignMotion.durationMillis(DesignMotion.feedbackOut)
                    interpolator = DesignMotion.softInOut
                    addUpdateListener { setRing(it.animatedValue as Float) }
                    start()
                }
            }
        }

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    private fun setRing(value: Float) {
        ringAlpha = value
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        canvas.drawCircle(cx, cy, AVATAR_DP * density / 2f, surface)
        // The iOS call avatar puts a half-size mark on its neutral circle.
        val box = AVATAR_DP * density / 2f * 20f / 16f
        mark.setBounds((cx - box / 2).roundToInt(), (cy - box / 2).roundToInt(), (cx + box / 2).roundToInt(), (cy + box / 2).roundToInt())
        mark.draw(canvas)
        if (ringAlpha > 0f) {
            ring.color = ColorUtils.setAlphaComponent(ringColor, (255 * ringAlpha.coerceIn(0f, 1f)).roundToInt())
            canvas.drawCircle(cx, cy, (AVATAR_DP / 2f + RING_GAP_DP + RING_STROKE_DP / 2f) * density, ring)
        }
    }

    override fun onDetachedFromWindow() {
        breathing?.cancel()
        super.onDetachedFromWindow()
    }

    companion object {
        const val AVATAR_DP = 112
        /** Room for the logo and the ring around it. */
        const val BOX_DP = 168
        const val RING_GAP_DP = 6f
        const val RING_STROKE_DP = 3f
        const val RING_LOW = 0.3f
        const val BREATH_MS = 700L
    }
}
