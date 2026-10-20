package surf.comma.android.settings

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Shader
import android.util.LruCache
import android.view.View
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import surf.comma.android.R
import surf.comma.android.ui.Background
import surf.comma.android.ui.theme.DesignFonts
import java.text.BreakIterator
import kotlin.math.max

/** Decoded avatars, small and few. Remote ones are keyed by session generation and avatar id. */
internal object AvatarImages {
    private const val TARGET_PX = 256
    private val cache = object : LruCache<String, Bitmap>(4 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    fun key(source: AvatarSource, generation: Long?): String? = when (source) {
        AvatarSource.None -> null
        is AvatarSource.Remote -> generation?.let { "remote:$it:${source.avatarId}" }
    }

    fun cached(key: String): Bitmap? = cache.get(key)

    fun load(context: Context, source: AvatarSource, key: String, done: (Bitmap?) -> Unit): Job = scope.launch {
        val bitmap = runCatching {
            withContext(Background.files) {
                when (source) {
                    AvatarSource.None -> null
                    is AvatarSource.Remote -> SettingsGraph.account(context).avatarBytes(source.avatarId)?.let(::decode)
                }
            }
        }.getOrNull()
        if (bitmap != null) cache.put(key, bitmap)
        done(bitmap)
    }

    private fun decode(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= TARGET_PX) sample *= 2
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
    }
}

/** A round avatar: the picture, cropped to fill, or the name's first letter on the brand colour. */
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
        if (next == null || generation != shownGeneration) setBitmap(null)
        shownGeneration = generation
        if (next == null) return
        AvatarImages.cached(next)?.let { setBitmap(it); return }
        loading = AvatarImages.load(context, source, next) { decoded ->
            if (key == next && decoded != null) setBitmap(decoded)
        }
    }

    private fun setBitmap(value: Bitmap?) {
        bitmap = value
        imagePaint.shader = value?.let { BitmapShader(it, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP) }
        updateShader()
        invalidate()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = updateShader()

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
        // Load again when shown next time.
        if (bitmap == null) key = null
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
