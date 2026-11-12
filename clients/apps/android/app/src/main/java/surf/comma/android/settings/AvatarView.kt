package surf.comma.android.settings

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.Drawable
import android.util.LruCache
import android.view.View
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import surf.comma.android.R
import surf.comma.android.media.AnimatedWebP
import surf.comma.android.ui.Background
import surf.comma.android.ui.theme.DesignFonts
import java.nio.ByteBuffer
import java.text.BreakIterator
import kotlin.math.max

/** A decoded avatar: a still picture, or a WebP or GIF that moves (its bytes, made a drawable for each view). */
internal sealed interface AvatarPicture {
    class Still(val bitmap: Bitmap) : AvatarPicture
    class Moving(val bytes: ByteArray) : AvatarPicture
}

/** Decoded avatars, small and few. Remote ones are keyed by session generation and avatar id. */
internal object AvatarImages {
    private const val TARGET_PX = 256
    private val cache = object : LruCache<String, AvatarPicture>(4 * 1024 * 1024) {
        override fun sizeOf(key: String, value: AvatarPicture) = when (value) {
            is AvatarPicture.Still -> value.bitmap.allocationByteCount
            is AvatarPicture.Moving -> value.bytes.size
        }
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    fun key(source: AvatarSource, generation: Long?): String? = when (source) {
        AvatarSource.None -> null
        is AvatarSource.Remote -> generation?.let { "remote:$it:${source.avatarId}" }
    }

    fun cached(key: String): AvatarPicture? = cache.get(key)

    fun load(context: Context, source: AvatarSource, key: String, done: (AvatarPicture?) -> Unit): Job = scope.launch {
        val picture = runCatching {
            withContext(Background.files) {
                when (source) {
                    AvatarSource.None -> null
                    is AvatarSource.Remote -> SettingsGraph.account(context).avatarBytes(source.avatarId)?.let(::decode)
                }
            }
        }.getOrNull()
        if (picture != null) cache.put(key, picture)
        done(picture)
    }

    /** A drawable that plays [picture], at most [TARGET_PX] on its longer side; null when it cannot be read. */
    fun moving(picture: AvatarPicture.Moving, done: (AnimatedImageDrawable?) -> Unit): Job = scope.launch {
        done(runCatching {
            withContext(Background.files) {
                val source = ImageDecoder.createSource(ByteBuffer.wrap(picture.bytes))
                ImageDecoder.decodeDrawable(source) { decoder, info, _ ->
                    val sample = max(1, max(info.size.width, info.size.height) / TARGET_PX)
                    decoder.setTargetSampleSize(sample)
                } as? AnimatedImageDrawable
            }
        }.getOrNull())
    }

    private fun decode(bytes: ByteArray): AvatarPicture? {
        if (isGif(bytes) || AnimatedWebP.isAnimated(bytes)) return AvatarPicture.Moving(bytes)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= TARGET_PX) sample *= 2
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
            ?.let(AvatarPicture::Still)
    }

    private fun isGif(bytes: ByteArray) =
        bytes.size >= 6 && String(bytes, 0, 6, Charsets.US_ASCII).let { it == "GIF87a" || it == "GIF89a" }
}

