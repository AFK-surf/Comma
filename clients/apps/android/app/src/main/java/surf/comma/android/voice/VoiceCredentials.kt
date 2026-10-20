package surf.comma.android.voice

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONObject
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreError
import java.io.IOException

interface VoiceCredentials {
    suspend fun endpoint(): VoiceEndpoint
    suspend fun invalidate()
}

/** No generated string/copy/component methods can accidentally expose the bearer. */
class VoiceEndpoint(val sessionsUrl: String, val readinessUrl: String, val bearer: String) {
    init {
        require(validUrl(sessionsUrl, socket = true) && validUrl(readinessUrl, socket = false)) { "Invalid voice endpoint" }
        require(bearer.isNotEmpty() && bearer.length <= 16_384 && bearer.all { it in '!'..'~' }) { "Invalid voice credential" }
    }
    override fun toString() = "VoiceEndpoint([redacted])"

    private fun validUrl(value: String, socket: Boolean): Boolean {
        val normalized = if (socket) value.replaceFirst(Regex("^ws:"), "http:").replaceFirst(Regex("^wss:"), "https:") else value
        val url = normalized.toHttpUrlOrNull() ?: return false
        return url.username.isEmpty() && url.password.isEmpty() && url.query == null && url.fragment == null
    }
}

class VoiceFailure(val result: CallResult) : IOException("Voice request failed ($result)")

/** Whom a voice key is for: the signed-in account's session, in its workspace. */
internal data class VoiceAccess(val accountId: String, val sessionId: String, val workspaceId: String)

/**
 * Thirty-day device key, made through the client core (`voice.createKey`) and replaced before a call when fewer than
 * three days remain. A key this phone no longer uses is deleted at once (`voice.deleteKey`); one that cannot be
 * deleted then (offline) ends on its own when it expires, and this phone no longer holds it.
 */
class VoiceKeyCredentials internal constructor(
    private val core: CoreApi,
    private val store: VoiceKeyStore,
    private val access: () -> VoiceAccess?,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) : VoiceCredentials {
    private val mutex = Mutex()
    private var issued: VoiceKeyRecord? = null

    override suspend fun endpoint(): VoiceEndpoint = mutex.withLock {
        try {
            val owner = access() ?: throw VoiceFailure(CallResult.CredentialsExpired)
            val saved = store.read()
            val cached = saved?.takeIf {
                it.accountId == owner.accountId && it.sessionId == owner.sessionId && it.workspaceId == owner.workspaceId
            }
            if (cached != null && cached.expiresAt > nowMillis() / 1000 + RENEW_SECONDS) {
                issued = cached
                return@withLock cached.endpoint
            }
            // Once a mint starts, its one-time answer is taken even if the caller hangs up, so the key is not lost.
            withContext(NonCancellable) { mint(owner, saved) }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) {
            currentCoroutineContext().ensureActive()
            throw when (e) {
                is VoiceFailure -> e
                is CoreError -> VoiceFailure(e.status?.let(VoiceProtocol::result) ?: CallResult.Unavailable)
                else -> VoiceFailure(CallResult.Unavailable)
            }
        }
    }

    private suspend fun mint(owner: VoiceAccess, saved: VoiceKeyRecord?): VoiceEndpoint {
        val expiry = nowMillis() / 1000 + LIFETIME_SECONDS
        val json = core.call("voice.createKey", JSONObject().put("workspace", owner.workspaceId)
            .put("name", "Android voice calls").put("expiresAt", expiry)) as? JSONObject
            ?: throw VoiceFailure(CallResult.Unavailable)
        val keyId = json.optString("key_id")
        val record = try {
            val expiresAt = json.getLong("expires_at")
            require(keyId.isNotEmpty() && expiresAt > nowMillis() / 1000 && expiresAt <= expiry)
            VoiceKeyRecord(owner.accountId, owner.sessionId, owner.workspaceId, keyId, expiresAt,
                VoiceEndpoint(json.getString("sessions_url"), json.getString("readiness_url"), json.getString("key")))
        } catch (_: Exception) {
            if (keyId.isNotEmpty()) delete(owner.workspaceId, keyId)
            throw VoiceFailure(CallResult.Unavailable)
        }
        // The account or its session changed while the key was made: it is no one's here.
        if (access() != owner) {
            delete(record.workspaceId, record.keyId)
            throw VoiceFailure(CallResult.CredentialsExpired)
        }
        try {
            store.write(record)
        } catch (e: Exception) {
            delete(record.workspaceId, record.keyId)
            throw e
        }
        saved?.let { delete(it.workspaceId, it.keyId) }
        issued = record
        return record.endpoint
    }

    override suspend fun invalidate() = mutex.withLock {
        val record = issued ?: return@withLock
        issued = null
        if (store.read()?.keyId != record.keyId) return@withLock
        store.clear()
        withContext(NonCancellable) { delete(record.workspaceId, record.keyId) }
    }

    /** Deletes this phone's key at the server, before the session that made it ends; the phone forgets it either way. */
    internal suspend fun retire() = mutex.withLock {
        val record = runCatching { store.read() }.getOrNull()
        issued = null
        runCatching { store.clear() }
        if (record != null) withContext(NonCancellable) { delete(record.workspaceId, record.keyId) }
    }

    private suspend fun delete(workspaceId: String, keyId: String) {
        try {
            core.call("voice.deleteKey", JSONObject().put("workspace", workspaceId).put("key", keyId))
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // It expires on its own; nothing here holds it any more.
        }
    }

    companion object {
        internal const val LIFETIME_SECONDS = 30 * 24 * 60 * 60L
        internal const val RENEW_SECONDS = 3 * 24 * 60 * 60L
    }
}
