package surf.comma.android.media.video

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.media.MediaGraph
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography
import java.io.File

/**
 * Plays one fully downloaded video file. The backend serves no byte ranges, so nothing streams:
 * the file is already in the media cache. The player exists only while this page is started,
 * and it is the only one in the process ([VideoPlayers]).
 */
class VideoPlayerActivity : ComponentActivity() {
    private lateinit var file: File
    private lateinit var frame: AspectFitLayout
    private lateinit var surface: SurfaceView
    private lateinit var paused: ImageView
    private lateinit var error: TextView
    private var player: ExoPlayer? = null
    private var position = 0L
    private var playing = true

    override fun onCreate(savedInstanceState: Bundle?) {
        // Light system-bar icons on the dark backdrop, in either theme.
        enableEdgeToEdge(SystemBarStyle.dark(android.graphics.Color.TRANSPARENT), SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        super.onCreate(savedInstanceState)
        val path = intent.getStringExtra(EXTRA_PATH)
        // Only files this app downloaded or wrote itself.
        val candidate = path?.let(::File)?.canonicalFile
        if (candidate == null || !candidate.isFile || !candidate.path.startsWith(cacheDir.canonicalPath + File.separator)) return finish()
        file = candidate
        position = savedInstanceState?.getLong(STATE_POSITION) ?: 0L
        playing = savedInstanceState?.getBoolean(STATE_PLAYING) ?: true
        if (intent.getBooleanExtra(EXTRA_SESSION_BOUND, false)) {
            val http = MediaGraph.get(this).http
            val session = http.session.value ?: return finish()
            lifecycleScope.launch {
                http.session.drop(1).first { it != session }
                finish()
            }
        }

        val density = resources.displayMetrics.density
        val root = FrameLayout(this).apply { setBackgroundColor(getColor(R.color.token_bg_overlay)) }
        frame = AspectFitLayout(this)
        surface = SurfaceView(this)
        frame.addView(surface, FrameLayout.LayoutParams(-1, -1))
        root.addView(frame, FrameLayout.LayoutParams(-1, -1))
        paused = ImageView(this).apply {
            setImageResource(R.drawable.ic_media_play)
            imageTintList = android.content.res.ColorStateList.valueOf(getColor(android.R.color.white))
            contentDescription = getString(R.string.media_video_play)
            visibility = View.GONE
        }
        root.addView(paused, FrameLayout.LayoutParams((56 * density).toInt(), (56 * density).toInt(), Gravity.CENTER))
        error = TextView(this).apply {
            DesignTypography.applyTo(this, DesignTypography.Level.SMALL, DesignFonts.regular)
            setTextColor(getColor(android.R.color.white))
            setText(R.string.media_video_cannot_play)
            visibility = View.GONE
        }
        root.addView(error, FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))
        val chrome = FrameLayout(this)
        val close = ImageButton(this).apply {
            setImageResource(R.drawable.ic_media_close)
            imageTintList = android.content.res.ColorStateList.valueOf(getColor(android.R.color.white))
            background = null
            val padding = (10 * density).toInt()
            setPadding(padding, padding, padding, padding)
            contentDescription = getString(R.string.media_viewer_close)
            setOnClickListener { finish() }
        }
        chrome.addView(close, FrameLayout.LayoutParams((44 * density).toInt(), (44 * density).toInt(), Gravity.TOP or Gravity.START)
            .apply { val m = (8 * density).toInt(); setMargins(m, m, m, m) })
        root.addView(chrome, FrameLayout.LayoutParams(-1, -1))
        ViewCompat.setOnApplyWindowInsetsListener(chrome) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.updatePadding(left = bars.left, top = bars.top, right = bars.right, bottom = bars.bottom)
            insets
        }
        root.setOnClickListener { toggle() }
        setContentView(root)
        intent.getIntExtra(EXTRA_WIDTH, 0).let { width ->
            val height = intent.getIntExtra(EXTRA_HEIGHT, 0)
            if (width > 0 && height > 0) frame.ratio = width.toFloat() / height
        }
    }

    override fun onStart() {
        super.onStart()
        if (!::file.isInitialized) return
        val created = VideoPlayers.slot.acquire(this, { ExoPlayer.Builder(this).build() }, onRevoked = { player = null })
        player = created
        created.addListener(listener)
        created.setVideoSurfaceView(surface)
        created.setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
        created.prepare()
        created.seekTo(position)
        created.playWhenReady = playing
    }

    override fun onStop() {
        player?.let {
            position = it.currentPosition
            playing = it.playWhenReady
            it.removeListener(listener)
        }
        player = null
        VideoPlayers.slot.release(this)
        super.onStop()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        player?.let { position = it.currentPosition; playing = it.playWhenReady }
        outState.putLong(STATE_POSITION, position)
        outState.putBoolean(STATE_PLAYING, playing)
    }

    private fun toggle() {
        val current = player ?: return
        if (current.playbackState == Player.STATE_ENDED) {
            current.seekTo(0)
            current.playWhenReady = true
        } else {
            current.playWhenReady = !current.playWhenReady
        }
    }

    private val listener = object : Player.Listener {
        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (videoSize.width > 0 && videoSize.height > 0) {
                frame.ratio = videoSize.width * videoSize.pixelWidthHeightRatio / videoSize.height
            }
        }

        override fun onEvents(player: Player, events: Player.Events) {
            val showPlay = !player.playWhenReady || player.playbackState == Player.STATE_ENDED
            paused.visibility = if (showPlay && error.visibility != View.VISIBLE) View.VISIBLE else View.GONE
        }

        override fun onPlayerError(failure: PlaybackException) {
            error.visibility = View.VISIBLE
            paused.visibility = View.GONE
        }
    }

    companion object {
        private const val EXTRA_PATH = "surf.comma.android.media.video.PATH"
        private const val EXTRA_WIDTH = "surf.comma.android.media.video.WIDTH"
        private const val EXTRA_HEIGHT = "surf.comma.android.media.video.HEIGHT"
        private const val EXTRA_SESSION_BOUND = "surf.comma.android.media.video.SESSION_BOUND"
        private const val STATE_POSITION = "position"
        private const val STATE_PLAYING = "playing"

        /** [sessionBound]: the file came from the signed-in session and must close with it. */
        fun intent(context: Context, file: File, width: Int = 0, height: Int = 0, sessionBound: Boolean = true): Intent =
            Intent(context, VideoPlayerActivity::class.java)
                .putExtra(EXTRA_PATH, file.path)
                .putExtra(EXTRA_WIDTH, width)
                .putExtra(EXTRA_HEIGHT, height)
                .putExtra(EXTRA_SESSION_BOUND, sessionBound)
    }
}

/** Sizes its children to the largest box of [ratio] (width / height) that fits, centred. */
class AspectFitLayout(context: Context) : FrameLayout(context) {
    var ratio = 16f / 9f
        set(value) {
            if (value > 0 && value.isFinite() && value != field) {
                field = value
                requestLayout()
            }
        }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = MeasureSpec.getSize(heightMeasureSpec)
        setMeasuredDimension(width, height)
        var childWidth = width
        var childHeight = (width / ratio).toInt()
        if (childHeight > height) {
            childHeight = height
            childWidth = (height * ratio).toInt()
        }
        for (i in 0 until childCount) {
            getChildAt(i).measure(MeasureSpec.makeMeasureSpec(childWidth, MeasureSpec.EXACTLY),
                MeasureSpec.makeMeasureSpec(childHeight, MeasureSpec.EXACTLY))
        }
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        for (i in 0 until childCount) {
            val child = getChildAt(i)
            val x = (width - child.measuredWidth) / 2
            val y = (height - child.measuredHeight) / 2
            child.layout(x, y, x + child.measuredWidth, y + child.measuredHeight)
        }
    }
}