/** A round avatar: the picture (a moving WebP or GIF plays), cropped to fill, or the name's first letter on the brand colour. */
internal class AvatarView(context: Context) : View(context) {
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = context.color(R.color.token_bg_brand_solid) }
    private val letterPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        // White on the brand fill, as on the user's message bubble (DESIGN §5).
        color = android.graphics.Color.WHITE
        typeface = DesignFonts.inter(context, DesignFonts.semibold)
        textAlign = Paint.Align.CENTER
    }
    private val imagePaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val matrix = Matrix()
    private var bitmap: Bitmap? = null
    private var animated: AnimatedImageDrawable? = null
    private val circle = Path()
    private var letter = ""
    private var key: String? = null
    private var shownGeneration: Long? = null
    private var loading: Job? = null

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /**
     * Shows [source] for the account [generation], or the first letter of [name] until and unless
     * a picture is available. Within one account a picture being replaced stays until the new one
     * is decoded; another account's picture never does.
     */
    fun show(source: AvatarSource, name: String, generation: Long?) {
        letter = initial(name)
        val next = AvatarImages.key(source, generation)
        if (next == key) { invalidate(); return }
        key = next
        loading?.cancel()
        loading = null
        if (next == null || generation != shownGeneration) clearPicture()
        shownGeneration = generation
        if (next == null) return
        AvatarImages.cached(next)?.let { display(next, it); return }
        loading = AvatarImages.load(context, source, next) { decoded ->
            if (key == next && decoded != null) display(next, decoded)
        }
    }

    private fun display(shown: String, picture: AvatarPicture) {
        when (picture) {
            is AvatarPicture.Still -> setBitmap(picture.bitmap)
            is AvatarPicture.Moving -> loading = AvatarImages.moving(picture) { drawable ->
                if (key == shown && drawable != null) setAnimated(drawable)
            }
        }
    }

    private fun clearPicture() {
        setBitmap(null)
        setAnimated(null)
    }

    private fun setBitmap(value: Bitmap?) {
        if (value != null) setAnimated(null)
        bitmap = value
        imagePaint.shader = value?.let { BitmapShader(it, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP) }
        updateShader()
        invalidate()
    }

    private fun setAnimated(value: AnimatedImageDrawable?) {
        animated?.let { it.stop(); it.callback = null }
        if (value != null) setBitmap(null)
        animated = value
        value?.let {
            it.callback = this
            updateAnimatedBounds()
            if (isAttachedToWindow) it.start()
        }
        invalidate()
    }

    override fun verifyDrawable(who: Drawable) = who === animated || super.verifyDrawable(who)

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        updateShader()
        updateAnimatedBounds()
    }

    /** Fills the view with the animation, cropped to its middle like a still picture. */
    private fun updateAnimatedBounds() {
        val drawable = animated ?: return
        val size = minOf(width, height).toFloat()
        val w = drawable.intrinsicWidth
        val h = drawable.intrinsicHeight
        if (size <= 0f || w <= 0 || h <= 0) return
        val scale = size / minOf(w, h)
        val left = ((width - w * scale) / 2f).toInt()
        val top = ((height - h * scale) / 2f).toInt()
        drawable.setBounds(left, top, left + (w * scale).toInt(), top + (h * scale).toInt())
        circle.reset()
        circle.addCircle(width / 2f, height / 2f, size / 2f, Path.Direction.CW)
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        animated?.start()
    }

    private fun updateShader() {
        val image = bitmap ?: return
        val size = minOf(width, height).toFloat()
        if (size <= 0f) return
        val scale = size / minOf(image.width, image.height)
        matrix.setScale(scale, scale)
        matrix.postTranslate((width - image.width * scale) / 2f, (height - image.height * scale) / 2f)
        imagePaint.shader?.setLocalMatrix(matrix)
    }

    override fun onDetachedFromWindow() {
        loading?.cancel()
        loading = null
        animated?.stop()
        // Load again when shown next time.
        if (bitmap == null && animated == null) key = null
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val radius = minOf(width, height) / 2f
        val cx = width / 2f
        val cy = height / 2f
        if (bitmap != null) {
            canvas.drawCircle(cx, cy, radius, imagePaint)
            return
        }
        animated?.let {
            canvas.save()
            canvas.clipPath(circle)
            it.draw(canvas)
            canvas.restore()
            return
        }
        canvas.drawCircle(cx, cy, radius, fill)
        letterPaint.textSize = radius * 0.9f
        val baseline = cy - (letterPaint.descent() + letterPaint.ascent()) / 2f
        canvas.drawText(letter, cx, baseline, letterPaint)
    }

    companion object {
        /** The first user-perceived character, upper-cased. */
        fun initial(name: String): String {
            val trimmed = name.trim()
            if (trimmed.isEmpty()) return ""
            val iterator = BreakIterator.getCharacterInstance().apply { setText(trimmed) }
            return trimmed.substring(0, iterator.next()).uppercase()
        }
    }
}
