package surf.comma.android.media.video

import android.content.Context
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.animation.AnimationUtils
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import androidx.annotation.MainThread
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import surf.comma.android.R
import surf.comma.android.media.ImageDimensions
import surf.comma.android.media.ImagePlaceholder
import surf.comma.android.media.MediaDownload
import surf.comma.android.media.MediaDownloadState
import surf.comma.android.media.VideoCover
import surf.comma.android.media.VideoCovers
import surf.comma.android.ui.Background
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography
import java.io.File

/**
 * A video in a list: its first frame and a play button, never a playing player. The file is
 * downloaded whole while the card is visible (the backend has no byte ranges), with progress and
 * cancel; the cover is extracted from it once and its size remembered, so the card reserves the
 * right height the next time. Tapping play hands the local file to [VideoPlayerActivity].
 */
class VideoCardView(context: Context) : FrameLayout(context) {
    private val density = resources.displayMetrics.density
    private val cover = ImageView(context).apply { scaleType = ImageView.ScaleType.CENTER_CROP }
    private val control = ControlView(context)
    private val caption = TextView(context).apply {
        DesignTypography.applyTo(this, DesignTypography.Level.MINI, DesignFonts.medium)
        setTextColor(context.getColor(R.color.token_fg_primary))
        background = GradientDrawable().apply {
            setColor(context.getColor(R.color.token_markdown_image_bg_primary))
            cornerRadius = 6 * density
        }
        val h = (8 * density).toInt()
        val v = (2 * density).toInt()
        setPadding(h, v, h, v)
        visibility = View.GONE
    }
    private var job: Job? = null
    private val visible = MutableStateFlow(false)
    private var download: MediaDownload? = null
    private var shownCover: File? = null

    init {
        background = GradientDrawable().apply {
            setColor(context.getColor(R.color.token_bg_tertiary))
            cornerRadius = resources.getDimension(R.dimen.radius_xl)
        }
        clipToOutline = true
        addView(cover, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        val size = (48 * density).toInt()
        addView(control, LayoutParams(size, size, Gravity.CENTER))
        addView(caption, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.START)
            .apply { val m = (8 * density).toInt(); setMargins(m, m, m, m) })
        control.setOnClickListener { onControl() }
    }

    private var play: (VideoCover?, File) -> Unit = { _, _ -> }
    private var playWhenReady = false
    private var lastCover: VideoCover? = null

    /**
     * Freezes the card at [widthPx] and the known or remembered proportions (16:9 until known).
     * [download] is null when the session has ended; the card then stays an empty frame.
     */
    @MainThread
    fun bind(
        download: MediaDownload?,
        covers: VideoCovers,
        widthPx: Int,
        scope: CoroutineScope,
        known: ImageDimensions? = null,
        visible: Boolean = false,
        onPlay: (cover: VideoCover?, file: File) -> Unit,
    ) {
        unbind()
        this.download = download
        play = onPlay
        val placeholder = ImagePlaceholder.reserve(widthPx, known ?: download?.key?.let(covers::dimensions), 16.0 / 9.0)
        layoutParams = (layoutParams ?: ViewGroup.LayoutParams(placeholder.width, placeholder.height)).apply {
            width = placeholder.width
            height = placeholder.height
        }
        this.visible.value = visible
        if (download == null) {
            control.state = MediaDownloadState.Failed(MediaDownloadState.Failure.UNAVAILABLE)
            return
        }
        job = scope.launch(Dispatchers.Main.immediate) {
            combine(download.state, this@VideoCardView.visible) { state, shown -> state to shown }.collectLatest { (state, shown) ->
                control.state = state
                caption.visibility = View.GONE
                when (state) {
                    MediaDownloadState.Idle -> if (shown && !control.cancelledByUser) download.start()
                    is MediaDownloadState.Downloading -> state.progress?.let {
                        caption.text = context.getString(R.string.media_video_progress, (it * 100).toInt())
                        caption.visibility = View.VISIBLE
                    }
                    is MediaDownloadState.Ready -> {
                        showCover(covers, download.key, state.file)
                        // A tap on play started this download: carry on to the player.
                        if (playWhenReady) {
                            playWhenReady = false
                            // Not if the user has since scrolled or navigated away.
                            if (isAttachedToWindow && isShown && hasWindowFocus()) play(lastCover, state.file)
                        }
                    }
                    is MediaDownloadState.Failed -> {
                        caption.setText(if (state.reason == MediaDownloadState.Failure.NETWORK) R.string.media_video_retry
                            else R.string.media_video_unavailable)
                        caption.visibility = View.VISIBLE
                    }
                }
            }
        }
    }

