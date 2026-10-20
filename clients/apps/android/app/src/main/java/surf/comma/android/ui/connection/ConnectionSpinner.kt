package surf.comma.android.ui.connection

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View
import android.view.animation.LinearInterpolator

/**
 * An open ring that turns. The arc has a fixed length, so the ring looks the same at every
 * moment of the turn and when it is standing still: with system animations off, or before the
 * first frame. Only the view's rotation animates, which is a render-node property and never
 * re-records the page.
 */
internal class ConnectionSpinner(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private var spinner: ValueAnimator? = null
    private var aggregatedVisible = false

    var color: Int
        get() = paint.color
        set(value) {
            paint.color = value
            invalidate()
        }

    /** True while the ring is turning; exposed for tests. */
    val isSpinning: Boolean get() = spinner != null

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    override fun onDraw(canvas: Canvas) {
        val size = minOf(width - paddingLeft - paddingRight, height - paddingTop - paddingBottom).toFloat()
        if (size <= 0f) return
        val stroke = size * STROKE_FRACTION
        paint.strokeWidth = stroke
        val left = paddingLeft + (width - paddingLeft - paddingRight - size) / 2f + stroke / 2f
        val top = paddingTop + (height - paddingTop - paddingBottom - size) / 2f + stroke / 2f
        canvas.drawArc(left, top, left + size - stroke, top + size - stroke, START_DEGREES, SWEEP_DEGREES, false, paint)
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
            // A continuous loading indicator turns at a constant rate; it is the documented
            // exception to springs for rotation. Resume from where the ring stopped.
            val start = rotation % 360f
            spinner = ValueAnimator.ofFloat(start, start + 360f).apply {
                duration = PERIOD_MS
                interpolator = LinearInterpolator()
                repeatCount = ValueAnimator.INFINITE
                addUpdateListener { rotation = it.animatedValue as Float }
                start()
            }
        } else {
            spinner?.cancel()
            spinner = null
        }
    }

    private companion object {
        const val PERIOD_MS = 1_000L
        const val STROKE_FRACTION = 1f / 12f
        const val START_DEGREES = -90f
        const val SWEEP_DEGREES = 270f
    }
}
