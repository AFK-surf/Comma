package surf.comma.android.media

import android.content.Context
import android.net.Uri
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import kotlinx.coroutines.*
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignTypography
import java.io.File

/** A local photo/fixture tile using the same Coil loader and lifecycle as message attachments. */
class TimelineImageView(context: Context) : FrameLayout(context) {
    private val picture = ImageView(context)
    private val retry = TextView(context).apply {
        DesignTypography.applyTo(this, DesignTypography.Level.SMALL)
        setTextColor(context.getColor(R.color.token_text_tertiary))
        setText(R.string.media_viewer_load_failed)
        gravity = Gravity.CENTER
        visibility = View.GONE
    }
    private var source: ViewerImage.Local? = null
    private var scope: CoroutineScope? = null
    private var binding: MediaImageBinding? = null
    private var visible = false
    var onOpen: (() -> Unit)? = null

    init {
        setBackgroundColor(context.getColor(R.color.token_bg_tertiary))
        addView(picture, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(retry, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        picture.setOnClickListener { onOpen?.invoke() }
        retry.setOnClickListener { retry.visibility = View.GONE; binding?.retry() }
    }

    fun bind(image: ViewerImage.Local?) {
        if (source == image && binding != null) return
        release()
        source = image
        retry.visibility = if (image == null) View.VISIBLE else View.GONE
        start()
    }

    fun setVisible(value: Boolean) { visible = value; binding?.setVisible(value) }
    override fun onAttachedToWindow() { super.onAttachedToWindow(); start() }
    override fun onDetachedFromWindow() { release(); super.onDetachedFromWindow() }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w != oldw || h != oldh) { release(); start() }
    }

    private fun start() {
        val image = source ?: return
        if (!isAttachedToWindow || width <= 0 || height <= 0 || scope != null) return
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).also { owner ->
            owner.launch {
                val images = MediaGraph.get(context).images()
                // Freeze at the host tile's size. The decoded pixels remain aspect-fit within it.
                binding = images.bind(picture, image.copy(dimensions = ImageDimensions(width, height)), width, visible) {
                    retry.visibility = View.VISIBLE
                }
            }
        }
    }

    fun release() {
        binding?.close(); binding = null
        scope?.cancel(); scope = null
    }
}

/** No URL fetching: local galleries cannot turn message strings into authenticated requests. */
fun localViewerImage(source: String): ViewerImage.Local? {
    val uri = if (source.startsWith('/')) Uri.fromFile(File(source)) else Uri.parse(source)
    if (uri.scheme !in setOf("content", "file", "android.resource")) return null
    return ViewerImage.Local(uri, "image/*", uri.lastPathSegment)
}
