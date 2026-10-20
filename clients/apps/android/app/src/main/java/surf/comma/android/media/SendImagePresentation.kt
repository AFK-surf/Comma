package surf.comma.android.media

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.*
import android.graphics.drawable.Animatable
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.view.animation.AnimationUtils
import androidx.appcompat.widget.AppCompatImageView
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignMotion

/**
 * One image surface shared by the flight and its row. The row takes the very same preview at
 * landing; readiness, rather than flight time, starts the in-row clarity transition. No bitmap
 * copy, decode, row snapshot or dimension change is needed to hand it over.
 */
internal class SendImagePresentation(private val placeholderColor: Int, private val radius: Float) : Drawable(), Drawable.Callback {
    internal var preview: Bitmap? = null
        private set
    internal var target: Drawable? = null
        private set
    internal var held = false
        private set
    private var fadeAt = -1L
    private var previewOffered = false
    private var bindingOpen = true
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val add = PorterDuffXfermode(PorterDuff.Mode.ADD)
    private val clip = Path()
    private val aperture = RectF()
    private val pixels = RectF()

    fun hold(bitmap: Bitmap?) {
        if (!bindingOpen) return
        if (held && previewOffered) return
        held = true
        if (!previewOffered) {
            previewOffered = true
            preview = bitmap
            fadeAt = -1L
        }
        invalidateSelf()
    }

    fun land() {
        held = false
        invalidateSelf()
    }

    fun openBinding() { bindingOpen = true }

    fun ready(drawable: Drawable) {
        if (!bindingOpen) return
        (target as? Animatable)?.stop()
        target?.callback = null
        target = drawable
        drawable.callback = this
        fadeAt = -1L
        invalidateSelf()
    }

    fun clear() {
        bindingOpen = false
        (target as? Animatable)?.stop()
        target?.callback = null
        target = null
        preview = null
        previewOffered = false
        held = false
        fadeAt = -1L
        invalidateSelf()
    }

    override fun draw(canvas: Canvas) {
        aperture.set(bounds)
        drawInto(canvas, aperture, radius)
    }

    /** Both callers supply their own aperture; they never resize or mutate the image itself. */
    fun drawInto(canvas: Canvas, box: RectF, corner: Float, now: Long = AnimationUtils.currentAnimationTimeMillis()) {
        if (box.isEmpty) return
        val source = preview
        val image = target?.takeIf { it.intrinsicWidth > 0 && it.intrinsicHeight > 0 }
        val mix = when {
            image == null -> 0f
            source == null -> 1f
            held -> 0f
            source === (image as? BitmapDrawable)?.bitmap -> 1f
            !ValueAnimator.areAnimatorsEnabled() -> 1f
            else -> {
                // This runs only when there are actual pixels to draw and a laid-out aperture.
                if (fadeAt < 0) fadeAt = now
                DesignMotion.softInOut.getInterpolation(((now - fadeAt).toFloat() / DesignMotion.stateChange).coerceIn(0f, 1f))
            }
        }
        val saved = canvas.save()
        clip.reset()
        clip.addRoundRect(box, corner, corner, Path.Direction.CW)
        canvas.clipPath(clip)
        if (source == null && image == null) {
            paint.color = placeholderColor
            paint.alpha = 255
            canvas.drawRect(box, paint)
        } else if (mix <= 0f && source != null) {
            bitmap(canvas, source, box, 255, false)
        } else if (mix >= 1f && image != null) {
            picture(canvas, image, box, 255, false)
            // The shared Coil cache owns decoded pixels. Drop our only extra reference, don't recycle.
            preview = null
        } else if (source != null && image != null) {
            val layer = canvas.saveLayer(box, null)
            val targetAlpha = (255 * mix).toInt()
            bitmap(canvas, source, box, 255 - targetAlpha, false)
            picture(canvas, image, box, targetAlpha, true)
            canvas.restoreToCount(layer)
        }
        canvas.restoreToCount(saved)
        if (!held && source != null && image != null && mix < 1f) invalidateSelf()
    }

    private fun bitmap(canvas: Canvas, bitmap: Bitmap, box: RectF, alpha: Int, plus: Boolean) {
        ImageCrop.cover(bitmap.width, bitmap.height, box, pixels)
        paint.alpha = alpha
        paint.xfermode = if (plus) add else null
        canvas.drawBitmap(bitmap, null, pixels, paint)
        paint.xfermode = null
    }

    private fun picture(canvas: Canvas, drawable: Drawable, box: RectF, alpha: Int, plus: Boolean) {
        if (drawable is BitmapDrawable) {
            bitmap(canvas, drawable.bitmap, box, alpha, plus)
            return
        }
        ImageCrop.cover(drawable.intrinsicWidth, drawable.intrinsicHeight, box, pixels)
        val saved = if (plus) {
            paint.alpha = alpha
            paint.xfermode = add
            canvas.saveLayer(box, paint).also { paint.xfermode = null }
        } else canvas.save()
        canvas.translate(pixels.left, pixels.top)
        val scale = pixels.width() / drawable.intrinsicWidth
        canvas.scale(scale, scale)
        drawable.setBounds(0, 0, drawable.intrinsicWidth, drawable.intrinsicHeight)
        drawable.draw(canvas)
        canvas.restoreToCount(saved)
    }

    override fun invalidateDrawable(who: Drawable) = invalidateSelf()
    override fun scheduleDrawable(who: Drawable, what: Runnable, `when`: Long) = scheduleSelf(what, `when`)
    override fun unscheduleDrawable(who: Drawable, what: Runnable) = unscheduleSelf(what)
    override fun setAlpha(alpha: Int) = Unit
    override fun setColorFilter(colorFilter: ColorFilter?) = Unit
    @Suppress("DEPRECATION") override fun getOpacity() = PixelFormat.TRANSLUCENT
}

/** Receives the existing media binding's readiness and cancellation without starting a second load. */
internal class SendImageView(context: Context) : AppCompatImageView(context) {
    val presentation = SendImagePresentation(context.getColor(R.color.token_bg_tertiary),
        resources.getDimension(R.dimen.radius_4xl))

    init { super.setImageDrawable(presentation) }

    override fun setImageDrawable(drawable: Drawable?) {
        if (drawable == null) presentation.clear() else presentation.ready(drawable)
        // ImageView gives this drawable the whole fixed tile (no intrinsic dimensions).
        super.setImageDrawable(presentation)
        // A loaded transparent PNG keeps its alpha, including during the handoff.
        background = null
    }
}
