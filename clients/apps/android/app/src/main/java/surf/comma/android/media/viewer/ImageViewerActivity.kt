package surf.comma.android.media.viewer

import android.animation.ValueAnimator
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
import androidx.dynamicanimation.animation.FloatPropertyCompat
import surf.comma.android.ui.theme.DesignSpring
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
 * Full-screen pictures and videos: pinch or double-tap to zoom, drag a zoomed picture, swipe between
 * pages, drag down to close, and save pictures to Photos. Each page first decodes at screen size and
 * decodes again, larger, only when zoomed in far enough to need it. A video page plays while current.
 *
 * Opened from chat tiles ([EXTRA_ROWS]), the viewer grows out of the tapped tile and closes into the
 * tile of the page it shows, which the chat reveals as the member pages ([ChatMediaLink]).
 */
class ImageViewerActivity : ComponentActivity() {
    private lateinit var items: List<ViewerImage>
    private var rows: LongArray? = null
    private lateinit var videos: ViewerVideo
    /** 0 at the source tile, 1 shown full screen; the open and close zooms spring it. */
    private var zoomProgress = 1f
    private var zoom: DesignSpring<ImageViewerActivity>? = null
    private val zoomFrom = android.graphics.RectF()
    private val zoomTo = android.graphics.RectF()
    private var zoomStartOffset = 0f
    private var hiddenTile: View? = null
    private var closing = false
    private var zoomEnd: androidx.dynamicanimation.animation.DynamicAnimation.OnAnimationEndListener? = null
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
        rows = intent.getLongArrayExtra(EXTRA_ROWS)?.takeIf { it.size == items.size }
        media = MediaGraph.get(this)
        videos = ViewerVideo(this, media)
        onBackPressedDispatcher.addCallback(this, object : androidx.activity.OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { close() }
        })
        // Pictures from the signed-in session must not outlive it.
        if (items.any { it !is ViewerImage.Local }) {
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

        val restored = savedInstanceState != null
        if (!restored) prepareOpening(root)
        lifecycleScope.launch {
            val loader = media.images()
            pager.binder = Binder(loader)
            pager.select(savedInstanceState?.getInt(STATE_INDEX) ?: intent.getIntExtra(EXTRA_INDEX, 0))
            if (!restored) pager.post { open() }
        }
    }

    override fun onStart() {
        super.onStart()
        if (::videos.isInitialized) videos.start()
    }

    override fun onStop() {
        if (::videos.isInitialized) videos.stop()
        super.onStop()
    }

    override fun onDestroy() {
        if (::videos.isInitialized) videos.hide()
        hiddenTile?.alpha = 1f
        hiddenTile = null
        super.onDestroy()
    }

    /** Until the zoom starts, the viewer shows nothing over the chat, so the tile does not flash full screen first. */
    private fun prepareOpening(root: View) {
        if (rows == null || !ValueAnimator.areAnimatorsEnabled()) return
        root.alpha = 0f
    }

    /** Grows the picture out of the tapped tile, or simply shows it when the tile is not on screen. */
    private fun open() {
        val root = pager.parent as View
        val row = rows?.getOrNull(pager.current)
        if (row == null || !ValueAnimator.areAnimatorsEnabled() || !tileRect(row, zoomFrom)) {
            root.alpha = 1f
            return
        }
        root.alpha = 1f
        hideTile(row)
        fitted(items[pager.current], zoomFrom, zoomTo)
        zoomStartOffset = 0f
        zoomProgress = 0f
        applyZoom()
        springZoom(1f) { showTile() }
    }

    /**
     * Closes into the current page's tile when the chat shows it, from wherever the drag left the picture; otherwise
     * fades out. True when the viewer is closing.
     */
    private fun close(): Boolean {
        if (closing) return true
        closing = true
        pager.freeze()
        videos.hide()
        val row = rows?.getOrNull(pager.current)
        val page = pager.page(pager.current)
        if (row == null || page == null || !ValueAnimator.areAnimatorsEnabled() || !tileRect(row, zoomFrom)) {
            finish()
            return true
        }
        page.zoom.jumpTo(ZoomState())
        hideTile(row)
        fitted(items[pager.current], zoomFrom, zoomTo)
        zoomStartOffset = pager.dismissTranslation
        zoomProgress = 1f
        springZoom(0f) {
            // Draw the tile again before the window goes, so nothing blinks.
            showTile()
            finish()
        }
        return true
    }

    private fun springZoom(target: Float, done: () -> Unit) {
        val spring = zoom ?: DesignSpring(this, ZoomProgress, DesignMotion.springSpatial, minimumVisibleChange = 0.001f).also { zoom = it }
        spring.cancel()
        zoomEnd?.let(spring.animation::removeEndListener)
        val end = androidx.dynamicanimation.animation.DynamicAnimation.OnAnimationEndListener { _, canceled, _, _ -> if (!canceled) done() }
        zoomEnd = end
        spring.animation.addEndListener(end)
        spring.animateTo(target)
        if (!spring.isRunning) done()
    }

    /**
     * Moves the pager so that the picture's fitted rectangle ([zoomTo]) sits on the tile ([zoomFrom]) at progress 0
     * and fills the screen at 1. Progress is not clamped, so the spring may overshoot.
     */
    private fun applyZoom() {
        val p = zoomProgress
        val width = pager.width.toFloat().takeIf { it > 0 } ?: return
        val height = pager.height.toFloat()
        val origin = IntArray(2).also(pager::getLocationOnScreen)
        val scaleX = zoomFrom.width() / zoomTo.width()
        val scaleY = zoomFrom.height() / zoomTo.height()
        val dx = zoomFrom.centerX() - origin[0] - zoomTo.centerX()
        val dy = zoomFrom.centerY() - origin[1] - zoomTo.centerY()
        pager.pivotX = width / 2f
        pager.pivotY = height / 2f
        // The fitted rectangle is centred in the pager, so scaling about the centre keeps it centred.
        pager.scaleX = scaleX + (1f - scaleX) * p
        pager.scaleY = scaleY + (1f - scaleY) * p
        pager.translationX = dx * (1f - p)
        pager.translationY = dy * (1f - p)
        pager.dismissTranslation = zoomStartOffset * p
        backdrop.alpha = (p.coerceIn(0f, 1f) * 255).toInt()
        chrome.alpha = if (chromeShown) p.coerceIn(0f, 1f) else 0f
    }

    /** The picture's rectangle in the pager when shown full screen: its proportions, or the tile's, fitted and centred. */
    private fun fitted(item: ViewerImage, tile: android.graphics.RectF, out: android.graphics.RectF) {
        val width = pager.width.toFloat()
        val height = pager.height.toFloat()
        val ratio = item.dimensions?.takeIf { it.width > 0 && it.height > 0 }?.let { it.width.toFloat() / it.height }
            ?: (tile.width() / tile.height())
        val fitWidth = minOf(width, height * ratio)
        val fitHeight = fitWidth / ratio
        out.set((width - fitWidth) / 2f, (height - fitHeight) / 2f, (width + fitWidth) / 2f, (height + fitHeight) / 2f)
    }

    private fun tileRect(row: Long, out: android.graphics.RectF): Boolean {
        val rect = android.graphics.Rect()
        if (!ChatMediaLink.bounds(row, rect)) return false
        out.set(rect)
        return true
    }

    /** The tile stands under the moving picture; it shows again once the picture has landed or left. */
    private fun hideTile(row: Long) {
        showTile()
        hiddenTile = ChatMediaLink.tile(row)?.also { it.alpha = 0f }
    }

    private fun showTile() {
        hiddenTile?.alpha = 1f
        hiddenTile = null
    }

    private object ZoomProgress : FloatPropertyCompat<ImageViewerActivity>("zoom") {
        override fun getValue(activity: ImageViewerActivity) = activity.zoomProgress
        override fun setValue(activity: ImageViewerActivity, value: Float) {
            activity.zoomProgress = value
            activity.applyZoom()
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
            if (items[index] is ViewerImage.Video) {
                // Only the current page reads and plays its video ([onPageSelected]).
                page.zoom.onSettled = null
                if (index == pager.current) videos.show(page, items[index] as ViewerImage.Video)
                return
            }
            page.zoom.onSettled = { state -> sharpen(page, load, state.scale) }
            // The chat tile's picture stands in until the full decode replaces its pixels in place.
            rows?.getOrNull(index)?.let { row ->
                ChatMediaLink.picture(row, resources)?.let { page.zoom.setDrawable(it, items[index].dimensions) }
            }
            decode(page, load, level = 1)
        }

        override fun unbind(page: ViewerPage, index: Int) {
            if (items[index] is ViewerImage.Video && index == pager.current) videos.hide()
            page.job?.cancel()
            page.job = null
            page.tag = null
            page.zoom.onSettled = null
        }

        private var paged = false

        override fun onPageSelected(index: Int) {
            counter.text = getString(R.string.media_viewer_counter, index + 1, items.size)
            counter.visibility = if (items.size > 1) View.VISIBLE else View.GONE
            val item = items[index]
            save.visibility = if (item is ViewerImage.Video) View.GONE else View.VISIBLE
            val page = pager.page(index)
            if (item is ViewerImage.Video && page != null) videos.show(page, item) else videos.hide()
            // Paging brings the page's tile into the chat underneath, so closing can return to it. The page the viewer
            // opens on came from its tile, which stays where it is.
            if (paged) rows?.getOrNull(index)?.let { row -> ChatMediaLink.reveal?.invoke(row) }
            paged = true
        }

        override fun onDismissRequested(velocityY: Float): Boolean = close()

        override fun onDismissProgress(fraction: Float) {
            // The zoom owns the backdrop while it runs.
            if (zoom?.isRunning == true || closing) return
            dismissFraction = fraction
            backdrop.alpha = ((1f - fraction) * 255).toInt().coerceIn(0, 255)
            applyChromeAlpha()
        }

        override fun onDismissed() = finish()

        override fun onTap() {
            if (items[pager.current] is ViewerImage.Video && videos.tap()) return
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
            addView(button(R.drawable.ic_media_close, R.string.media_viewer_close, Gravity.TOP or Gravity.START) { close() })
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
            is ViewerImage.Video -> throw java.io.IOException("Videos are not saved to Photos")
        }
    }

    companion object {
        private const val EXTRA_ITEMS = "surf.comma.android.media.viewer.ITEMS"
        private const val EXTRA_INDEX = "surf.comma.android.media.viewer.INDEX"
        private const val EXTRA_ROWS = "surf.comma.android.media.viewer.ROWS"
        private const val STATE_INDEX = "index"

        fun intent(context: Context, items: List<ViewerImage>, index: Int = 0): Intent {
            require(items.isNotEmpty() && index in items.indices)
            return Intent(context, ImageViewerActivity::class.java)
                .putParcelableArrayListExtra(EXTRA_ITEMS, ArrayList(items.map(ViewerImageBundles::write)))
                .putExtra(EXTRA_INDEX, index)
        }

        fun start(context: Context, items: List<ViewerImage>, index: Int = 0) =
            context.startActivity(intent(context, items, index))

        /**
         * Opens a chat's media: [rows] names each item's timeline row, whose tile ([ChatMediaLink]) the viewer zooms
         * from and back to.
         */
        fun startFromChat(context: Context, items: List<ViewerImage>, rows: List<Long>, index: Int) {
            require(rows.size == items.size)
            context.startActivity(intent(context, items, index).putExtra(EXTRA_ROWS, rows.toLongArray()))
        }
    }
}
