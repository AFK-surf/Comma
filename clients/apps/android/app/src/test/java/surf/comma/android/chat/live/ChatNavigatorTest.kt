package surf.comma.android.chat.live

import org.junit.Assert.assertEquals
import org.junit.Test
import surf.comma.android.auth.Account
import surf.comma.android.auth.AuthProblem
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.ConnectionStep
import surf.comma.android.auth.Workspace
import surf.comma.android.auth.WorkspaceSelection

class ChatNavigatorTest {
    private val connected = AuthState.Connected(Account("a", "a@example.test", null, "active"),
        WorkspaceSelection(Workspace("w", "g", "W"), "c"))

    @Test fun `routes follow the session`() {
        assertEquals(ChatRoute.CHAT, routeFor(connected))
        assertEquals(ChatRoute.WAIT, routeFor(AuthState.Starting))
        assertEquals(ChatRoute.WAIT, routeFor(AuthState.Connecting(ConnectionStep.SESSION)))
        assertEquals(ChatRoute.AUTH, routeFor(AuthState.Login()))
        assertEquals(ChatRoute.AUTH, routeFor(AuthState.Retry(AuthProblem.NETWORK)))
        assertEquals(ChatRoute.AUTH, routeFor(AuthState.Unconfigured))
    }

    @Test fun `a failed session check keeps the cached chat that is already showing`() {
        assertEquals(ChatRoute.CHAT, routeFor(AuthState.Retry(AuthProblem.NETWORK), hasChat = true))
        assertEquals(ChatRoute.AUTH, routeFor(AuthState.Retry(AuthProblem.NETWORK), hasChat = false))
        // Signed out clears the chat first, so it always leads to sign-in.
        assertEquals(ChatRoute.AUTH, routeFor(AuthState.Login(), hasChat = true))
        assertEquals(ChatRoute.WAIT, routeFor(AuthState.Connecting(ConnectionStep.SESSION), hasChat = true))
    }

    @Test fun `signed out opens sign-in once and connecting brings the chat back`() {
        val navigator = ChatNavigator()
        assertEquals(ChatNavigation.NONE, navigator.onRoute(ChatRoute.WAIT))
        assertEquals(ChatNavigation.OPEN_AUTH, navigator.onRoute(ChatRoute.AUTH))
        navigator.onChatStopped()
        assertEquals(ChatNavigation.NONE, navigator.onRoute(ChatRoute.AUTH))
        assertEquals(ChatNavigation.NONE, navigator.onRoute(ChatRoute.WAIT))
        assertEquals(ChatNavigation.RETURN_TO_CHAT, navigator.onRoute(ChatRoute.CHAT))
        assertEquals(ChatNavigation.NONE, navigator.onChatResumed(ChatRoute.CHAT))
        assertEquals(ChatNavigation.NONE, navigator.onRoute(ChatRoute.CHAT))
    }

    @Test fun `opening sign-in from onCreate does not count as backing out`() {
        val navigator = ChatNavigator()
        assertEquals(ChatNavigation.OPEN_AUTH, navigator.onRoute(ChatRoute.AUTH))
        // The chat can still reach onResume before the sign-in page covers it.
        assertEquals(ChatNavigation.NONE, navigator.onChatResumed(ChatRoute.AUTH))
    }

    @Test fun `backing out of sign-in without a session closes the app`() {
        val navigator = ChatNavigator()
        navigator.onRoute(ChatRoute.AUTH)
        navigator.onChatStopped()
        assertEquals(ChatNavigation.FINISH, navigator.onChatResumed(ChatRoute.AUTH))
    }

    @Test fun `signing out while connected opens sign-in, and a new sign-in returns`() {
        val navigator = ChatNavigator()
        assertEquals(ChatNavigation.NONE, navigator.onRoute(ChatRoute.CHAT))
        assertEquals(ChatNavigation.OPEN_AUTH, navigator.onRoute(ChatRoute.AUTH))
        navigator.onChatStopped()
        assertEquals(ChatNavigation.RETURN_TO_CHAT, navigator.onRoute(ChatRoute.CHAT))
    }

    @Test fun `account page opened from the chat returns after switching account`() {
        val navigator = ChatNavigator()
        navigator.onRoute(ChatRoute.CHAT)
        navigator.onAccountOpened()
        navigator.onChatStopped()
        // Signing out there shows the sign-in form in the same page; nothing new opens.
        assertEquals(ChatNavigation.NONE, navigator.onRoute(ChatRoute.AUTH))
        assertEquals(ChatNavigation.RETURN_TO_CHAT, navigator.onRoute(ChatRoute.CHAT))
    }

    @Test fun `leaving the account page while still signed in just resumes the chat`() {
        val navigator = ChatNavigator()
        navigator.onRoute(ChatRoute.CHAT)
        navigator.onAccountOpened()
        navigator.onChatStopped()
        assertEquals(ChatNavigation.NONE, navigator.onChatResumed(ChatRoute.CHAT))
        assertEquals(ChatNavigation.OPEN_AUTH, navigator.onRoute(ChatRoute.AUTH))
    }
}
