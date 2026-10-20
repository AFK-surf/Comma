package surf.comma.android.media

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import surf.comma.android.auth.AuthState
import surf.comma.android.ui.Background
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

/**
 * Each account's media epoch, one directory per account under [root] (`<root>/<sha256(account id)>`). Signing out
 * deletes every account's directory; connecting as one account deletes the others'. The downloaded files themselves
 * are the client core's ([MediaFileStore]).
 */
class MediaAccountStorage(val root: File) {
    private val lock = Any()

    fun directory(accountId: String): File = File(root, sha256(accountId))

    /**
     * The account's media epoch; see [AuthMediaHttp]. A new epoch starts an empty directory, so
     * nothing written under an earlier sign-in can be read back under this one.
     */
    fun epoch(accountId: String): String = synchronized(lock) {
        val directory = directory(accountId)
        val file = File(directory, EPOCH)
        file.takeIf { it.isFile && it.length() in 1..64 }?.readText()?.trim()
            ?.takeIf { it.matches(Regex("[0-9a-f]{32}")) }?.let { return it }
        if (directory.exists() && !directory.deleteRecursively()) throw IOException("Cannot reset media cache")
        if (!directory.mkdirs()) throw IOException("Cannot create media cache")
        val epoch = UUID.randomUUID().toString().replace("-", "")
        val temporary = File(directory, "$EPOCH.tmp")
        temporary.writeText(epoch)
        if (!temporary.renameTo(file)) throw IOException("Cannot store media epoch")
        epoch
    }

    /** Signed out: nothing any account downloaded may stay on disk. */
    fun clearAll() = synchronized(lock) { root.deleteRecursively() }

    /** Connected as [accountId]: remove whatever other accounts left behind. */
    fun retainOnly(accountId: String) = synchronized(lock) {
        val keep = sha256(accountId)
        root.listFiles()?.filter { it.name != keep }?.forEach { it.deleteRecursively() }
    }

    /**
     * Follows the sign-in state for the life of [scope]. A process that starts signed out also
     * clears what an earlier process could not (for example after a crash during sign-out).
     */
    fun follow(states: StateFlow<AuthState>, scope: CoroutineScope) = scope.launch {
        states.collectLatest { state ->
            withContext(Background.files) {
                when (state) {
                    // A clear that runs late, after the next account signed in and made its directory, would take
                    // that directory: it clears only while still signed out.
                    is AuthState.Login, AuthState.Unconfigured -> synchronized(lock) {
                        if (signedOut(states.value)) root.deleteRecursively()
                    }
                    is AuthState.Connected -> retainOnly(state.account.id)
                    else -> Unit
                }
            }
        }
    }

    private fun signedOut(state: AuthState) = state is AuthState.Login || state == AuthState.Unconfigured

    private companion object {
        const val EPOCH = "epoch"
        fun sha256(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }
}
