package surf.comma.android.tasks.ui

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.view.View
import android.view.animation.AnimationUtils
import android.view.animation.LinearInterpolator
import androidx.annotation.DrawableRes
import androidx.core.content.ContextCompat
import androidx.core.graphics.withTranslation
import surf.comma.android.tasks.TaskStatusBucket

/** One full turn of the in-progress glyph. */
internal const val SPIN_PERIOD_MS = 2_000L

/**
 * Status glyph. The in-progress glyph turns, but only while the view can actually be seen:
 * attached, visible up the tree, in a visible window, and with system animations on.
 * The turn is a View rotation, a render-node property, so it never re-records the parent's
 * display list; a list row with a spinning glyph costs no more per frame than a static one.
 */
class TaskStatusIconView(context: Context) : View(context) {
    private var icon: Drawable? = null
    private var spinner: ValueAnimator? = null
    private var aggregatedVisible = false
    private var spinAllowed = true

    /** Null before the first [setStatus], and while the task's status is not known. */
    var bucket: TaskStatusBucket? = null
        private set
    @DrawableRes private var iconRes = 0

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** [spin] false keeps an in-progress glyph still, e.g. on a section header. [bucket] null draws the neutral glyph. */
    fun setStatus(bucket: TaskStatusBucket?, tint: Int, spin: Boolean = true) {
        spinAllowed = spin
        this.bucket = bucket
        val res = statusIconRes(bucket)
        if (iconRes != res) {
            iconRes = res
            icon = ContextCompat.getDrawable(context, res)?.mutate()
        }
        if (bucket != TaskStatusBucket.IN_PROGRESS || !spin) rotation = 0f
        icon?.setTint(tint)
        updateSpin()
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val drawable = icon ?: return
        drawable.setBounds(paddingLeft, paddingTop, width - paddingRight, height - paddingBottom)
        drawable.draw(canvas)
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

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        updateSpin()
    }

    /** True while the glyph is turning; exposed for tests and the demo's frame checks. */
    val isSpinning: Boolean get() = spinner != null

    private fun updateSpin() {
        val shouldSpin = spinAllowed &&
            bucket == TaskStatusBucket.IN_PROGRESS &&
            isAttachedToWindow &&
            aggregatedVisible &&
            windowVisibility == VISIBLE &&
            ValueAnimator.areAnimatorsEnabled()
        if (shouldSpin == (spinner != null)) return
        if (shouldSpin) {
            // A continuous loading indicator turns at a constant rate; it is the documented
            // exception to springs for rotation. Resume from where the glyph stopped.
            val start = rotation % 360f
            spinner = ValueAnimator.ofFloat(start, start + 360f).apply {
                duration = SPIN_PERIOD_MS
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
}

/**
 * The same glyph for surfaces that draw everything on one canvas (a chat message cell).
 * The host decides when to request frames; [draw] only reads the clock.
 */
class TaskStatusGlyphs(private val context: Context) {
    private val icons = HashMap<Int, Drawable>()

    /** [bucket] null draws the neutral glyph, still. */
    fun draw(canvas: Canvas, bucket: TaskStatusBucket?, tint: Int, left: Float, top: Float, size: Int, spin: Boolean) {
        val res = statusIconRes(bucket)
        val drawable = icons.getOrPut(res) {
            requireNotNull(ContextCompat.getDrawable(context, res)).mutate()
        }
        drawable.setTint(tint)
        drawable.setBounds(0, 0, size, size)
        canvas.withTranslation(left, top) {
            if (spin && bucket == TaskStatusBucket.IN_PROGRESS) {
                val turn = (AnimationUtils.currentAnimationTimeMillis() % SPIN_PERIOD_MS) / SPIN_PERIOD_MS.toFloat()
                rotate(turn * 360f, size / 2f, size / 2f)
            }
            drawable.draw(this)
        }
    }
}