    /** Forward the real viewport and page state; a hidden card starts no download. */
    @MainThread fun setVisible(value: Boolean) { visible.value = value }

    @MainThread
    fun unbind() {
        job?.cancel()
        job = null
        download = null
        control.cancelledByUser = false
        playWhenReady = false
        shownCover = null
        lastCover = null
        cover.setImageDrawable(null)
    }

    private suspend fun showCover(covers: VideoCovers, key: String, file: File) {
        val found = try { covers.cover(key, file) } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null }
        lastCover = found
        val image = found?.file ?: return
        if (image == shownCover) return
        val targetWidth = width.takeIf { it > 0 } ?: layoutParams.width
        val bitmap = withContext(Background.files) {
            runCatching {
                ImageDecoder.decodeBitmap(ImageDecoder.createSource(image)) { decoder, info, _ ->
                    val scale = minOf(1f, targetWidth.toFloat() / info.size.width)
                    decoder.setTargetSize((info.size.width * scale).toInt().coerceAtLeast(1), (info.size.height * scale).toInt().coerceAtLeast(1))
                }
            }.getOrNull()
        } ?: return
        shownCover = image
        cover.setImageBitmap(bitmap)
    }

    private fun onControl() {
        val download = download ?: return
        when (val state = download.state.value) {
            MediaDownloadState.Idle -> { control.cancelledByUser = false; playWhenReady = true; download.start() }
            is MediaDownloadState.Downloading -> { control.cancelledByUser = true; playWhenReady = false; download.cancel() }
            is MediaDownloadState.Ready -> play(lastCover, state.file)
            is MediaDownloadState.Failed -> if (state.reason == MediaDownloadState.Failure.NETWORK) {
                playWhenReady = true
                download.start()
            }
        }
    }

    /** Round button over the cover: play, a progress ring that cancels, or retry. */
    private class ControlView(context: Context) : View(context) {
        var cancelledByUser = false
        var state: MediaDownloadState = MediaDownloadState.Idle
            set(value) {
                field = value
                contentDescription = context.getString(when (value) {
                    is MediaDownloadState.Downloading -> R.string.media_video_cancel
                    is MediaDownloadState.Failed -> R.string.media_video_retry
                    MediaDownloadState.Idle -> R.string.media_video_download
                    is MediaDownloadState.Ready -> R.string.media_video_play
                })
                isClickable = value !is MediaDownloadState.Failed || value.reason == MediaDownloadState.Failure.NETWORK
                invalidate()
            }
        private val density = resources.displayMetrics.density
        private val disc = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = context.getColor(R.color.token_markdown_image_bg_primary) }
        private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2 * density
            color = context.getColor(R.color.token_fg_quaternary)
        }
        private val arc = Paint(track).apply {
            color = context.getColor(R.color.token_fg_primary)
            strokeCap = Paint.Cap.ROUND
        }
        private val playIcon = context.getDrawable(R.drawable.ic_media_play)!!.mutate().apply { setTint(context.getColor(R.color.token_fg_primary)) }
        private val retryIcon = context.getDrawable(R.drawable.ic_media_retry)!!.mutate().apply { setTint(context.getColor(R.color.token_fg_primary)) }
        private val rect = RectF()

        override fun onDraw(canvas: Canvas) {
            val s = state
            if (s is MediaDownloadState.Failed && s.reason != MediaDownloadState.Failure.NETWORK) return
            val cx = width / 2f
            val cy = height / 2f
            canvas.drawCircle(cx, cy, minOf(cx, cy), disc)
            when (s) {
                is MediaDownloadState.Downloading -> {
                    val r = 10 * density
                    rect.set(cx - r, cy - r, cx + r, cy + r)
                    canvas.drawOval(rect, track)
                    val progress = s.progress
                    if (progress != null) {
                        canvas.drawArc(rect, -90f, 360f * progress, false, arc)
                    } else {
                        val t = AnimationUtils.currentAnimationTimeMillis() % SPIN_MS / SPIN_MS.toFloat()
                        canvas.drawArc(rect, 360f * t - 90f, 90f, false, arc)
                        if (android.animation.ValueAnimator.areAnimatorsEnabled()) postInvalidateOnAnimation()
                    }
                }
                is MediaDownloadState.Failed -> drawIcon(canvas, retryIcon, 11f)
                else -> drawIcon(canvas, playIcon, 10f)
            }
        }

        private fun drawIcon(canvas: Canvas, icon: android.graphics.drawable.Drawable, halfDp: Float) {
            val half = (halfDp * density).toInt()
            val cx = width / 2
            val cy = height / 2
            icon.setBounds(cx - half, cy - half, cx + half, cy + half)
            icon.draw(canvas)
        }

        private companion object { const val SPIN_MS = 900L }
    }
}
