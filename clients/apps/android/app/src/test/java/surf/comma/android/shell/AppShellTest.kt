package surf.comma.android.shell

import android.os.Bundle
import androidx.activity.ComponentActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.Before
import org.junit.After
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.shadows.ShadowLooper
import org.robolectric.annotation.Config
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthRepository
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.MemorySessions
import surf.comma.android.auth.TestAuthRepository
import surf.comma.android.auth.TestSessionCore
import surf.comma.android.auth.awaitState
import surf.comma.android.chat.live.LiveChatScreen
import surf.comma.android.conversation.AuthConversationSessions
import surf.comma.android.conversation.ChatView
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.workspace.CommaApi
import surf.comma.android.workspace.WorkspaceStore

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class AppShellTest {
    private val sessions = MemorySessions()
    private val core = TestSessionCore(sessions)
    @Before fun jumpSprings() = setDurationScale(0f)
    @After fun restoreSprings() = setDurationScale(1f)

    private fun setDurationScale(scale: Float) {
        android.animation.ValueAnimator::class.java.getDeclaredMethod("setDurationScale", Float::class.javaPrimitiveType)
            .invoke(null, scale)
    }

    private fun withShell(signedIn: Boolean = false, block: (ComponentActivity, AuthRepository, AppShell, LiveChatScreen) -> Unit) {
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Chat)
            controller.create()
            AuthGraph.install(TestAuthRepository(sessions, core = core),
                CoroutineScope(SupervisorJob() + Dispatchers.Unconfined))
            val auth = AuthGraph.get(activity)
            runBlocking { auth.start(); auth.awaitState<AuthState.Login>() }
            if (signedIn) signIn(auth)
            val chat = ChatView(AuthConversationSessions(auth), null, io = Dispatchers.Unconfined)
            val screen = LiveChatScreen(activity, chat, auth.state, retrySession = {}, onOpenAccount = {}, router = true)
            val tasks = ServerTaskRepository(AuthConversationSessions(auth), null, io = Dispatchers.Unconfined)
            val store = WorkspaceStore(activity, auth, tasks, CommaApi(null))
            val shell = AppShell(activity, screen, chat, store)
            shell.restoreState(null)
            activity.setContentView(shell)
            controller.start().resume().visible()
            ShadowLooper.idleMainLooper()
            try {
                block(activity, auth, shell, screen)
            } finally {
                screen.release()
                chat.close()
                tasks.close()
            }
        }
    }

    private fun signIn(auth: AuthRepository) {
        runBlocking {
            auth.sendCode("alice@example.test")
            auth.awaitState<AuthState.Login> { it.challengeId != null }
            auth.verify("123456")
            auth.awaitState<AuthState.Connected>()
        }
        ShadowLooper.idleMainLooper()
    }

    @Test fun `signing in opens the chat at full size without focusing the keyboard`() = withShell { _, auth, _, chat ->
        signIn(auth)
        assertTrue("chat is the first page after sign-in", chat.root.isShown)
        assertEquals(1f, (chat.root.parent as android.view.View).alpha, 0f)
        assertFalse(chat.root.findFocus() is android.widget.EditText)
    }

    @Test fun `a fresh launch with an existing session opens chat and back returns to the tabs`() =
        withShell(signedIn = true) { activity, _, shell, chat ->
            assertTrue(chat.root.isShown)
            assertEquals(1f, (chat.root.parent as android.view.View).alpha, 0f)
            activity.onBackPressedDispatcher.onBackPressed()
            ShadowLooper.idleMainLooper()
            assertFalse(chat.root.isShown)
            shell.resumed()
            assertFalse("returning to the app preserves the tabs", chat.root.isShown)
        }

    @Test fun `returning to the app keeps the chosen page and signing in again opens chat`() =
        withShell { _, auth, shell, chat ->
            signIn(auth)
            shell.openSettings()
            ShadowLooper.idleMainLooper()
            shell.resumed()
            assertFalse("resuming does not replace Settings", chat.root.isShown)
            runBlocking { auth.logout(); auth.awaitState<AuthState.Login>() }
            ShadowLooper.idleMainLooper()
            signIn(auth)
            assertTrue("a new sign-in starts in chat", chat.root.isShown)
        }

    @Test fun `restoring navigation returns to the chat or the chosen tab`() = withShell { _, auth, shell, chat ->
        signIn(auth)
        val chatState = Bundle().also(shell::saveState)
        shell.openSettings()
        ShadowLooper.idleMainLooper()
        val tabState = Bundle().also(shell::saveState)
        shell.restoreState(chatState)
        ShadowLooper.idleMainLooper()
        assertTrue("restores the open chat", chat.root.isShown)
        shell.restoreState(tabState)
        ShadowLooper.idleMainLooper()
        assertFalse("restores the selected tab without opening chat", chat.root.isShown)
    }

    @Test fun `a different workspace closes chat even if the connection stays ready`() =
        withShell(signedIn = true) { _, auth, shell, chat ->
            core.workspaceChat = {
                JSONObject().put("status", "ready").put("kept", false).put("chat", JSONObject()
                    .put("workspaceId", "w-other").put("groupId", "g-other").put("conversationId", "chat-other"))
            }
            core.changed()
            runBlocking { auth.awaitState<AuthState.Connected> { it.selection.workspace.id == "w-other" } }
            ShadowLooper.idleMainLooper()
            assertFalse("the old chat closes when its scope changes", chat.root.isShown)
            shell.resumed()
            assertFalse("resuming does not reopen chat after a workspace switch", chat.root.isShown)
            shell.openRouter(focus = false)
            ShadowLooper.idleMainLooper()
            assertTrue("chat can be opened for the new workspace", chat.root.isShown)
        }

    @Test fun `losing a workspace closes chat while recovery with the same scope keeps it open`() =
        withShell(signedIn = true) { _, auth, _, chat ->
            core.phase = "indeterminate"
            core.kept = "alice"
            core.changed()
            runBlocking { auth.awaitState<AuthState.Retry>() }
            ShadowLooper.idleMainLooper()
            assertTrue("a retained offline scope keeps its chat", chat.root.isShown)

            core.workspaceChat = { JSONObject().put("status", "hidden").put("chat", JSONObject.NULL).put("kept", false) }
            core.changed()
            runBlocking { auth.conversationScope.first { it == null } }
            ShadowLooper.idleMainLooper()
            assertFalse("a removed scope closes chat", chat.root.isShown)
        }
}
