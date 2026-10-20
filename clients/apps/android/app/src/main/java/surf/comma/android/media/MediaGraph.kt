package surf.comma.android.media

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import surf.comma.android.BuildConfig
import surf.comma.android.auth.AuthGraph
import surf.comma.android.core.CoreApi
import surf.comma.android.auth.AuthRepository
import surf.comma.android.auth.AuthState
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
    private val imageDirectory = File(app.cacheDir, "message-images")
    private val opening = Mutex()
    @Volatile private var images: MediaImageLoader? = null
    @Volatile private var covers: VideoCovers? = null

    init {
        storage.follow(auth.state, scope)
        // Before the client core downloaded them, the files were kept in each account's directory here.
        scope.launch(Dispatchers.IO) { storage.root.listFiles()?.forEach { File(it, "files").deleteRecursively() } }
        // What only exists while a loader is open is cleared by the loader itself; this covers
        // a sign-out in a process that never opened one.
        scope.launch(Dispatchers.IO) {
            auth.state.map { it is AuthState.Login || it == AuthState.Unconfigured }.filter { it }.collect {
                opening.withLock {
                    images?.clearCaches() ?: imageDirectory.deleteRecursively()
                    covers?.clear() ?: File(app.cacheDir, VIDEO_SIZES).delete()
                }
            }
        }
    }

    /** The shared picture loader for lists and the viewer. Opens on first use. */
    suspend fun images(): MediaImageLoader = images ?: opening.withLock {
        images ?: MediaImageLoader.open(app, http, files, scope, imageDirectory).also { images = it }
    }

    /** Video cover extraction and the remembered video sizes. */
    suspend fun covers(): VideoCovers = covers ?: opening.withLock {
        covers ?: VideoCovers(AspectRatioCache.open(File(app.cacheDir, VIDEO_SIZES))).also { covers = it }
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
