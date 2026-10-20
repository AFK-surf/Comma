package surf.comma.android.media.demo

import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import android.net.Uri
import android.os.Bundle
import android.widget.CheckBox
import android.widget.ImageView
import android.widget.LinearLayout
import surf.comma.android.scroll.widget.ScrollContainer
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import surf.comma.android.R
import surf.comma.android.media.AspectRatioCache
import surf.comma.android.media.ImageDimensions
import surf.comma.android.media.MediaAttachment
import surf.comma.android.media.MediaDownload
import surf.comma.android.media.MediaDownloadState
import surf.comma.android.media.VideoCovers
import surf.comma.android.media.ViewerImage
import surf.comma.android.media.file.FileCardView
import surf.comma.android.media.video.VideoCardView
import surf.comma.android.media.video.VideoPlayerActivity
import surf.comma.android.media.viewer.ImageViewerActivity
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography
import java.io.File
import java.security.MessageDigest

/**
 * Debug-only playground for the media components on local files: the image viewer, video covers
 * and player, and file cards. Downloads are simulated (progress, cancel, and a failure switch), so
 * it needs no sign-in or server. `adb shell am start -n <package>/surf.comma.android.media.demo.MediaDemoActivity`.
 */
class MediaDemoActivity : ComponentActivity() {
    private val density get() = resources.displayMetrics.density
    private val failNext = MutableStateFlow(false)
    private val root by lazy { File(cacheDir, "media-demo") }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val gutter = (16 * density).toInt()
            setPadding(gutter, gutter, gutter, gutter)
        }
        val scroll = ScrollContainer(this).apply {
            setBackgroundColor(getColor(R.color.token_bg_primary))
            addView(column)
        }
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.updatePadding(top = bars.top, bottom = bars.bottom)
            insets
        }
        setContentView(scroll)
        root.deleteRecursively()
        val width = resources.displayMetrics.widthPixels - (32 * density).toInt()

        column.addView(heading("Images"))
        val pictures = (1..8).map { index ->
            val name = "fixture_image_%02d".format(index)
            // Numeric form: the image loader resolves resources by ID, not by type/name.
            @android.annotation.SuppressLint("DiscouragedApi")
            val id = resources.getIdentifier(name, "drawable", packageName)
            ViewerImage.Local(Uri.parse("android.resource://$packageName/$id"), "image/png", "$name.png")
        }
        val grid = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        pictures.chunked(4).forEachIndexed { row, chunk ->
            val line = LinearLayout(this)
            chunk.forEachIndexed { column, picture ->
                val size = (width - (3 * 6 * density).toInt()) / 4
                line.addView(ImageView(this).apply {
                    scaleType = ImageView.ScaleType.CENTER_CROP
                    setImageURI(picture.uri)
                    contentDescription = picture.fileName
                    setOnClickListener { ImageViewerActivity.start(this@MediaDemoActivity, pictures, row * 4 + column) }
                }, LinearLayout.LayoutParams(size, size).apply { if (column > 0) marginStart = (6 * density).toInt() })
            }
            grid.addView(line, LinearLayout.LayoutParams(-1, -2).apply { if (row > 0) topMargin = (6 * density).toInt() })
        }
        column.addView(grid)

        column.addView(heading("Videos"))
        val failSwitch = CheckBox(this).apply {
            text = "Fail the next download"
            setTextColor(getColor(R.color.token_text_primary))
            setOnCheckedChangeListener { _, checked -> failNext.value = checked }
        }
        column.addView(failSwitch)
        // Untick once a download has used it up.
        lifecycleScope.launch { failNext.collect { if (!it) failSwitch.isChecked = false } }
        val covers = VideoCovers(AspectRatioCache.memory())
        listOf(
            Triple("landscape.mp4", R.raw.media_demo_landscape, null),
            Triple("portrait.webm", R.raw.media_demo_portrait, ImageDimensions(360, 640)),
        ).forEach { (name, raw, known) ->
            val card = VideoCardView(this)
            val download = SimulatedDownload(name, lifecycleScope) { output -> resources.openRawResource(raw).use { input -> output.outputStream().use { input.copyTo(it) } } }
            column.addView(card, LinearLayout.LayoutParams(-2, -2).apply { topMargin = (8 * density).toInt() })
            card.bind(download, covers, if (known != null) width / 2 else width, lifecycleScope, known, visible = true) { cover, file ->
                startActivity(VideoPlayerActivity.intent(this, file, cover?.dimensions?.width ?: 0,
                    cover?.dimensions?.height ?: 0, sessionBound = false))
            }
        }

        column.addView(heading("Files"))
        fileCard(column, MediaAttachment("Quarterly report.pdf", "application/pdf", null, null)) { writePdf(it) }
        fileCard(column, MediaAttachment("dashboard.html", "text/html", null, null)) {
            it.writeText("<!doctype html><title>Demo</title><h1>Opened by another app</h1><script>document.title='ran'</script>")
        }
        fileCard(column, MediaAttachment("diagram.svg", "image/svg+xml", null, null)) {
            it.writeText("<svg xmlns='http://www.w3.org/2000/svg' width='120' height='80'><rect width='120' height='80' fill='#205BFF'/></svg>")
        }
        fileCard(column, MediaAttachment("notes.md", "", null, null)) { it.writeText("# Notes\n\nPlain text, opened elsewhere.\n") }
        fileCard(column, MediaAttachment("archive.bin", "application/x-comma-unknown", null, null)) { it.writeBytes(ByteArray(2048)) }
        // Over the limit: shown as a card that explains it cannot be downloaded here.
        column.addView(FileCardView(this).apply {
            bind(MediaAttachment("screen-recording.mov", "video/quicktime", 25_000_000, null), null, lifecycleScope)
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = (8 * density).toInt() })
    }

    private fun fileCard(column: LinearLayout, attachment: MediaAttachment, write: (File) -> Unit) {
        val download = SimulatedDownload(attachment.displayName, lifecycleScope, write)
        val sized = attachment.copy(size = 48_000L)
        column.addView(FileCardView(this).apply { bind(sized, download, lifecycleScope) },
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = (8 * density).toInt() })
    }

    private fun heading(text: String) = TextView(this).apply {
        this.text = text
        DesignTypography.applyTo(this, DesignTypography.Level.LARGE, DesignFonts.semibold)
        setTextColor(getColor(R.color.token_text_primary))
        setPadding(0, (20 * density).toInt(), 0, (8 * density).toInt())
    }

    private fun writePdf(output: File) {
        val document = PdfDocument()
        val page = document.startPage(PdfDocument.PageInfo.Builder(595, 842, 1).create())
        page.canvas.drawText("comma media demo", 72f, 96f, Paint().apply { textSize = 24f })
        document.finishPage(page)
        output.outputStream().use(document::writeTo)
        document.close()
    }

    /** A download that writes a local sample slowly, so progress, cancel and retry can be tried. */
    private inner class SimulatedDownload(
        private val name: String,
        private val scope: CoroutineScope,
        private val write: (File) -> Unit,
    ) : MediaDownload {
        override val key: String = MessageDigest.getInstance("SHA-256").digest(name.toByteArray())
            .joinToString("") { "%02x".format(it) }
        private val mutableState = MutableStateFlow<MediaDownloadState>(MediaDownloadState.Idle)
        override val state = mutableState.asStateFlow()
        private var job: Job? = null

        override fun start() {
            if (job?.isActive == true || state.value is MediaDownloadState.Ready) return
            job = scope.launch {
                val total = 1_000_000L
                for (step in 0..20) {
                    mutableState.value = MediaDownloadState.Downloading(total * step / 20, total)
                    delay(90)
                    if (step == 12 && failNext.value) {
                        failNext.value = false
                        mutableState.value = MediaDownloadState.Failed(MediaDownloadState.Failure.NETWORK)
                        return@launch
                    }
                }
                val file = withContext(Dispatchers.IO) {
                    File(root, "$key/data/$name").apply { parentFile!!.mkdirs(); write(this) }
                }
                mutableState.value = MediaDownloadState.Ready(file)
            }
        }

        override fun cancel() {
            job?.cancel()
            if (state.value is MediaDownloadState.Downloading) mutableState.value = MediaDownloadState.Idle
        }
    }
}
