package surf.comma.android.ui.composer

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View
import android.view.animation.AnimationUtils
import kotlin.math.exp
import kotlin.math.max

/**
 * Voice bars. Each frame eases toward the latest spectrum: quick to rise (τ 70 ms), slow to fall
 * (τ 220 ms), so speech reads as a pulse rather than flicker. Heights run from a dot to the full
 * view height. Only runs while [start]ed and attached; otherwise it draws a still row of dots.
 */
internal class VoiceWaveView(context: Context, private val style: ComposerStyle) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var targets = FloatArray(0)
    private var shown = FloatArray(0)
    private var lastFrameMs = 0L
    private var running = false
    private val barWidth = style.dp(2.5f)
    private val maxGap = style.dp(4f)

    var color: Int = style.fgPrimary
        set(value) {
            field = value
            invalidate()
        }

    fun setBars(bars: FloatArray) {
        if (shown.size != bars.size) shown = FloatArray(bars.size)
        targets = bars
    }

    fun start() {
        running = true
        lastFrameMs = 0L
        shown.fill(0f)
        postInvalidateOnAnimation()
    }

    /** Back to a still row of dots. */
    fun stop() {
        running = false
        targets = FloatArray(targets.size)
        shown.fill(0f)
        invalidate()
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        running = false
    }

    override fun onDraw(canvas: Canvas) {
        val count = if (shown.isNotEmpty()) shown.size else IDLE_BARS
        if (running && shown.isNotEmpty()) {
            val now = AnimationUtils.currentAnimationTimeMillis()
            val dt = if (lastFrameMs == 0L) 0.016f else ((now - lastFrameMs) / 1000f).coerceIn(0.001f, 0.05f)
            lastFrameMs = now
            for (i in shown.indices) {
                val target = targets.getOrElse(i) { 0f }
                val tau = if (target > shown[i]) TAU_ATTACK else TAU_RELEASE
                shown[i] += (target - shown[i]) * (1f - exp(-dt / tau))
            }
        }
        val gap = ((width - count * barWidth) / (count - 1)).coerceIn(barWidth * 0.6f, maxGap)
        val total = count * barWidth + (count - 1) * gap
        var x = (width - total) / 2f
        val cy = height / 2f
        val maxH = height.toFloat()
        paint.color = color
        for (i in 0 until count) {
            val v = shown.getOrElse(i) { 0f }
            val h = max(barWidth, v * maxH)
            canvas.drawRoundRect(x, cy - h / 2f, x + barWidth, cy + h / 2f, barWidth / 2f, barWidth / 2f, paint)
            x += barWidth + gap
        }
        if (running) postInvalidateOnAnimation()
    }

    private companion object {
        const val IDLE_BARS = 32
        const val TAU_ATTACK = 0.07f
        const val TAU_RELEASE = 0.22f
    }
}
