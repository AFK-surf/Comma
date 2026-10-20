package surf.comma.android.media.viewer

import android.content.Context
import android.graphics.Canvas
import android.graphics.drawable.Animatable
import android.graphics.drawable.Drawable
import android.view.View
import androidx.dynamicanimation.animation.FloatPropertyCompat
import surf.comma.android.media.ImageDimensions
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring

/**
 * Draws one picture at a [ZoomState]. The state is relative to the fitted picture, so a sharper
 * decode can replace the drawable without the picture moving. Gestures are handled by
 * [ImageViewerLayout]; this view only draws and animates.
 */
class ZoomImageView(context: Context) : View(context) {
    var drawable: Drawable? = null
        private set
    /** The picture's proportions; fixed once known so resolution swaps never reshape it. */
    private var content: ImageDimensions? = null
    var state = ZoomState()
        private set

    /** Called when a zoom gesture or animation comes to rest. */
    var onSettled: ((ZoomState) -> Unit)? = null

    private var from = ZoomState()
    private var to = ZoomState()
    private var progress = 1f
    private val spring = DesignSpring(this, Progress, DesignMotion.springSpatial, minimumVisibleChange = 0.001f).also {
        it.animation.addEndListener { _, canceled, _, _ -> if (!canceled) onSettled?.invoke(state) }
    }

    val geometry: ZoomGeometry?
        get() {
            val size = content ?: return null
            if (width <= 0 || height <= 0) return null
            return ZoomGeometry(width.toFloat(), height.toFloat(), size.width.toFloat(), size.height.toFloat())
        }

    /** [known] fixes the proportions before the first decode arrives, if the caller has them. */
    fun setDrawable(value: Drawable?, known: ImageDimensions? = null) {
        (drawable as? Animatable)?.stop()
        drawable?.callback = null
        drawable = value
        value?.callback = this
        if (content == null) {
            content = known ?: value?.let {
                if (it.intrinsicWidth > 0 && it.intrinsicHeight > 0) ImageDimensions(it.intrinsicWidth, it.intrinsicHeight) else null
            }
        }
        invalidate()
    }

    fun reset() {
        spring.cancel()
        setDrawable(null)
        content = null
        state = ZoomState()
        progress = 1f
    }

    fun startAnimation(run: Boolean) {
        val animatable = drawable as? Animatable ?: return
        if (run) animatable.start() else animatable.stop()
    }

    /** Follow a gesture exactly, stopping any animation. */
    fun jumpTo(value: ZoomState) {
        spring.cancel()
        progress = 1f
        state = value
        invalidate()
    }

    /** Settle on [target] with the spatial spring; the path is not clamped, so it may overshoot. */
    fun animateTo(target: ZoomState) {
        if (target == state) {
            onSettled?.invoke(state)
            return
        }
        spring.cancel()
        from = state
        to = target
        progress = 0f
        spring.animateTo(1f)
        // With animations off the spring lands at once and reports no end.
        if (!spring.isRunning) onSettled?.invoke(state)
    }

    override fun verifyDrawable(who: Drawable): Boolean = who === drawable || super.verifyDrawable(who)

    override fun onDraw(canvas: Canvas) {
        val picture = drawable ?: return
        val geometry = geometry ?: return
        val width = geometry.displayedWidth(state)
        val height = geometry.displayedHeight(state)
        val left = this.width / 2f + state.offsetX - width / 2f
        val top = this.height / 2f + state.offsetY - height / 2f
        val intrinsicWidth = picture.intrinsicWidth.takeIf { it > 0 } ?: return
        val intrinsicHeight = picture.intrinsicHeight.takeIf { it > 0 } ?: return
        picture.setBounds(0, 0, intrinsicWidth, intrinsicHeight)
        val save = canvas.save()
        canvas.translate(left, top)
        canvas.scale(width / intrinsicWidth, height / intrinsicHeight)
        picture.draw(canvas)
        canvas.restoreToCount(save)
    }

    override fun onDetachedFromWindow() {
        spring.cancel()
        startAnimation(false)
        super.onDetachedFromWindow()
    }

    private object Progress : FloatPropertyCompat<ZoomImageView>("zoomProgress") {
        override fun getValue(view: ZoomImageView) = view.progress
        override fun setValue(view: ZoomImageView, value: Float) {
            view.progress = value
            view.state = view.from.lerp(view.to, value)
            view.invalidate()
        }
    }
}
