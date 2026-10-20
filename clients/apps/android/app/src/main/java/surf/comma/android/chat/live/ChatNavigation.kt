package surf.comma.android.chat.live

import android.content.Context
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState
import surf.comma.android.conversation.ConversationGraph
import surf.comma.android.conversation.ChatView

/** The main chat's data, owned by the process like the session itself. */
object ChatGraph {
    @Volatile private var repository: ChatView? = null

    fun conversations(context: Context): ChatView = repository ?: synchronized(this) {
        repository ?: ConversationGraph.create(context.applicationContext, AuthGraph.get(context))
            .also { it.start(); repository = it }
    }
}

enum class ChatRoute { CHAT, AUTH, WAIT }

/**
 * Signed in with a main chat: the chat. Still deciding: stay. A failed check of a session whose
 * chat is already showing ([hasChat]) keeps the chat, which offers the retry. Anything else: the
 * sign-in flow.
 */
fun routeFor(state: AuthState, hasChat: Boolean = false): ChatRoute = when (state) {
    is AuthState.Connected -> ChatRoute.CHAT
    AuthState.Starting, is AuthState.Connecting -> ChatRoute.WAIT
    is AuthState.Retry -> if (hasChat) ChatRoute.CHAT else ChatRoute.AUTH
    is AuthState.Login, AuthState.Unconfigured -> ChatRoute.AUTH
}

enum class ChatNavigation { NONE, OPEN_AUTH, RETURN_TO_CHAT, FINISH }

/**
 * Keeps the chat page and the sign-in page in step with the session. The chat page stays at the
 * bottom of the task; the sign-in page is opened over it and closed again by bringing the chat
 * back to the front once the session connects.
 */
class ChatNavigator {
    private var authOpen = false
    private var leftForAuth = false

    /** The session moved to [route]. */
    fun onRoute(route: ChatRoute): ChatNavigation = when (route) {
        ChatRoute.AUTH -> if (authOpen) ChatNavigation.NONE else {
            authOpen = true
            leftForAuth = false
            ChatNavigation.OPEN_AUTH
        }
        ChatRoute.CHAT -> if (authOpen) {
            authOpen = false
            leftForAuth = false
            ChatNavigation.RETURN_TO_CHAT
        } else ChatNavigation.NONE
        ChatRoute.WAIT -> ChatNavigation.NONE
    }

    /** The user opened the account page from the chat. */
    fun onAccountOpened() {
        authOpen = true
        leftForAuth = false
    }

    fun onChatStopped() {
        if (authOpen) leftForAuth = true
    }

    /**
     * The chat is visible again. Returning from the sign-in page without a session means the
     * user backed out of signing in, so the app closes rather than show an empty chat.
     */
    fun onChatResumed(route: ChatRoute): ChatNavigation {
        if (!authOpen || !leftForAuth) return ChatNavigation.NONE
        authOpen = false
        leftForAuth = false
        return if (route == ChatRoute.AUTH) ChatNavigation.FINISH else ChatNavigation.NONE
    }
}
