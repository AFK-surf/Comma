package surf.comma.android.ui.kit

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View
import android.view.animation.LinearInterpolator
import android.widget.ProgressBar
import androidx.annotation.ColorInt
import surf.comma.android.R

/**
 * The loading indicator the iOS app shows: eight rounded spokes, the leading one solid and the ones behind it fading,
 * the bright spoke stepping clockwise once around per second. It is drawn to fit its box (20dp matches the iOS
 * default size). The spokes never redraw while it turns: only the view's rotation steps by one spoke, a render-node
 * property, so a turning indicator costs no re-recording. With system animations off it stands still. Screen readers
 * read it as a progress bar that is loading.
 */
class ActivityIndicator(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        color = context.getColor(R.color.token_fg_quaternary)
    }
    private var spinner: ValueAnimator? = null
    private var aggregatedVisible = false

    /** The spokes' colour; the fade is applied over it. */
    @get:ColorInt
    var color: Int
        get() = paint.color
        set(value) {
            paint.color = value
            invalidate()
        }

    /** True while the indicator is turning; exposed for tests. */
    val isSpinning: Boolean get() = spinner != null

    init {
        // Read as a progress bar that is loading. A caller whose control already says so hides it from screen readers.
        contentDescription = context.getString(R.string.activity_indicator_loading)
    }

    override fun getAccessibilityClassName(): CharSequence = ProgressBar::class.java.name

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val size = context.dp(DEFAULT_DP)
        setMeasuredDimension(resolveSize(size + paddingLeft + paddingRight, widthMeasureSpec),
            resolveSize(size + paddingTop + paddingBottom, heightMeasureSpec))
    }

    override fun onDraw(canvas: Canvas) {
        val size = minOf(width - paddingLeft - paddingRight, height - paddingTop - paddingBottom).toFloat()
        if (size <= 0f) return
        val cx = paddingLeft + (width - paddingLeft - paddingRight) / 2f
        val cy = paddingTop + (height - paddingTop - paddingBottom) / 2f
        val stroke = size * STROKE_FRACTION
        paint.strokeWidth = stroke
        val inner = size * INNER_FRACTION + stroke / 2f
        val outer = size / 2f - stroke / 2f
        val base = paint.alpha
        // Spoke 0 points up and is the leading one; the trail runs anticlockwise behind it.
        for (i in 0 until SPOKES) {
            paint.alpha = (base * (1f - i * FADE_STEP)).toInt()
            canvas.save()
            canvas.rotate(-i * 360f / SPOKES, cx, cy)
            canvas.drawLine(cx, cy - inner, cx, cy - outer, paint)
            canvas.restore()
        }
        paint.alpha = base
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        updateSpin()
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        updateSpin()
    }

    override fun onVisibilityAggregated(isVisible: Boolean) {
        super.onVisibilityAggregated(isVisible)
        aggregatedVisible = isVisible
        updateSpin()
    }

    private fun updateSpin() {
        val shouldSpin = isAttachedToWindow && aggregatedVisible && ValueAnimator.areAnimatorsEnabled()
        if (shouldSpin == (spinner != null)) return
        if (shouldSpin) {
            // A continuous loading indicator turns at a constant rate, the documented exception to springs for
            // rotation; it steps one spoke at a time as iOS does. Resume from the spoke it stopped on.
            val start = (rotation / STEP_DEGREES).toInt()
            spinner = ValueAnimator.ofFloat(0f, SPOKES.toFloat()).apply {
                duration = PERIOD_MS
                interpolator = LinearInterpolator()
                repeatCount = ValueAnimator.INFINITE
                addUpdateListener {
                    val step = (start + (it.animatedValue as Float).toInt()) % SPOKES
                    val degrees = step * STEP_DEGREES
                    if (rotation != degrees) rotation = degrees
                }
                start()
            }
        } else {
            spinner?.cancel()
            spinner = null
        }
    }

    private companion object {
        const val DEFAULT_DP = 20
        const val SPOKES = 8
        const val STEP_DEGREES = 360f / SPOKES
        const val PERIOD_MS = 1_000L
        const val STROKE_FRACTION = 0.11f
        const val INNER_FRACTION = 0.19f
        const val FADE_STEP = 0.1f
    }
}
