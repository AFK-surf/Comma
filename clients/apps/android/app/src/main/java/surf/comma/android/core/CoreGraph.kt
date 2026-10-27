package surf.comma.android.core

import android.content.Context
import android.util.Log
import okhttp3.OkHttpClient
import surf.comma.android.BuildConfig
import surf.comma.android.conversation.SyncDiagnostics
import surf.comma.android.media.PickedLocalFiles
import java.io.File
import java.util.concurrent.TimeUnit

/** The process's client core and what it keeps for it. One per process; it outlives every Activity. */
internal class CoreRuntime(val core: CommaCore, val host: CoreHost, val custody: SessionCustody)

/**
 * Builds the process's client core: Hermes running the shared TypeScript core, its requests and databases in this
 * app, the bearer in [SessionCustody].
 */
internal object CoreGraph {
    @Volatile private var runtime: CoreRuntime? = null

    /**
     * The running core. [baseUrl] is the Comma API's origin, [sealer] encrypts the credential file, [google] is the
     * account chooser the core's Google sign-in asks. [adoptEarlier] runs once, before the core starts, with the new
     * credential store: an earlier version's session moves into it there.
     */
    fun get(
        context: Context,
        baseUrl: String,
        sealer: Sealer,
        google: GoogleIdTokens,
        networkFailure: (Throwable?, Int?) -> Unit = { _, _ -> },
        adoptEarlier: (SessionCustody) -> Unit = {},
    ): CoreRuntime = runtime ?: synchronized(this) {
        runtime ?: create(context.applicationContext, baseUrl, sealer, google, networkFailure, adoptEarlier).also { runtime = it }
    }

    /** Where the core's downloads are written: the only place the video player and the file provider take them from. */
    fun downloads(context: Context) = File(context.noBackupFilesDir, "core-downloads")

    private fun create(
        context: Context,
        baseUrl: String,
        sealer: Sealer,
        google: GoogleIdTokens,
        networkFailure: (Throwable?, Int?) -> Unit,
        adoptEarlier: (SessionCustody) -> Unit,
    ): CoreRuntime {
        val custody = SessionCustody(File(context.noBackupFilesDir, "credentials.bin"), sealer, baseUrl)
        runCatching { adoptEarlier(custody) }
        val client = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .apply { SyncDiagnostics.interceptor()?.let(::addNetworkInterceptor) }
            .build()
        // The core bounds the downloads itself and keeps an index of them: they are not a cache the system may clear.
        val host = CoreHost(client, custody, File(context.noBackupFilesDir, "core"), google,
            HostDownloads(downloads(context)), networkFailure = networkFailure,
            localFiles = PickedLocalFiles.host(context.contentResolver), appVersion = BuildConfig.VERSION_NAME)
        val script by lazy { context.assets.open(CORE_SCRIPT).use { it.readBytes() } }
        val core = CommaCore(
            engines = { config, engineHost -> HermesEngine(script, config, engineHost) },
            host = host,
            onFault = { reason -> Log.e("CommaCore", reason) },
        )
        return CoreRuntime(core, host, custody)
    }
}
