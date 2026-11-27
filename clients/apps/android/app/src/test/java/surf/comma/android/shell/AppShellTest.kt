package surf.comma.android.shell

import android.os.Bundle
import android.view.MotionEvent
import android.view.View
import androidx.activity.BackEventCompat
import androidx.activity.ComponentActivity
import java.util.concurrent.TimeUnit
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
    private companion object {
        const val FRAME_MS = 16L
        /** The time on the touches the tests make; only their spacing counts. */
        const val TOUCH_AT = 1_000L
    }
    private val sessions = MemorySessions()
    private val core = TestSessionCore(sessions)
    @Before fun jumpSprings() = setDurationScale(0f)
    @After fun restoreSprings() {
        setDurationScale(1f)
        org.robolectric.shadows.ShadowChoreographer.setPaused(false)
        resetSpringFrames()
    }

    private fun setDurationScale(scale: Float) {
        android.animation.ValueAnimator::class.java.getDeclaredMethod("setDurationScale", Float::class.javaPrimitiveType)
            .invoke(null, scale)
    }

    private fun withShell(signedIn: Boolean = false, state: Bundle? = null, block: (ComponentActivity, AuthRepository, AppShell, LiveChatScreen) -> Unit) {
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
            shell.restoreState(state)
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

    @Test fun `Home's search button opens search over the tabs`() = withShell(signedIn = true) { activity, _, shell, _ ->
        shell.layout(0, 0, 1080, 2400)
        shell.measure(android.view.View.MeasureSpec.makeMeasureSpec(1080, android.view.View.MeasureSpec.EXACTLY),
            android.view.View.MeasureSpec.makeMeasureSpec(2400, android.view.View.MeasureSpec.EXACTLY))
        shell.layout(0, 0, 1080, 2400)
        ShadowLooper.idleMainLooper()
        activity.findViewById<android.view.View>(R.id.tab_home).performClick()
        ShadowLooper.idleMainLooper()
        activity.findViewById<android.view.View>(R.id.home_search).performClick()
        ShadowLooper.idleMainLooper()
        assertTrue(anyDescendant(shell) { it is SearchLayer })
    }

    private fun anyDescendant(view: android.view.View, match: (android.view.View) -> Boolean): Boolean =
        match(view) || (view is android.view.ViewGroup && (0 until view.childCount).any { anyDescendant(view.getChildAt(it), match) })

    @Test fun wifiListScrollsAboveTheShellBar() = withShell { activity, _, shell, _ ->
        shell.openSettings()
        val settings = AppShell::class.java.getDeclaredField("settings").apply { isAccessible = true }
            .get(shell) as surf.comma.android.settings.SettingsHost
        val page = surf.comma.android.settings.AddDevicePage(settings)
        settings.open(page)
        val layout = page.view as surf.comma.android.settings.SettingsPageLayout
        val device = surf.comma.android.settings.devices.FoundDevice("fixture", "Comma-1234", -50)
        val step = surf.comma.android.settings.devices.AddDeviceStep.ChoosingWifi(device, device.name,
            (1..30).map { surf.comma.android.settings.devices.WifiNetwork("Wi-Fi $it", -50, false) },
            false, false, null, null)
        page.javaClass.getDeclaredMethod("show", surf.comma.android.settings.devices.AddDeviceStep::class.java)
            .apply { isAccessible = true }.invoke(page, step)
        androidx.core.view.ViewCompat.dispatchApplyWindowInsets(shell, androidx.core.view.WindowInsetsCompat.Builder()
            .setInsets(androidx.core.view.WindowInsetsCompat.Type.systemBars(), androidx.core.graphics.Insets.of(0, 72, 0, 144)).build())
        ShadowLooper.idleMainLooper()
        fun place() {
            shell.measure(android.view.View.MeasureSpec.makeMeasureSpec(1233, android.view.View.MeasureSpec.EXACTLY),
                android.view.View.MeasureSpec.makeMeasureSpec(2673, android.view.View.MeasureSpec.EXACTLY))
            shell.layout(0, 0, shell.measuredWidth, shell.measuredHeight)
        }
        place()
        layout.list.scrollBy(0, Int.MAX_VALUE)
        place()
        val tabBar = AppShell::class.java.getDeclaredField("tabBar").apply { isAccessible = true }.get(shell) as android.view.View
        val cancel = layout.sections.firstNotNullOf { it.findViewById<android.view.View>(R.id.devices_add_secondary) }
        val bounds = android.graphics.Rect(0, 0, cancel.width, cancel.height)
        shell.offsetDescendantRectToMyCoords(cancel, bounds)
        assertTrue("cancel $bounds clears bar at ${tabBar.top}", bounds.bottom <= tabBar.top)
        assertTrue("cancel is visible", bounds.top >= layout.bar.bottom)
        fun rows(view: android.view.View): List<surf.comma.android.settings.SettingsRow> = when (view) {
            is surf.comma.android.settings.SettingsRow -> listOf(view)
            is android.view.ViewGroup -> (0 until view.childCount).flatMap { rows(view.getChildAt(it)) }
            else -> emptyList()
        }
        val last = layout.sections.flatMap(::rows).last { it.title.text.toString() == "Wi-Fi 30" }
        bounds.set(0, 0, last.width, last.height)
        shell.offsetDescendantRectToMyCoords(last, bounds)
        assertTrue("last network $bounds clears bar at ${tabBar.top}", bounds.bottom <= tabBar.top)
        assertTrue("last network is visible", bounds.top >= layout.bar.bottom)
        settings.host.clear()
    }

    @Test fun `signing in opens the chat at full size without focusing the keyboard`() = withShell { _, auth, _, chat ->
        signIn(auth)
        assertTrue("chat is the first page after sign-in", chat.root.isShown)
        assertEquals(1f, (chat.root.parent as android.view.View).alpha, 0f)
        assertFalse(chat.root.findFocus() is android.widget.EditText)
    }

    @Test fun `restored editor focus stays quiet until the shell explicitly requests editing`() =
        withShell(signedIn = true) { activity, _, shell, chat ->
            val composer = chat.root.findViewById<surf.comma.android.ui.composer.ComposerView>(R.id.comma_composer)
            val keyboard = org.robolectric.Shadows.shadowOf(activity.getSystemService(android.view.inputmethod.InputMethodManager::class.java))
            composer.field.requestFocus()
            shell.resumed()
            ShadowLooper.idleMainLooper()
            assertTrue(composer.field.hasFocus())
            assertFalse("restoring focus while resuming does not request the keyboard", keyboard.isSoftInputVisible)
            shell.openRouter(focus = true)
            ShadowLooper.idleMainLooper()
            assertTrue("an explicit edit request still opens the keyboard", keyboard.isSoftInputVisible)
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

    @Test fun `a pull down on the chat's top bar closes it past half way and springs back short of it`() =
        withShell(signedIn = true) { activity, _, shell, chat ->
            layOut(shell)
            pull(shell, activity, travel = 0.2f)
            ShadowLooper.idleMainLooper()
            assertTrue("short of half way, the chat springs back", chat.root.isShown)
            assertFullSize(chat)
            pull(shell, activity, travel = 0.6f)
            ShadowLooper.idleMainLooper()
            assertFalse("past half way, it closes", chat.root.isShown)
        }

    @Test fun `once the chat starts closing, a tap reaches the tabs under it`() =
        withShell(signedIn = true) { activity, _, shell, chat ->
            layOut(shell)
            animateFromHere()
            activity.onBackPressedDispatcher.onBackPressed()
            assertTrue("still on its way out", chat.root.isShown)
            tap(shell, activity.findViewById(R.id.tab_settings))
            frames(100)
            assertTrue("the tab under the closing chat took the tap", activity.findViewById<View>(R.id.tab_settings).isSelected)
        }

    @Test fun `tapping the circle while the chat closes opens it again, and it stays open`() =
        withShell(signedIn = true) { activity, _, shell, chat ->
            layOut(shell)
            animateFromHere()
            activity.onBackPressedDispatcher.onBackPressed()
            frames(100)
            assertTrue("part way into the circle", chat.root.isShown && chat.root.scaleX < 1f)
            tap(shell, activity.findViewById(R.id.tab_router))
            frames(2000)
            assertTrue(chat.root.isShown)
            assertFullSize(chat)
        }

    @Test fun `a cancelled back gesture leaves the chat open and a finished one closes it`() =
        withShell(signedIn = true) { activity, _, shell, chat ->
            layOut(shell)
            val back = activity.onBackPressedDispatcher
            fun swipe() {
                back.dispatchOnBackStarted(BackEventCompat(0f, 1200f, 0f, BackEventCompat.EDGE_LEFT))
                back.dispatchOnBackProgressed(BackEventCompat(shell.width * 0.4f, 1200f, 0.4f, BackEventCompat.EDGE_LEFT))
            }
            swipe()
            assertTrue("the chat follows the finger", chat.root.scaleX < 1f)
            back.dispatchOnBackCancelled()
            ShadowLooper.idleMainLooper()
            assertTrue(chat.root.isShown)
            assertFullSize(chat)
            swipe()
            back.onBackPressed()
            ShadowLooper.idleMainLooper()
            assertFalse(chat.root.isShown)
        }

    @Test fun `a back gesture that starts while the chat is still opening does not snap it to full size`() =
        withShell(signedIn = true) { activity, _, shell, chat ->
            layOut(shell)
            activity.onBackPressedDispatcher.onBackPressed()
            ShadowLooper.idleMainLooper()
            assertFalse(chat.root.isShown)
            animateFromHere()
            tap(shell, activity.findViewById(R.id.tab_router))
            frames(64)
            val scale = chat.root.scaleX
            val top = chat.root.translationY
            assertTrue("part way out of the circle", scale < 0.9f)
            val back = activity.onBackPressedDispatcher
            back.dispatchOnBackStarted(BackEventCompat(0f, 1200f, 0f, BackEventCompat.EDGE_LEFT))
            back.dispatchOnBackProgressed(BackEventCompat(shell.width * 0.1f, 1200f, 0.1f, BackEventCompat.EDGE_LEFT))
            assertEquals("the shape stays where it was", scale, chat.root.scaleX, 0f)
            assertEquals(top, chat.root.translationY, 0f)
            back.dispatchOnBackCancelled()
            frames(2000)
            assertTrue(chat.root.isShown)
            assertFullSize(chat)
        }

    @Test fun `the chat opens out of the circle after the screen it fills changed size while closed`() =
        withShell(signedIn = true) { activity, _, shell, chat ->
            layOut(shell)
            activity.onBackPressedDispatcher.onBackPressed()
            ShadowLooper.idleMainLooper()
            assertFalse(chat.root.isShown)
            // Shorter now, as with a docked Task under the app: the closed layer kept its old size.
            val metrics = shell.resources.displayMetrics
            fun shorter() {
                shell.measure(View.MeasureSpec.makeMeasureSpec(metrics.widthPixels, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(metrics.heightPixels - 300, View.MeasureSpec.EXACTLY))
                shell.layout(0, 0, shell.measuredWidth, shell.measuredHeight)
            }
            shorter()
            animateFromHere()
            val circle = activity.findViewById<View>(R.id.tab_router)
            tap(shell, circle)
            ShadowLooper.idleMainLooper()
            shorter()
            val at = IntArray(2).also(circle::getLocationInWindow)
            val origin = IntArray(2).also(shell::getLocationInWindow)
            assertEquals("starts on the circle", (at[0] - origin[0]).toFloat(), chat.root.translationX, 2f)
            assertEquals((at[1] - origin[1]).toFloat(), chat.root.translationY, 2f)
        }

    @Test fun `closing a minimized Task lowers the app's foot with its bar instead of dropping it at the end`() =
        withShell(signedIn = true) { activity, _, shell, _ ->
            layOut(shell)
            val dock = AppShell::class.java.getDeclaredField("dock").apply { isAccessible = true }.get(shell) as TaskDock
            val tabBar = activity.findViewById<View>(R.id.tab_home).let { generateSequence(it) { v -> v.parent as? View } }
                .first { it is ShellTabBar }
            fun barBottom(): Int { layOut(shell); return IntArray(2).also(tabBar::getLocationInWindow)[1] + tabBar.height }
            val free = barBottom()
            dock.open("task-a", raise = false)
            ShadowLooper.idleMainLooper()
            val docked = barBottom()
            assertTrue("the minimized bar lifts the tabs", docked < free)

            animateFromHere()
            dock.close()
            val path = mutableListOf(docked)
            repeat(60) { frames(FRAME_MS); path += barBottom() }
            assertFalse("the Task is let go once its bar is off the screen", dock.isOpen)
            assertEquals("the tabs end at their own place", free, path.last())
            val steps = path.zipWithNext { a, b -> b - a }
            assertTrue("the tabs only go down: $path", steps.all { it >= 0 })
            assertTrue("no frame takes more than a third of the way: $path", steps.all { it <= (free - docked) / 3 })
            assertTrue("they move over several frames: $path", steps.count { it > 0 } >= 5)
        }

    /** Springs move from here on, one vsync per 16 ms of looper time ([frames]) instead of all at once in an idle. */
    private fun animateFromHere() {
        setDurationScale(1f)
        resetSpringFrames()
        org.robolectric.shadows.ShadowChoreographer.setPaused(true)
        org.robolectric.shadows.ShadowChoreographer.setFrameDelay(java.time.Duration.ofMillis(FRAME_MS))
    }

    /**
     * Springs share one frame handler per thread, and the main thread outlives each test. A spring still running when
     * a test ends leaves the handler waiting for a frame from a looper that is reset, and every later spring on the
     * thread would freeze; start and leave it empty.
     */
    private fun resetSpringFrames() {
        Class.forName("androidx.dynamicanimation.animation.AnimationHandler")
            .getDeclaredField("sAnimatorHandler").apply { isAccessible = true }
            .let { (it.get(null) as ThreadLocal<*>).remove() }
    }

    /** Runs [millis] of frames, one at a time. */
    private fun frames(millis: Long) = repeat((millis / FRAME_MS).toInt()) { ShadowLooper.idleMainLooper(FRAME_MS, TimeUnit.MILLISECONDS) }

    private fun assertFullSize(chat: LiveChatScreen) {
        assertEquals("full width", 1f, chat.root.scaleX, 0f)
        assertEquals("at the top", 0f, chat.root.translationY, 0f)
        assertEquals("fully shown", 1f, chat.root.alpha, 0f)
    }

    /** A slow pull down from the chat's top bar over [travel] of the screen's height, held still before letting go. */
    private fun pull(shell: AppShell, activity: ComponentActivity, travel: Float) {
        val x = shell.width / 2f
        val y = 20 * activity.resources.displayMetrics.density
        val start = TOUCH_AT
        val steps = 10
        val events = mutableListOf(MotionEvent.obtain(start, start, MotionEvent.ACTION_DOWN, x, y, 0))
        for (step in 1..steps) {
            events += MotionEvent.obtain(start, start + step * 100L, MotionEvent.ACTION_MOVE, x, y + shell.height * travel * step / steps, 0)
        }
        val end = y + shell.height * travel
        events += MotionEvent.obtain(start, start + steps * 100L + 200L, MotionEvent.ACTION_MOVE, x, end, 0)
        events += MotionEvent.obtain(start, start + steps * 100L + 200L, MotionEvent.ACTION_UP, x, end, 0)
        events.forEach { shell.dispatchTouchEvent(it); it.recycle() }
    }

    private fun tap(shell: AppShell, view: View) {
        val at = IntArray(2).also(view::getLocationInWindow)
        val origin = IntArray(2).also(shell::getLocationInWindow)
        val x = at[0] - origin[0] + view.width / 2f
        val y = at[1] - origin[1] + view.height / 2f
        val time = TOUCH_AT
        listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP).forEach { action ->
            MotionEvent.obtain(time, time, action, x, y, 0).also { shell.dispatchTouchEvent(it); it.recycle() }
        }
    }

    private fun settingsOf(shell: AppShell) = AppShell::class.java.getDeclaredField("settings").apply { isAccessible = true }
        .get(shell) as surf.comma.android.settings.SettingsHost

    /** The Settings tab with its list scrolled and Notifications opened from it, saved as the activity is recreated. */
    private fun savedSettings(): Pair<Bundle, Pair<Int, Int>> {
        val saved = Bundle()
        var shown = 0 to 0
        withShell { _, _, shell, _ ->
            shell.openSettings()
            ShadowLooper.idleMainLooper()
            val settings = settingsOf(shell)
            val list = (settings.host.pages().first().view as surf.comma.android.settings.SettingsPageLayout).list
            layOut(shell)
            // Short of the end: the recreated window is taller, and a list scrolled to its end there is clamped back.
            list.scrollBy(0, 500)
            layOut(shell)
            shown = firstShown(list)
            settings.openFromList(surf.comma.android.settings.NotificationsPage(settings))
            ShadowLooper.idleMainLooper()
            shell.saveState(saved)
        }
        assertTrue("the list was scrolled", shown.first > 0 || shown.second < 0)
        return saved to shown
    }

    /** Lays the shell out at the display's size, the same before and after the activity is recreated. */
    private fun layOut(shell: AppShell) {
        val metrics = shell.resources.displayMetrics
        shell.measure(android.view.View.MeasureSpec.makeMeasureSpec(metrics.widthPixels, android.view.View.MeasureSpec.EXACTLY),
            android.view.View.MeasureSpec.makeMeasureSpec(metrics.heightPixels, android.view.View.MeasureSpec.EXACTLY))
        shell.layout(0, 0, shell.measuredWidth, shell.measuredHeight)
    }

    /** Where the first row shown starts: its place in the list and its top. */
    private fun firstShown(list: surf.comma.android.scroll.widget.RecyclerView) =
        list.getChildAt(0).let { list.getChildAdapterPosition(it) to it.top }

    /**
     * Recreated with animations on and no frame drawn: a slide would start as the page is first laid out and still be
     * at its start, which Robolectric would otherwise run to its end at once.
     */
    private fun recreatedSettings(saved: Bundle, block: (surf.comma.android.settings.SettingsHost) -> Unit) {
        setDurationScale(1f)
        org.robolectric.shadows.ShadowChoreographer.setPaused(true)
        try {
            withShell(state = saved) { _, _, shell, _ ->
                // Frames are paused, so the window lays nothing out.
                layOut(shell)
                block(settingsOf(shell))
            }
        } finally {
            org.robolectric.shadows.ShadowChoreographer.setPaused(false)
        }
    }

    @Test fun `Settings comes back as it was, without sliding in, after the activity is recreated`() {
        val (saved, shown) = savedSettings()
        recreatedSettings(saved) { settings ->
            val root = settings.host.pages().first().view as surf.comma.android.settings.SettingsPageLayout
            assertTrue("laid out", root.isLaidOut)
            assertEquals("the list is in place, not sliding in", 0f, root.translationX, 0f)
            assertEquals("the page opened from the list is still open", listOf("root", "notifications"), settings.host.keys)
            assertEquals("and in place too", 0f, settings.host.pages().last().view.translationX, 0f)
            assertEquals("the list is where it was", shown, firstShown(root.list))
        }
    }

    @Config(sdk = [35], qualifiers = "w1000dp-h800dp-xhdpi")
    @Test fun `on a wide window the page beside the list comes back after the activity is recreated`() {
        val (saved, _) = savedSettings()
        recreatedSettings(saved) { settings ->
            assertTrue("two columns", settings.host.columns)
            assertEquals("the page beside the list is still open", listOf("root", "notifications"), settings.host.keys)
            assertEquals("not sliding in", 0f, settings.host.pages().last().view.translationX, 0f)
        }
    }
}
