package surf.comma.android.media

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.StateFlow
import okhttp3.HttpUrl

/**
 * Supplied by the authentication owner. Publish null before logout, and a new immutable
 * snapshot with a new generation on every account/group change. Clients must be bound to that snapshot's session:
 * an old client must never start using a new account's credentials. No token is exposed here.
 */
interface AuthorizedHttp {
    val session: StateFlow<AuthorizedSession?>

    /**
     * False as soon as the owner has ended [session]'s login, even if [session] has not yet
     * published the replacement. Checked before any progress or result is delivered.
     */
    fun isCurrent(session: AuthorizedSession): Boolean = true
}

data class MediaSessionId(val accountId: String, val generation: String, val groupId: String) {
    init { require(accountId.isNotBlank() && generation.isNotBlank() && groupId.isNotBlank()) }
}

/** [generation] is a unique session epoch, including across process restarts and re-login. */
data class AuthorizedSession(
    val id: MediaSessionId,
    val baseUrl: HttpUrl,
) {
    val generation: String get() = id.generation
}

internal fun AuthorizedHttp.requireCurrent(expected: AuthorizedSession) {
    if (session.value != expected || !isCurrent(expected)) throw CancellationException("Media session changed")
}
