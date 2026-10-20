package surf.comma.android.ui.composer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.view.animation.AnimationUtils
import android.widget.FrameLayout
import android.widget.ImageView
import surf.comma.android.R
import surf.comma.android.platform.logging.AppLog
import kotlinx.coroutines.*
import android.graphics.drawable.BitmapDrawable
import surf.comma.android.media.MediaGraph
import surf.comma.android.media.ViewerImage
import surf.comma.android.ui.theme.DesignMotion

/**
 * One attached image above the text: a rounded thumbnail, its upload state drawn on top, and a
 * remove button in the corner. A failed upload is retried by tapping the thumbnail.
 */
internal class AttachmentThumbView(
    context: Context,
    private val style: ComposerStyle,
    val attachmentId: String,
    val uri: Uri,
    onRemove: (String) -> Unit,
    onRetry: (String) -> Unit,
) : FrameLayout(context) {

    private val image = ImageView(context)
    private val overlay = UploadOverlay(context, style)
    var bitmap: Bitmap? = null
        private set

    var state: AttachmentUploadState = AttachmentUploadState.Pending
        set(value) {
            field = value
            overlay.state = value
            contentDescription = if (value == AttachmentUploadState.Failed) {
                context.getString(R.string.composer_attachment_retry)
            } else {
                null
            }
        }

    init {
        val radius = style.dp(RADIUS_DP.toFloat())
        image.scaleType = ImageView.ScaleType.CENTER_CROP
        image.background = GradientDrawable().apply {
            setColor(style.bgTertiary)
            cornerRadius = radius
        }
        image.clipToOutline = true
        image.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setRoundRect(0, 0, view.width, view.height, radius)
            }
        }
        addView(image, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(overlay, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))

        val remove = ImageView(context).apply {
            setImageResource(R.drawable.ic_composer_close)
            setColorFilter(style.onBrand)
            val pad = style.dp(3)
            setPadding(pad, pad, pad, pad)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(style.scrim)
            }
            contentDescription = context.getString(R.string.composer_attachment_remove)
            setOnClickListener { onRemove(attachmentId) }
        }
        val removeSize = style.dp(20)
        addView(remove, LayoutParams(removeSize, removeSize, Gravity.TOP or Gravity.END).apply {
            topMargin = style.dp(4)
            marginEnd = style.dp(4)
        })
        setOnClickListener { if (state == AttachmentUploadState.Failed) onRetry(attachmentId) }
        load()
    }

    private var owner: CoroutineScope? = null

    override fun onAttachedToWindow() { super.onAttachedToWindow(); load() }
    override fun onDetachedFromWindow() {
        owner?.cancel(); owner = null
        image.setImageDrawable(null)
        bitmap = null
        super.onDetachedFromWindow()
    }

    private fun load() {
        if (!isAttachedToWindow || owner != null || bitmap != null) return
        owner = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).also { scope ->
            scope.launch {
                try {
                    // Providers may return pre-cropped loadThumbnail pixels. Ask the shared loader
                    // for the original URI, oriented by its decoder, with bounded full-image size.
                    val decoded = MediaGraph.get(context).images().load(
                        ViewerImage.Local(uri, "image/*", null), PREVIEW_EDGE, PREVIEW_EDGE)
                    ensureActive()
                    bitmap = (decoded as? BitmapDrawable)?.bitmap
                    image.setImageBitmap(bitmap)
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (error: Exception) { AppLog.debug(TAG, error, "Thumbnail failed") }
            }
        }
    }

    /** Scrim plus a ring: still while pending, an arc while uploading, a retry glyph on failure. */
    private class UploadOverlay(context: Context, private val tokens: ComposerStyle) : View(context) {
        private val scrim = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = tokens.scrim }
        private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = tokens.dp(2f)
            color = 0x59FFFFFF
        }
        private val arc = Paint(track).apply {
            color = tokens.onBrand
            strokeCap = Paint.Cap.ROUND
        }
        private val retry = context.getDrawable(R.drawable.ic_composer_retry)!!.mutate().apply {
            setTint(tokens.onBrand)
        }
        private val rect = RectF()

        var state: AttachmentUploadState = AttachmentUploadState.Pending
            set(value) {
                field = value
                val done = value == AttachmentUploadState.Done
                if (done && ComposerStyle.motionEnabled && isLaidOut) {
                    animate().alpha(0f).setDuration(DesignMotion.feedbackOut).start()
                } else {
                    animate().cancel()
                    alpha = if (done) 0f else 1f
                }
                invalidate()
            }

        override fun onDraw(canvas: Canvas) {
            val s = state
            if (s == AttachmentUploadState.Done) return
            val radius = tokens.dp(RADIUS_DP.toFloat())
            canvas.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), radius, radius, scrim)
            val cx = width / 2f
            val cy = height / 2f
            if (s == AttachmentUploadState.Failed) {
                val half = tokens.dp(10)
                retry.setBounds((cx - half).toInt(), (cy - half).toInt(), (cx + half).toInt(), (cy + half).toInt())
                retry.draw(canvas)
                return
            }
            val r = tokens.dp(9f)
            rect.set(cx - r, cy - r, cx + r, cy + r)
            canvas.drawOval(rect, track)
            if (s is AttachmentUploadState.Uploading) {
                val progress = s.progress
                if (progress != null) {
                    canvas.drawArc(rect, -90f, 360f * progress.coerceIn(0f, 1f), false, arc)
                } else {
                    val t = AnimationUtils.currentAnimationTimeMillis() % SPIN_MS / SPIN_MS.toFloat()
                    canvas.drawArc(rect, 360f * t - 90f, 90f, false, arc)
                    if (ComposerStyle.motionEnabled) postInvalidateOnAnimation()
                }
            }
        }

        private companion object {
            const val SPIN_MS = 900L
        }
    }

    companion object {
        const val SIZE_DP = 64
        /** DESIGN radius 2xl. */
        const val RADIUS_DP = 16
        private const val TAG = "ComposerThumb"
        private const val PREVIEW_EDGE = 1024
    }
}
