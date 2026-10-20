package surf.comma.android.media.viewer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.media.MediaComponents
import surf.comma.android.media.MediaGraph
import surf.comma.android.media.MediaImageLoader
import surf.comma.android.media.ViewerImage
import surf.comma.android.media.ViewerImageBundles
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignTypography

/**
 * Full-screen pictures: pinch or double-tap to zoom, drag a zoomed picture, swipe between
 * pictures, drag down to close, and save to Photos. Each page first decodes at screen size and
 * decodes again, larger, only when zoomed in far enough to need it.
 */
class ImageViewerActivity : ComponentActivity() {
    private lateinit var items: List<ViewerImage>
    private lateinit var media: MediaComponents
    private lateinit var pager: ImageViewerLayout
    private lateinit var backdrop: ColorDrawable
    private lateinit var chrome: View
    private lateinit var counter: TextView
    private lateinit var save: ImageButton
    private var chromeShown = true
    private var dismissFraction = 0f
    private var saving = false

    /** Per page: the decode level on screen, and whether it already holds every source pixel. */
    private class PageLoad(val index: Int) {
        var level = 0
        var complete = false
        var failed = false
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Light system-bar icons on the dark backdrop, in either theme.
        enableEdgeToEdge(SystemBarStyle.dark(android.graphics.Color.TRANSPARENT), SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        super.onCreate(savedInstanceState)
        overrideActivityTransition(Activity.OVERRIDE_TRANSITION_OPEN, android.R.anim.fade_in, 0)
        overrideActivityTransition(Activity.OVERRIDE_TRANSITION_CLOSE, 0, android.R.anim.fade_out)
        @Suppress("DEPRECATION")
        items = intent.getParcelableArrayListExtra<Bundle>(EXTRA_ITEMS).orEmpty().map { ViewerImageBundles.read(it) ?: return finish() }
        if (items.isEmpty()) return finish()
        media = MediaGraph.get(this)
        // Pictures from the signed-in session must not outlive it.
        if (items.any { it is ViewerImage.Remote }) {
            val session = media.http.session.value ?: return finish()
            lifecycleScope.launch {
                media.http.session.drop(1).first { it != session }
                finish()
            }
        }

        val root = FrameLayout(this)
        backdrop = ColorDrawable(getColor(R.color.token_bg_overlay))
        root.background = backdrop
        pager = ImageViewerLayout(this)
        root.addView(pager, FrameLayout.LayoutParams(-1, -1))
        chrome = buildChrome()
        root.addView(chrome, FrameLayout.LayoutParams(-1, -1))
        setContentView(root)
        ViewCompat.setOnApplyWindowInsetsListener(chrome) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.updatePadding(left = bars.left, top = bars.top, right = bars.right, bottom = bars.bottom)
            insets
        }

        lifecycleScope.launch {
            val loader = media.images()
            pager.binder = Binder(loader)
            pager.select(savedInstanceState?.getInt(STATE_INDEX) ?: intent.getIntExtra(EXTRA_INDEX, 0))
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        if (::pager.isInitialized) outState.putInt(STATE_INDEX, pager.current)
    }

    private inner class Binder(private val loader: MediaImageLoader) : ImageViewerLayout.PageBinder {
        override val count get() = items.size

        override fun bind(page: ViewerPage, index: Int) {
            val load = PageLoad(index)
            page.tag = load
            page.message.visibility = View.GONE
            page.zoom.onSettled = { state -> sharpen(page, load, state.scale) }
            decode(page, load, level = 1)
        }

        override fun unbind(page: ViewerPage, index: Int) {
            page.job?.cancel()
            page.job = null
            page.tag = null
            page.zoom.onSettled = null
        }

        override fun onPageSelected(index: Int) {
            counter.text = getString(R.string.media_viewer_counter, index + 1, items.size)
            counter.visibility = if (items.size > 1) View.VISIBLE else View.GONE
        }

        override fun onDismissProgress(fraction: Float) {
            dismissFraction = fraction
            backdrop.alpha = ((1f - fraction) * 255).toInt().coerceIn(0, 255)
            applyChromeAlpha()
        }

        override fun onDismissed() = finish()

        override fun onTap() {
            val page = pager.page(pager.current)
            val load = page?.tag as? PageLoad
            if (page != null && load?.failed == true) {
                decode(page, load, level = 1)
                return
            }
            chromeShown = !chromeShown
            chrome.animate().cancel()
            chrome.animate().alpha(if (chromeShown) 1f - dismissFraction else 0f)
                .setDuration(DesignMotion.durationMillis(DesignMotion.stateChange)).setInterpolator(DesignMotion.softInOut)
                .withEndAction { chrome.visibility = if (chromeShown) View.VISIBLE else View.INVISIBLE }
                .start()
            if (chromeShown) chrome.visibility = View.VISIBLE
        }

        private fun sharpen(page: ViewerPage, load: PageLoad, scale: Float) {
            val level = ZoomResolution.level(scale)
            if (!load.complete && !load.failed && level > load.level && page.job?.isActive != true) decode(page, load, level)
        }

        private fun decode(page: ViewerPage, load: PageLoad, level: Int) {
            page.job?.cancel()
            load.failed = false
            page.message.visibility = View.GONE
            val item = items[load.index]
            page.job = lifecycleScope.launch {
                val width = pager.width.takeIf { it > 0 } ?: resources.displayMetrics.widthPixels
                val height = pager.height.takeIf { it > 0 } ?: resources.displayMetrics.heightPixels
                val box = ZoomResolution.box(width, height, level, maxDecodePixels(width, height))
                try {
                    val drawable = loader.load(item, box.width, box.height)
                    if (page.tag !== load) return@launch
                    page.zoom.setDrawable(drawable, item.dimensions)
                    page.zoom.startAnimation(load.index == pager.current)
                    load.level = level
                    load.complete = ZoomResolution.reachedSource(drawable.intrinsicWidth, drawable.intrinsicHeight, box)
                    // The user may have zoomed further while this decode ran; check once it has ended.
                    page.post { if (page.tag === load) sharpen(page, load, page.zoom.state.scale) }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    if (page.tag !== load) return@launch
                    // A sharper decode failing keeps the picture already on screen.
                    if (page.zoom.drawable == null) {
                        load.failed = true
                        page.message.setText(R.string.media_viewer_load_failed)
                        page.message.visibility = View.VISIBLE
                    }
                }
            }
        }
    }

