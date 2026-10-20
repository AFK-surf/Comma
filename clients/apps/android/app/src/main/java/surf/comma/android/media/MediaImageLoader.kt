package surf.comma.android.media

import android.content.Context
import android.graphics.drawable.Animatable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import surf.comma.android.R
import surf.comma.android.ui.Background
import android.widget.ImageView
import androidx.annotation.MainThread
import coil3.ImageLoader
import coil3.asDrawable
import coil3.gif.AnimatedImageDecoder
import coil3.memory.MemoryCache
import coil3.request.ErrorResult
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.size.Precision
import coil3.size.Scale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

/** Shared by a list/screen owner. Open once per cache directory; close after closing bindings. */
class MediaImageLoader private constructor(
    private val context: Context,
    private val authorizedHttp: AuthorizedHttp,
    files: MediaFileStore,
    internal val ratios: AspectRatioCache,
    parentScope: CoroutineScope,
    memoryBytes: Long,
) : AutoCloseable {
    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob(parentScope.coroutineContext[Job]) + Dispatchers.Main.immediate)
    private val fastScrolling = MutableStateFlow(false)
    private val fetchers = MediaImageFetcherFactory(authorizedHttp, files, ratios)
    private val imageLoader = ImageLoader.Builder(context)
        // Fetching and decoding run where the app's file work runs: Coil's own IO threads in the app, in place in
        // unit tests, so a test decides when a picture is there.
        .coroutineContext(Background.files)
        .memoryCache { MemoryCache.Builder().maxSizeBytes(memoryBytes).weakReferencesEnabled(false).build() }
        .components {
            add(fetchers)
            add(AnimatedImageDecoder.Factory())
        }
        .build()
    private val bindings = mutableSetOf<MediaImageBinding>()
    private class LocalLoad { val mutex = Mutex(); var users = 0 }
    // Only active URI requests, never bitmap storage. A waiter rechecks Coil's bounded cache
    // after the first decode, so identical attachments don't allocate/upload duplicate pixels.
    private val localLoads = HashMap<android.net.Uri, LocalLoad>()

    private suspend fun <T> serialLocal(uri: android.net.Uri, block: suspend () -> T): T {
        val entry = synchronized(localLoads) { localLoads.getOrPut(uri, ::LocalLoad).also { it.users++ } }
        try { return entry.mutex.withLock { block() } }
        finally { synchronized(localLoads) { if (--entry.users == 0) localLoads.remove(uri) } }
    }

    init {
        // Keys already separate accounts; this also keeps one account's pictures off the disk
        // once it has signed out or another account has signed in.
        scope.launch {
            var account: String? = null
            authorizedHttp.session.collect { current ->
                val next = current?.id?.accountId
                if (account != null && next != account) clearCaches()
                if (next != null) account = next else if (current == null) account = null
            }
        }
    }

    /** Forget every decoded picture and size. The originals are the client core's, kept per account. */
    suspend fun clearCaches() {
        imageLoader.memoryCache?.clear()
        withContext(Background.files) { ratios.clear() }
    }

    /**
     * One decode of [image] fitted inside [widthPx]×[heightPx], never above the source's own size.
     * The image viewer asks again with a larger box as the user zooms in.
     */
    suspend fun load(image: ViewerImage, widthPx: Int, heightPx: Int): Drawable =
        if (image is ViewerImage.Local) serialLocal(image.uri) { decode(image, widthPx, heightPx) }
        else decode(image, widthPx, heightPx)

    private suspend fun decode(image: ViewerImage, widthPx: Int, heightPx: Int): Drawable {
        require(widthPx > 0 && heightPx > 0)
        val session = if (image is ViewerImage.Remote) checkNotNull(authorizedHttp.session.value) { "No authorized media session" } else null
        val builder = ImageRequest.Builder(context).size(widthPx, heightPx).precision(Precision.INEXACT).scale(Scale.FIT)
        when (image) {
            is ViewerImage.Remote -> {
                val data = AuthorizedImage(session!!, image.image)
                builder.data(data).memoryCacheKey("${data.key}:${image.image.mime}:${widthPx}x$heightPx")
            }
            // Let Coil validate the cached decode against the requested size. A fully decoded
            // preview (or a larger existing decode) can satisfy the row without decoding twice.
            is ViewerImage.Local -> builder.data(image.uri).memoryCacheKey("local:${image.uri}")
        }
        return when (val result = imageLoader.execute(builder.build())) {
            is SuccessResult -> {
                session?.let(authorizedHttp::requireCurrent)
                result.image.asDrawable(context.resources)
            }
            is ErrorResult -> throw result.throwable
        }
    }

    /** Runs [block] on the verified original file, downloading it first if needed. */
    suspend fun <T> withOriginal(image: MediaImage, block: suspend (File) -> T): T {
        val session = checkNotNull(authorizedHttp.session.value) { "No authorized media session" }
        return block(fetchers.original(AuthorizedImage(session, image)).first)
    }

    /** Cancel active loads during a fling. Visible pending images restart when it ends. */
    @MainThread fun setFastScrolling(value: Boolean) { fastScrolling.value = value }

    /** Read metadata before preparing row geometry; a load never changes an existing row. */
    fun dimensions(source: MediaSource): ImageDimensions? = authorizedHttp.session.value
        ?.takeIf(authorizedHttp::isCurrent)?.let { ratios.get(mediaCacheKey(it, source)) }

    suspend fun remember(image: UploadedImage, session: AuthorizedSession? = authorizedHttp.session.value) {
        if (session == null) return
        authorizedHttp.requireCurrent(session)
        ratios.put(mediaCacheKey(session, MediaSource.UploadedFile(image.path)), image.dimensions)
        // A logout racing the write must not leave metadata behind after cache cleanup.
        if (!authorizedHttp.isCurrent(session)) ratios.clear()
    }

    @MainThread
    fun bind(
        view: ImageView,
        image: MediaImage,
        widthPx: Int,
        visible: Boolean = false,
        fallbackRatio: Double = 1.0,
        onError: (Throwable) -> Unit = {},
    ): MediaImageBinding = bind(view, ViewerImage.Remote(image), widthPx, visible, fallbackRatio, onError)

    /** Local draft/fixture pictures and remote attachments share Coil, sizing and visibility. */
    @MainThread
    fun bind(
        view: ImageView,
        image: ViewerImage,
        widthPx: Int,
        visible: Boolean = false,
        fallbackRatio: Double = 1.0,
        onError: (Throwable) -> Unit = {},
    ): MediaImageBinding {
        val session = authorizedHttp.session.value
        if (image is ViewerImage.Remote) checkNotNull(session) { "No authorized media session" }
        val known = image.dimensions ?: (image as? ViewerImage.Remote)?.image?.source?.let(::dimensions)
        val placeholder = ImagePlaceholder.reserve(widthPx, known, fallbackRatio)
        if (view is SendImageView) {
            // Its host has fixed the exact landing aperture, including subpixel ratio rounding.
            // Keep MATCH_PARENT: recomputing height from the rounded width can lose a pixel.
            view.presentation.openBinding()
        } else {
            view.layoutParams = (view.layoutParams ?: android.view.ViewGroup.LayoutParams(placeholder.width, placeholder.height)).apply {
                width = placeholder.width
                height = placeholder.height
            }
            view.scaleType = ImageView.ScaleType.FIT_CENTER
            view.background = GradientDrawable().apply {
                setColor(view.context.getColor(R.color.token_bg_tertiary))
                cornerRadius = view.resources.getDimension(R.dimen.radius_4xl)
            }
            view.clipToOutline = true
            view.setImageDrawable(null)
        }
        return MediaImageBinding(view, placeholder).also { binding ->
            bindings += binding
            binding.onClose = { bindings -= binding }
            binding.visibility.value = visible
            binding.job = scope.launch {
                var loaded: Drawable? = null
                try {
                    combine(authorizedHttp.session, fastScrolling, binding.visibility, binding.retries) { current, fast, showing, _ ->
                        Triple(current == session && (session == null || authorizedHttp.isCurrent(session)), fast, showing)
                    }.collectLatest { (current, fast, showing) ->
                        (loaded as? Animatable)?.stop()
                        if (!current) {
                            loaded = null
                            view.setImageDrawable(null)
                            return@collectLatest
                        }
                        if (fast || !showing) return@collectLatest
                        if (loaded == null) {
                            val size = ImageSizing.fit(ImageDimensions(placeholder.width, placeholder.height))
                            try {
                                loaded = load(image, size.width, size.height)
                                session?.let(authorizedHttp::requireCurrent)
                                view.setImageDrawable(loaded)
                            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                                throw cancelled
                            } catch (error: Exception) {
                                onError(error)
                                return@collectLatest
                            }
                        }
                        (loaded as? Animatable)?.start()
                    }
                } finally {
                    (loaded as? Animatable)?.stop()
                    if (!binding.closed) view.setImageDrawable(null)
                }
            }
        }
    }

    @MainThread override fun close() {
        bindings.toList().forEach { it.close() }
        scope.cancel()
        imageLoader.shutdown()
    }

    companion object {
        /** IO includes opening the persistent ratio cache. Default: 32 MiB memory. */
        suspend fun open(
            context: Context,
            authorizedHttp: AuthorizedHttp,
            files: MediaFileStore,
            parentScope: CoroutineScope,
            directory: File = File(context.cacheDir, "message-images"),
            memoryBytes: Long = 32L * 1024 * 1024,
        ): MediaImageLoader = withContext(Background.files) {
            require(memoryBytes > 0)
            // Before the client core kept the originals, a disk cache of them was here.
            File(directory, "data").deleteRecursively()
            val ratios = AspectRatioCache.open(File(directory, "ratios.json"))
            MediaImageLoader(context.applicationContext, authorizedHttp, files, ratios, parentScope, memoryBytes)
        }
    }
}

/** Host must forward visible-viewport/lifecycle changes and close on recycle or rebind. */
class MediaImageBinding internal constructor(private val view: ImageView, val placeholder: ImagePlaceholder) : AutoCloseable {
    internal val visibility = MutableStateFlow(false)
    internal val retries = MutableStateFlow(0L)
    internal var job: Job? = null
    internal var closed = false
    internal var onClose: () -> Unit = {}
    @MainThread fun setVisible(value: Boolean) {
        if (closed) return
        if (!value) (view.drawable as? Animatable)?.stop()
        visibility.value = value
    }
    @MainThread fun retry() { retries.value++ }
    @MainThread override fun close() {
        if (closed) return
        closed = true
        job?.cancel()
        job = null
        (view.drawable as? Animatable)?.stop()
        view.setImageDrawable(null)
        onClose()
    }
}
