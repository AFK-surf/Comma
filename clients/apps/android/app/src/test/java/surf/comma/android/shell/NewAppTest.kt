package surf.comma.android.shell

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.descendants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.MemorySessions
import surf.comma.android.auth.TestAuthRepository
import surf.comma.android.auth.TestSessionCore
import surf.comma.android.auth.awaitState
import surf.comma.android.chat.live.LiveChatScreen
import surf.comma.android.conversation.AuthConversationSessions
import surf.comma.android.conversation.ChatView
import surf.comma.android.miniapps.MiniAppRuntimes
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.ui.composer.ComposerView
import surf.comma.android.workspace.CommaApi
import surf.comma.android.workspace.WorkspaceStore
import java.io.File
import java.util.concurrent.TimeUnit

/** New app on the empty Apps tab leaves the start of a request in the router chat's composer once, as on the desktop. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN-w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NewAppTest {
    @Test fun `New app on the empty Apps tab opens the router chat with the request to finish, unsent`() =
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get().apply { setTheme(R.style.Theme_Chat) }
            controller.create()
            val sessions = MemorySessions()
            val core = TestSessionCore(sessions)
            AuthGraph.install(TestAuthRepository(sessions, core = core), CoroutineScope(SupervisorJob() + Dispatchers.Unconfined), core)
            val auth = AuthGraph.get(activity)
            // The Apps pages open under the scope the runtimes follow: this test's session, whatever ran before.
            val runtimesAuth = MiniAppRuntimes::class.java.getDeclaredField("auth").apply { isAccessible = true }
            val earlier = runtimesAuth.get(MiniAppRuntimes)
            runtimesAuth.set(MiniAppRuntimes, auth)
            runBlocking {
                auth.start()
                auth.awaitState<AuthState.Login>()
                auth.sendCode("alice@example.test")
                auth.awaitState<AuthState.Login> { it.challengeId != null }
                auth.verify("123456")
                auth.awaitState<AuthState.Connected>()
            }
            val chat = ChatView(AuthConversationSessions(auth), null, io = Dispatchers.Unconfined)
            val screen = LiveChatScreen(activity, chat, auth.state, retrySession = {}, onOpenAccount = {}, router = true)
            val tasks = ServerTaskRepository(AuthConversationSessions(auth), null, io = Dispatchers.Unconfined)
            val shell = AppShell(activity, screen, chat, WorkspaceStore(activity, auth, tasks, CommaApi(null)))
            activity.setContentView(shell)
            controller.start().resume().visible()
            try {
                settle(30)
                // A signed-in launch opens the router chat; the member goes back to the tabs and on to Settings › Apps.
                activity.onBackPressedDispatcher.onBackPressed()
                settle(40)
                activity.findViewById<View>(R.id.tab_settings).performClick()
                settle(40)
                activity.findViewById<View>(R.id.settings_apps).performClick()
                settle(40)
                val frames = Frames(shell)
                frames.hold(20)
                assertFalse(screen.root.isShown)
                val button = shell.descendants.filterIsInstance<TextView>()
                    .single { it.isShown && it.text == activity.getString(R.string.mini_apps_new) }
                button.performClick()
                val composer = screen.root.findViewById<ComposerView>(R.id.comma_composer)
                // The draft lands without taking focus; the chat raises the keyboard once it has opened.
                assertFalse("the field waits for the router chat to open", composer.field.hasFocus())
                val keyboard = org.robolectric.Shadows.shadowOf(activity.getSystemService(android.view.inputmethod.InputMethodManager::class.java))
                frames.run(60)

                assertTrue("the router chat is open", screen.root.isShown)
                assertEquals(activity.getString(R.string.mini_apps_new_prompt), composer.field.text.toString())
                assertEquals("the caret waits at the end", composer.field.length(), composer.field.selectionEnd)
                assertTrue("the keyboard is up for the member to finish it", composer.field.hasFocus() && keyboard.isSoftInputVisible)
                frames.hold(20)

                // Closed unsent and opened again from New app, the draft holds the request once, as on the desktop.
                activity.onBackPressedDispatcher.onBackPressed()
                settle(40)
                assertFalse(screen.root.isShown)
                button.performClick()
                settle(60)
                assertEquals(activity.getString(R.string.mini_apps_new_prompt), composer.field.text.toString())
            } finally {
                shell.release()
                runtimesAuth.set(MiniAppRuntimes, earlier)
                screen.release()
                chat.close()
                tasks.close()
            }
        }

    private fun settle(frames: Int) = repeat(frames) { ShadowLooper.idleMainLooper(16, TimeUnit.MILLISECONDS) }

    /** Numbered frames of [view] to `$COMMA_FRAMES/new-app`, one per 16ms step, for a video; nothing when unset. */
    private inner class Frames(private val view: View) {
        private val dir = System.getenv("COMMA_FRAMES")?.let { File(it, "new-app").apply { mkdirs() } }
        private var index = 0

        fun run(count: Int) = repeat(count) {
            ShadowLooper.idleMainLooper(16, TimeUnit.MILLISECONDS)
            shoot()
        }

        fun hold(count: Int) = repeat(count) { shoot() }

        private fun shoot() {
            val dir = dir ?: return
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            File(dir, "%04d.png".format(index++)).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
    }
}
