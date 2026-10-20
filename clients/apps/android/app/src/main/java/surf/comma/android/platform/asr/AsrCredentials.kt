package surf.comma.android.platform.asr

import surf.comma.android.BuildConfig

/**
 * What the streaming ASR endpoint needs to open a session.
 *
 * [toString] never prints the key: this object is passed around the UI layer and must be safe
 * to end up in a log line, a crash report or an exception message by accident.
 */
class AsrCredentials(
    val apiKey: String,
    val resourceId: String,
) {
    init {
        require(apiKey.isNotBlank()) { "ASR api key is blank" }
        require(resourceId.isNotBlank()) { "ASR resource id is blank" }
    }

    override fun toString(): String = "AsrCredentials(apiKey=<redacted>, resourceId=$resourceId)"
}

/**
 * Where ASR credentials come from.
 *
 * Today the only implementation reads a developer's local key compiled into debug builds.
 * Release builds will get short-lived credentials issued by the backend; that is a new
 * implementation of this interface (hence [credentials] suspends) and the composer is unchanged.
 */
interface AsrCredentialProvider {
    /** Cheap, synchronous: false means voice input is off in this build and the UI says so. */
    val isAvailable: Boolean

    /** Credentials for one new session, or null when none can be had right now. */
    suspend fun credentials(): AsrCredentials?
}

/**
 * Debug-only local key from `local.properties`, injected into `BuildConfig` of debug builds.
 * Release builds compile empty strings, so this reports unavailable there and voice degrades.
 */
class DebugLocalAsrCredentialProvider(
    private val apiKey: String = BuildConfig.DOUBAO_ASR_API_KEY,
    private val resourceId: String = BuildConfig.DOUBAO_ASR_RESOURCE_ID,
) : AsrCredentialProvider {
    override val isAvailable: Boolean get() = apiKey.isNotBlank()

    override suspend fun credentials(): AsrCredentials? {
        if (!isAvailable) return null
        return AsrCredentials(apiKey.trim(), resourceId.trim().ifEmpty { DEFAULT_RESOURCE_ID })
    }

    override fun toString(): String = "DebugLocalAsrCredentialProvider(available=$isAvailable)"

    private companion object {
        /** Hourly-billed streaming model; the default when a developer only provides a key. */
        const val DEFAULT_RESOURCE_ID = "volc.bigasr.sauc.duration"
    }
}
