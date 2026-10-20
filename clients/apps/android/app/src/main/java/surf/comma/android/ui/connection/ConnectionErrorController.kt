package surf.comma.android.ui.connection

import surf.comma.android.auth.AuthProblem
import surf.comma.android.auth.AuthState
import surf.comma.android.conversation.Connection
import surf.comma.android.conversation.ConversationProblem
import surf.comma.android.conversation.ConversationState

internal enum class ConnectionErrorReason {
    OFFLINE, UNREACHABLE, SERVICE, RATE_LIMITED, STORAGE, NO_WORKSPACE, CHAT_UNAVAILABLE,
}
internal enum class ConnectionRetryTarget { SESSION, CONVERSATION }
internal data class ConnectionErrorState(
    val reason: ConnectionErrorReason,
    val target: ConnectionRetryTarget,
    val busy: Boolean = false,
)

/** Presentation policy only: the repositories still own requests, backoff and session lifetimes. */
internal class ConnectionErrorController(
    private val onChanged: (ConnectionErrorState?) -> Unit,
    private val onRetry: (ConnectionRetryTarget) -> Unit,
) {
    var state: ConnectionErrorState? = null
        private set
    private var auth: AuthState = AuthState.Starting
    private var conversation: ConversationState? = null
    private var online: Boolean? = null
    private var requestedFrom: Pair<AuthState, ConversationState?>? = null

    fun present(auth: AuthState, conversation: ConversationState? = null) {
        this.auth = auth
        this.conversation = conversation
        // A fast failure can equal the previous failure after StateFlow conflates progress.
        // A fresh snapshot still ends that attempt; repeated renders of the same one do not.
        requestedFrom?.let { (requestedAuth, requestedChat) ->
            if (requestedAuth !== auth || requestedChat !== conversation) requestedFrom = null
        }
        refresh()
    }

    /** Null means connectivity is not known yet; an IO failure alone never proves offline. */
    fun connectivityChanged(available: Boolean?) {
        val restored = online == false && available == true
        online = available
        if (restored && state?.reason in AUTO_RETRY_REASONS) retry() else refresh()
    }

    fun retry() {
        val current = state ?: return
        if (current.busy) return
        requestedFrom = auth to conversation
        publish(current.copy(busy = true))
        onRetry(current.target)
    }

    /** Also handles a session retry that was ignored because the account changed meanwhile. */
    fun sessionRetryFinished() {
        requestedFrom = null
        refresh()
    }

    private fun refresh() {
        val previous = state
        val chat = conversation
        val next = when {
            // Never cover cached messages or a pending send with a full-page error.
            chat != null && (!chat.cacheLoaded || chat.timeline.isNotEmpty()) -> null
            auth is AuthState.Login || auth == AuthState.Unconfigured -> null
            auth is AuthState.Retry -> ConnectionErrorState(authReason((auth as AuthState.Retry).problem), ConnectionRetryTarget.SESSION)
            auth is AuthState.Connecting && previous?.target == ConnectionRetryTarget.SESSION -> previous.copy(busy = true)
            chat?.cacheLoaded == true && chat.connection in listOf(Connection.PAUSED, Connection.RECONNECTING) && chat.problem != null ->
                ConnectionErrorState(conversationReason(chat.problem), ConnectionRetryTarget.CONVERSATION)
            chat != null && chat.connection in listOf(Connection.CONNECTING, Connection.RECONNECTING) &&
                previous?.target == ConnectionRetryTarget.CONVERSATION -> previous.copy(busy = true)
            else -> null
        }
        // Keep both copy and geometry stable from the tap until the repository publishes progress.
        publish(if (next != null && requestedFrom != null) (previous ?: next).copy(busy = true) else next)
    }

    private fun networkReason(server: Boolean) = when {
        online == false -> ConnectionErrorReason.OFFLINE
        server -> ConnectionErrorReason.SERVICE
        else -> ConnectionErrorReason.UNREACHABLE
    }

    private fun authReason(problem: AuthProblem) = when (problem) {
        AuthProblem.NETWORK -> networkReason(server = false)
        // The auth layer uses EMAIL_UNAVAILABLE for HTTP 503 even during session validation.
        AuthProblem.SERVER, AuthProblem.EMAIL_UNAVAILABLE -> networkReason(server = true)
        AuthProblem.RATE_LIMITED -> ConnectionErrorReason.RATE_LIMITED
        AuthProblem.STORAGE -> ConnectionErrorReason.STORAGE
        AuthProblem.NO_WORKSPACE -> ConnectionErrorReason.NO_WORKSPACE
        // Sign-in problems stay on the sign-in page and never reach a connection error.
        AuthProblem.INVALID_CODE, AuthProblem.ACCOUNT_DISABLED, AuthProblem.GOOGLE_NOT_CONFIGURED,
        AuthProblem.GOOGLE_NO_ACCOUNT, AuthProblem.GOOGLE_UNAVAILABLE, AuthProblem.GOOGLE_REJECTED,
        AuthProblem.GOOGLE_CONFLICT -> ConnectionErrorReason.CHAT_UNAVAILABLE
    }

    private fun conversationReason(problem: ConversationProblem) = when (problem) {
        ConversationProblem.NETWORK -> networkReason(server = false)
        ConversationProblem.SERVER -> networkReason(server = true)
        ConversationProblem.STORAGE -> ConnectionErrorReason.STORAGE
        else -> ConnectionErrorReason.CHAT_UNAVAILABLE
    }

    private fun publish(next: ConnectionErrorState?) {
        if (state == next) return
        state = next
        onChanged(next)
    }

    private companion object {
        val AUTO_RETRY_REASONS = setOf(ConnectionErrorReason.OFFLINE, ConnectionErrorReason.UNREACHABLE, ConnectionErrorReason.SERVICE)
    }
}
