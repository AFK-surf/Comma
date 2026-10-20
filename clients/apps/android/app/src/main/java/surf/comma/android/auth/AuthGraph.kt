package surf.comma.android.auth

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import surf.comma.android.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import java.io.File
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreGraph
import surf.comma.android.core.CoreRuntime
import androidx.work.WorkManager
import surf.comma.android.core.PendingRevocation
import surf.comma.android.core.Sealer
import surf.comma.android.core.SessionCustody
import surf.comma.android.core.SessionLease
import surf.comma.android.core.StoredCredential
import surf.comma.android.voice.EncryptedVoiceKeyStore

private class CredentialSealer(private val cipher: SessionCipher) : Sealer {
    override fun seal(plaintext: ByteArray): ByteArray = cipher.encrypt(plaintext)
    override fun open(sealed: ByteArray): ByteArray = cipher.decrypt(sealed)
}

private class CustodyBearers(private val runtime: CoreRuntime) : SessionBearers {
    override fun savedAccount(): Account? = runtime.custody.identity()?.let { Account(it.userId, it.email, null, "active") }
    override fun lease(): SessionLease? = runtime.custody.current()?.lease
}

private object NoBearers : SessionBearers {
    override fun savedAccount(): Account? = null
    override fun lease(): SessionLease? = null
}

/** Process-owned session state outlives Activity recreation and is never placed in a Bundle. */
object AuthGraph {
    internal var scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        private set
    @Volatile private var repository: AuthRepository? = null
    @Volatile private var runtime: CoreRuntime? = null

    /** The process's client core, once [get] built it; null in a build without a backend address. */
    fun core(context: Context): CoreApi? {
        get(context)
        return runtime?.core
    }
    fun get(context: Context): AuthRepository = repository ?: synchronized(this) {
        repository ?: create(context.applicationContext).also { repository = it }
    }

    /**
     * Gives the process [repository] in place of the one [get] builds, and [scope] for its work: a test environment's,
     * before anything asks.
     */
    internal fun install(repository: AuthRepository, scope: CoroutineScope) = synchronized(this) {
        this.repository = repository
        this.scope = scope
        runtime = null
    }

    private fun create(context: Context): AuthRepository {
        val root = context.noBackupFilesDir
        val google = GoogleChooser()
        val baseUrl = BuildConfig.BACKEND_BASE_URL
        // No backend configured (a development build without one): nothing to run a core against.
        val runtime = runCatching {
            CoreGraph.get(context, baseUrl, CredentialSealer(SessionCipher("comma.credentials.v1", ::key)), google,
                networkFailure = { error, status ->
                    NetworkDiagnostics.record(error?.let(NetworkFailure::transport) ?: NetworkFailure(NetworkFailureKind.HTTP, status))
                }) { custody ->
                adoptEarlierSession(File(root, "session.bin"), baseUrl, custody)
                adoptEarlierLogouts(context, EarlierLogouts(File(root, "pending-logouts"),
                    SessionCipher("comma.pending-logout.v1", ::key)), baseUrl, custody)
            }
        }.getOrNull()
        this.runtime = runtime
        // The core keeps the account's chat now: what this app kept of it before goes.
        runCatching { File(root, "accounts").deleteRecursively() }
        return AuthRepository(runtime?.core, runtime?.let(::CustodyBearers) ?: NoBearers, google, scope,
            voiceKeyStore = EncryptedVoiceKeyStore(File(root, "voice-key.bin"), SessionCipher("comma.voice-key.v1", ::key)))
    }

    /**
     * The session an earlier version kept in `session.bin` becomes the credential store's, so an update does not sign
     * the person out. The old file is deleted once the store has it (or has a credential of its own).
     */
    private fun adoptEarlierSession(file: File, baseUrl: String, custody: SessionCustody) {
        if (!file.exists()) return
        val earlier = runCatching { EncryptedSessionStore(file, SessionCipher(key = ::key)).read() }.getOrNull()
        if (earlier != null) custody.adoptEarlier(StoredCredential(earlier.token.value,
            SessionCustody.canonicalAudience(baseUrl), earlier.sessionId, earlier.user.id, earlier.user.email, earlier.expiresAt))
        file.delete()
    }

    /**
     * The sign-outs an earlier version still had queued become the credential store's, which the core works through,
     * and the earlier version's scheduled retries are cancelled. Kept until the store takes them.
     */
    private fun adoptEarlierLogouts(context: Context, earlier: EarlierLogouts, baseUrl: String, custody: SessionCustody) {
        val ids = earlier.ids()
        if (ids.isEmpty()) return
        val now = System.currentTimeMillis() / 1000
        val audience = SessionCustody.canonicalAudience(baseUrl)
        val tokens = ids.mapNotNull(earlier::read).filter { (_, expiresAt) -> expiresAt > now }
            .map { (token, _) -> PendingRevocation(token, audience, null) }
        if (!custody.adoptRevocations(tokens)) return
        val work = WorkManager.getInstance(context)
        ids.forEach { work.cancelUniqueWork("logout-$it") }
        earlier.delete()
    }

    /** Where the client core put a download (its path), as a file on this device; null without a core. */
    fun downloaded(path: String): java.io.File? = runtime?.host?.downloads?.file(path)

    /** Encrypts another private file with the session key under its own authenticated [purpose]. */
    internal fun cipher(purpose: String) = SessionCipher(purpose, ::key)

    @Synchronized private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    private const val KEY_ALIAS = "comma.session.aes.v1"
}
