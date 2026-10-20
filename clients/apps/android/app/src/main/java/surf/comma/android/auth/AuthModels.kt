package surf.comma.android.auth

/** Secrets deliberately have no generated toString/copy/component methods. */
class SessionToken(val value: String) {
    init { require(value.isNotEmpty() && value.length <= 16_384 && value.all { it in '!'..'~' }) { "Invalid session credential" } }
    override fun toString() = "SessionToken([redacted])"
}

/**
 * The connected account's main chat for one session generation, as other modules see it.
 * It never carries the credential.
 */
class ConversationScope internal constructor(
    val generation: Long,
    val accountId: String,
    val groupId: String,
    val conversationId: String,
    /** The workspace the chat belongs to; empty when the scope's maker did not say. */
    val workspaceId: String = "",
) {
    override fun toString() = "ConversationScope(generation=$generation)"
}

data class Account(val id: String, val email: String, val name: String?, val status: String)
data class Session(val token: SessionToken, val expiresAt: Long, val sessionId: String, val user: Account)
data class Workspace(val id: String, val groupId: String, val name: String)
data class WorkspaceSelection(val workspace: Workspace, val chatId: String)

interface SessionStore {
    fun read(): Session?
    fun write(session: Session)
    fun clear()
}

enum class AuthProblem {
    NETWORK, EMAIL_UNAVAILABLE, RATE_LIMITED, INVALID_CODE, SERVER, STORAGE, NO_WORKSPACE,
    /** The account exists but is disabled (403). */
    ACCOUNT_DISABLED,
    /** The backend has no Google sign-in for Android yet (`google_not_configured`). */
    GOOGLE_NOT_CONFIGURED,
    /** The device has no Google account to choose. */
    GOOGLE_NO_ACCOUNT,
    /** No Google Play services or credential provider on this device. */
    GOOGLE_UNAVAILABLE,
    /** Google or the backend did not accept the credential (`invalid_google_credential` and kin). */
    GOOGLE_REJECTED,
    /** The Google account belongs to a different Comma account, or the link changed meanwhile (409). */
    GOOGLE_CONFLICT,
}
enum class ConnectionStep { SESSION, WORKSPACE, PROVISIONING }
sealed interface AuthState {
    data object Starting : AuthState
    data object Unconfigured : AuthState
    data class Login(
        val email: String = "",
        val challengeId: String? = null,
        val resendAtMillis: Long = 0,
        val verifyAtMillis: Long = 0,
        val busy: Boolean = false,
        val problem: AuthProblem? = null,
        /** A Google sign-in is in flight: the chooser is up or the backend is checking the token. */
        val googleBusy: Boolean = false,
        /** Why the last Google sign-in did not finish, shown by the Google button. */
        val googleProblem: AuthProblem? = null,
        /** [challengeId] links a Google account to an existing one; the code goes to the link endpoint. */
        val linkingGoogle: Boolean = false,
    ) : AuthState
    data class Connecting(val step: ConnectionStep, val retryAtMillis: Long = 0) : AuthState
    data class Retry(val problem: AuthProblem) : AuthState
    data class Connected(val account: Account, val selection: WorkspaceSelection) : AuthState
}
