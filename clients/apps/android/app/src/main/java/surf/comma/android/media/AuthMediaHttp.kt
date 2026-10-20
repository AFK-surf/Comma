package surf.comma.android.media

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import surf.comma.android.auth.AuthRepository
import surf.comma.android.auth.ConversationScope
import surf.comma.android.ui.Background

/**
 * Media requests on the signed-in session. Each snapshot's client tags every request with its own
 * [ConversationScope], so the session owner adds that generation's credential and refuses the
 * request, or its response, once the generation has ended. This class never sees the credential.
 *
 * The snapshot's generation is the account's media epoch from [epochFor], not the process-local
 * login counter: it stays the same across process restarts while the account stays signed in (so
 * persistent caches keep hitting) and is new after every sign-out, because signing out deletes it.
 */
class AuthMediaHttp internal constructor(
    private val scopes: StateFlow<ConversationScope?>,
    private val generationIsCurrent: (Long) -> Boolean,
    private val baseUrl: HttpUrl?,
    private val epochFor: suspend (accountId: String) -> String,
    parentScope: CoroutineScope,
) : AuthorizedHttp {
    constructor(auth: AuthRepository, baseUrl: String, storage: MediaAccountStorage, parentScope: CoroutineScope) : this(
        auth.conversationScope, auth::isCurrentGeneration, baseUrl.toHttpUrlOrNull(),
        storage::epoch, parentScope,
    )

    private class Bound(val session: AuthorizedSession, val scope: ConversationScope)

    private val lock = Any()
    @Volatile private var bound: Bound? = null
    private val mutableSession = MutableStateFlow<AuthorizedSession?>(null)
    override val session: StateFlow<AuthorizedSession?> = mutableSession.asStateFlow()

    init {
        // Unconfined: a sign-out reaches media callers in the same call that ends the login.
        parentScope.launch(Dispatchers.Unconfined) {
            scopes.collectLatest { scope ->
                if (scope == null || baseUrl == null) {
                    publish(null)
                    return@collectLatest
                }
                if (bound?.scope !== scope) publish(null)
                val epoch = try {
                    withContext(Background.files) { epochFor(scope.accountId) }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    return@collectLatest // Without a cache identity, media stays unavailable.
                }
                val next = AuthorizedSession(MediaSessionId(scope.accountId, epoch, scope.groupId), baseUrl)
                synchronized(lock) {
                    if (scopes.value === scope && generationIsCurrent(scope.generation)) {
                        bound = Bound(next, scope)
                        mutableSession.value = next
                    }
                }
            }
        }
    }

    override fun isCurrent(session: AuthorizedSession): Boolean {
        val current = bound ?: return false
        return current.session === session && scopes.value === current.scope && generationIsCurrent(current.scope.generation)
    }

    private fun publish(value: AuthorizedSession?) = synchronized(lock) {
        if (value == null) bound = null
        mutableSession.value = value
    }
}
