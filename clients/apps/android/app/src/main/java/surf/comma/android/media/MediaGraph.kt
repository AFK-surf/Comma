package surf.comma.android.media

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import surf.comma.android.BuildConfig
import surf.comma.android.auth.AuthGraph
import surf.comma.android.core.CoreApi
import surf.comma.android.auth.AuthRepository
import surf.comma.android.auth.AuthState
import surf.comma.android.ui.Background
import java.io.File

/**
 * The process's media components on the real sign-in. Every screen shares these; none of them
 * is closed by a screen. Signing out cancels their work, drops late results and deletes what
 * they cached for the account.
 */
class MediaComponents internal constructor(
    context: Context,
    auth: AuthRepository,
    core: CoreApi?,
    baseUrl: String,
    private val scope: CoroutineScope,
    /** Where the client core put a download (its path), as a file on this device. */
    downloaded: (String) -> File?,
) {
    private val app = context.applicationContext
    val storage = MediaAccountStorage(File(app.cacheDir, "media-accounts"))
    val http: AuthorizedHttp = AuthMediaHttp(auth, baseUrl, storage, scope)
    val files = MediaFileStore(http, core, downloaded, scope)
    val gallery = GallerySaver(app.contentResolver)
    private val coverDirectory = File(app.cacheDir, "video-covers")
    private val imageDirectory = File(app.cacheDir, "message-images")
    private val opening = Mutex()
    @Volatile private var images: MediaImageLoader? = null
    @Volatile private var covers: VideoCovers? = null

    init {
        storage.follow(auth.state, scope)
        // Before the client core downloaded them, the files were kept in each account's directory here.
        scope.launch(Background.files) { storage.root.listFiles()?.forEach { File(it, "files").deleteRecursively() } }
        // What only exists while a loader is open is cleared by the loader itself; this covers
        // a sign-out in a process that never opened one.
        scope.launch(Background.files) {
            var account: String? = null
            auth.state.collect { state ->
                val signedOut = state is AuthState.Login || state == AuthState.Unconfigured
                val next = (state as? AuthState.Connected)?.account?.id
                if (signedOut || (next != null && account != null && next != account)) {
                    opening.withLock {
                        images?.clearCaches() ?: imageDirectory.deleteRecursively()
                        clearCovers()
                    }
                }
                if (signedOut || next != null) account = next
            }
        }
    }

    /** The shared picture loader for lists and the viewer. Opens on first use. */
    suspend fun images(): MediaImageLoader = images ?: opening.withLock {
        images ?: MediaImageLoader.open(app, http, files, scope, imageDirectory).also { images = it }
    }

    /** Video cover extraction and the remembered video sizes. */
    suspend fun covers(): VideoCovers = covers ?: opening.withLock {
        covers ?: VideoCovers(AspectRatioCache.open(File(app.cacheDir, VIDEO_SIZES)), coverDirectory).also { covers = it }
    }

    private suspend fun clearCovers() {
        covers?.clear() ?: run {
            coverDirectory.deleteRecursively()
            File(app.cacheDir, VIDEO_SIZES).delete()
        }
    }

    private companion object { const val VIDEO_SIZES = "media-video-sizes.json" }
}

object MediaGraph {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    @Volatile private var instance: MediaComponents? = null

    fun get(context: Context): MediaComponents = instance ?: synchronized(this) {
        instance ?: MediaComponents(context, AuthGraph.get(context), AuthGraph.core(context), BuildConfig.BACKEND_BASE_URL, scope,
            AuthGraph::downloaded).also { instance = it }
    }
}