    /** Four screens' worth, and never more than the upload limit's 16 MP. */
    private fun maxDecodePixels(width: Int, height: Int) = minOf(width.toLong() * height * 4, 16_000_000L)

    private fun buildChrome(): View {
        val density = resources.displayMetrics.density
        val size = (44 * density).toInt()
        val padding = (10 * density).toInt()
        val tint = android.content.res.ColorStateList.valueOf(getColor(android.R.color.white))
        fun button(icon: Int, label: Int, gravity: Int, action: (View) -> Unit) = ImageButton(this).apply {
            setImageResource(icon)
            imageTintList = tint
            background = null
            setPadding(padding, padding, padding, padding)
            contentDescription = getString(label)
            setOnClickListener(action)
            layoutParams = FrameLayout.LayoutParams(size, size, gravity).apply {
                val margin = (8 * density).toInt()
                setMargins(margin, margin, margin, margin)
            }
        }
        counter = TextView(this).apply {
            DesignTypography.applyTo(this, DesignTypography.Level.SMALL, DesignFonts.medium)
            setTextColor(getColor(android.R.color.white))
            layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, size, Gravity.TOP or Gravity.CENTER_HORIZONTAL)
                .apply { topMargin = (8 * density).toInt() }
            gravity = Gravity.CENTER
        }
        save = button(R.drawable.ic_media_save, R.string.media_viewer_save, Gravity.TOP or Gravity.END) { saveCurrent() }
        return FrameLayout(this).apply {
            addView(button(R.drawable.ic_media_close, R.string.media_viewer_close, Gravity.TOP or Gravity.START) { finish() })
            addView(counter)
            addView(save)
        }
    }

    private fun applyChromeAlpha() {
        if (chromeShown) chrome.alpha = 1f - dismissFraction
    }

    private fun saveCurrent() {
        if (saving) return
        val item = items.getOrNull(pager.current) ?: return
        saving = true
        save.isEnabled = false
        lifecycleScope.launch {
            val saved = try {
                save(item)
                true
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                false
            } finally {
                saving = false
                save.isEnabled = true
            }
            Toast.makeText(this@ImageViewerActivity,
                if (saved) R.string.media_viewer_saved else R.string.media_viewer_save_failed, Toast.LENGTH_SHORT).show()
        }
    }

    /** The original bytes, not the on-screen decode. */
    private suspend fun save(item: ViewerImage) {
        val name = item.fileName ?: "image"
        when (item) {
            is ViewerImage.Remote -> media.images().withOriginal(item.image) { file ->
                media.gallery.saveImage(name, item.mime) { file.inputStream() }
            }
            is ViewerImage.Local -> media.gallery.saveImage(name, item.mime) {
                contentResolver.openInputStream(item.uri) ?: throw java.io.IOException("Cannot read image")
            }
        }
    }

    companion object {
        private const val EXTRA_ITEMS = "surf.comma.android.media.viewer.ITEMS"
        private const val EXTRA_INDEX = "surf.comma.android.media.viewer.INDEX"
        private const val STATE_INDEX = "index"

        fun intent(context: Context, items: List<ViewerImage>, index: Int = 0): Intent {
            require(items.isNotEmpty() && index in items.indices)
            return Intent(context, ImageViewerActivity::class.java)
                .putParcelableArrayListExtra(EXTRA_ITEMS, ArrayList(items.map(ViewerImageBundles::write)))
                .putExtra(EXTRA_INDEX, index)
        }

        fun start(context: Context, items: List<ViewerImage>, index: Int = 0) =
            context.startActivity(intent(context, items, index))
    }
}
