package surf.comma.android.media.viewer

import android.net.Uri
import android.view.Gravity
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.media.MediaComponents
import surf.comma.android.media.MediaDownload
import surf.comma.android.media.MediaDownloadState
import surf.comma.android.media.ViewerImage
import surf.comma.android.media.video.AspectFitLayout
import surf.comma.android.media.video.VideoPlayers
import java.io.File

/**
 * The viewer's current video page. Only the current page reads its file (whole, through the core's download, as the
 * chat's video cards do) and plays it with the process's single player; paging away, closing or leaving the app
 * releases the player. A failed read offers Retry until playback shows.
 */
internal class ViewerVideo(private val activity: ComponentActivity, private val media: MediaComponents) {
    private var page: ViewerPage? = null
    private var item: ViewerImage.Video? = null
    private var watch: Job? = null
    private var player: ExoPlayer? = null
    private var file: File? = null
    private var position = 0L
    private var playing = true
    private var failed = false
    private var started = true
    /** The read this page started, which stops with it. One already running belongs to the chat's card. */
    private var reading: MediaDownload? = null

    /** [page] is now the current page and shows [video]. */
    fun show(page: ViewerPage, video: ViewerImage.Video) {
        if (this.page === page && item == video) return
        hide()
        this.page = page
        item = video
        position = 0L
        playing = true
        val frame = page.videoFrame()
        video.dimensions?.let { frame.ratio = it.width.toFloat() / it.height }
        page.message.visibility = View.GONE
        read()
    }

    /** The page is no longer current: its player and read stop. */
    fun hide() {
        release()
        watch?.cancel()
        watch = null
        reading?.cancel()
        reading = null
        page?.let { it.videoFrame().visibility = View.INVISIBLE; it.paused().visibility = View.GONE }
        page = null
        item = null
        file = null
        failed = false
    }

    /** Leaving the app pauses: the player is released, and the place kept for the return. */
    fun stop() {
        started = false
        player?.let { position = it.currentPosition; playing = it.playWhenReady }
        release()
    }

    fun start() {
        started = true
        file?.let(::play)
    }

    /** A tap on the page: play or pause, or read again after a failure. */
    fun tap(): Boolean {
        if (page == null) return false
        if (failed && player == null) {
            read()
            return true
        }
        val current = player ?: return true
        if (current.playbackState == Player.STATE_ENDED) {
            current.seekTo(0)
            current.playWhenReady = true
        } else current.playWhenReady = !current.playWhenReady
        return true
    }

    private fun read() {
        val page = page ?: return
        val video = item ?: return
        failed = false
        watch?.cancel()
        val download = media.files.download(video.attachment) ?: return fail()
        // A failure waits for a start: showing the page or tapping Retry is that start.
        if (download.state.value is MediaDownloadState.Failed) {
            reading = download
            download.start()
        }
        watch = activity.lifecycleScope.launch {
            download.state.collect { state ->
                if (this@ViewerVideo.page !== page) return@collect
                when (state) {
                    MediaDownloadState.Idle -> {
                        reading = download
                        download.start()
                    }
                    is MediaDownloadState.Downloading -> status(state.progress?.let {
                        activity.getString(R.string.media_video_progress, (it * 100).toInt())
                    })
                    is MediaDownloadState.Ready -> {
                        status(null)
                        file = state.file
                        if (started) play(state.file)
                    }
                    is MediaDownloadState.Failed -> fail()
                }
            }
        }
    }

    private fun play(file: File) {
        val page = page ?: return
        if (player != null) return
        val frame = page.videoFrame()
        val created = VideoPlayers.slot.acquire(this, { ExoPlayer.Builder(activity).build() }, onRevoked = { player = null })
        player = created
        created.addListener(listener)
        created.setVideoSurfaceView(frame.getChildAt(0) as SurfaceView)
        created.setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
        created.prepare()
        created.seekTo(position)
        created.playWhenReady = playing
    }

    private fun release() {
        player?.removeListener(listener)
        player = null
        VideoPlayers.slot.release(this)
    }

    private fun status(text: String?) {
        val message = page?.message ?: return
        message.text = text
        message.visibility = if (text == null) View.GONE else View.VISIBLE
    }

    private fun fail() {
        // Playback that already shows keeps its picture clear of the failure.
        if (player?.playbackState == Player.STATE_READY) return
        failed = true
        status(activity.getString(R.string.media_video_retry))
    }

    private val listener = object : Player.Listener {
        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (videoSize.width > 0 && videoSize.height > 0) {
                page?.videoFrame()?.ratio = videoSize.width * videoSize.pixelWidthHeightRatio / videoSize.height
            }
        }

        override fun onRenderedFirstFrame() {
            page?.videoFrame()?.visibility = View.VISIBLE
            failed = false
            status(null)
        }

        override fun onEvents(player: Player, events: Player.Events) {
            val paused = !player.playWhenReady || player.playbackState == Player.STATE_ENDED
            page?.paused()?.visibility = if (paused && !failed) View.VISIBLE else View.GONE
        }

        override fun onPlayerError(error: PlaybackException) {
            release()
            failed = true
            status(activity.getString(R.string.media_video_cannot_play))
        }
    }
}

/** The page's video surface, made the first time the page shows a video. */
internal fun ViewerPage.videoFrame(): AspectFitLayout {
    (findViewWithTag<View>(VIDEO_TAG) as? AspectFitLayout)?.let { return it }
    return AspectFitLayout(context).apply {
        tag = VIDEO_TAG
        visibility = View.INVISIBLE
        addView(SurfaceView(context), FrameLayout.LayoutParams(-1, -1))
        this@videoFrame.addView(this, 1, FrameLayout.LayoutParams(-1, -1))
    }
}

/** The play glyph over a paused video. */
internal fun ViewerPage.paused(): ImageView {
    (findViewWithTag<View>(PAUSED_TAG) as? ImageView)?.let { return it }
    val size = (56 * resources.displayMetrics.density).toInt()
    return ImageView(context).apply {
        tag = PAUSED_TAG
        setImageResource(R.drawable.ic_media_play)
        imageTintList = android.content.res.ColorStateList.valueOf(context.getColor(android.R.color.white))
        contentDescription = context.getString(R.string.media_video_play)
        visibility = View.GONE
        this@paused.addView(this, FrameLayout.LayoutParams(size, size, Gravity.CENTER))
    }
}

private const val VIDEO_TAG = "viewer-video"
private const val PAUSED_TAG = "viewer-video-paused"
