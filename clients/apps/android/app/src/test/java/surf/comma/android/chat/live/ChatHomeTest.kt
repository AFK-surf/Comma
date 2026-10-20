package surf.comma.android.chat.live

import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.tasks.pages.TaskDetailActivity
import surf.comma.android.tasks.pages.TaskListActivity
import surf.comma.android.tasks.pages.TaskPages
import kotlin.math.roundToInt

/** The signed-in home as MainActivity mounts it: the chat, its floating top chrome and the sidebar. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w360dp-h740dp-xxhdpi")
class ChatHomeTest {
    private class Home(
        val activity: ComponentActivity,
        val screen: LiveChatScreen,
        val home: ChatHome,
        val topBar: HomeTopBar,
        val timeline: ChatTimelineView,
        val accountOpened: MutableList<Unit>,
        val settingsOpened: MutableList<Unit>,
        val callsStarted: MutableList<Unit>,
    )

    @Before fun jumpSprings() {
        // Springs land at once, as with "remove animations"; the motion itself is checked on a device.
        setDurationScale(0f)
    }

    @After fun restoreSprings() = setDurationScale(1f)

    private fun setDurationScale(scale: Float) {
        android.animation.ValueAnimator::class.java.getDeclaredMethod("setDurationScale", Float::class.javaPrimitiveType)
            .invoke(null, scale)
    }

    private fun <T> withHome(block: (Home) -> T): T =
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Chat)
            controller.setup()
            val account = mutableListOf<Unit>()
            val settings = mutableListOf<Unit>()
            val calls = mutableListOf<Unit>()
            val screen = LiveChatScreen(activity, ChatGraph.conversations(activity), AuthGraph.get(activity).state,
                retrySession = {}, onOpenAccount = { account += Unit }, onCall = { calls += Unit })
            val home = ChatHome(activity, screen, onOpenSettings = { settings += Unit })
            activity.setContentView(home.root)
            ShadowLooper.idleMainLooper()
            val topBar = descendants(screen.root).filterIsInstance<HomeTopBar>().single()
            val timeline = activity.findViewById<ChatTimelineView>(R.id.conversation_timeline)
            try {
                block(Home(activity, screen, home, topBar, timeline, account, settings, calls))
            } finally {
                screen.release()
            }
        }

    @Test fun `the chrome floats over the list, which reaches the top of the screen`() = withHome { h ->
        assertEquals(0, h.screen.root.paddingTop)
        assertEquals(0, h.topBar.top)
        assertEquals(h.topBar.heightFor(0), h.topBar.height)
        assertEquals("the list starts below the chrome", h.topBar.height, h.timeline.paddingTop)
        assertEquals(0, h.timeline.top)
        // The old bar's "Tasks" button is gone; tasks live in the sidebar now.
        assertNull(h.activity.findViewById<View?>(R.id.chat_settings)?.takeIf { it.parent !== h.topBar })
        val tasks = h.activity.getString(R.string.task_list_title)
        assertTrue(descendants(h.screen.root).none { it is android.widget.TextView && it.text == tasks })
    }

    @Test fun `the page behind the chat never takes keyboard focus`() = withHome { h ->
        // A tap on the page puts the keyboard away, but the page is not a control: focused outside
        // touch mode (after a hardware key), it would wear the system focus highlight, a 12 % grey
        // over the whole screen until the next touch.
        val page = h.screen.root
        assertTrue("a tap still dismisses", page.hasOnClickListeners())
        assertFalse("the page cannot be focused", page.isFocusable)
        // Asked for focus, the page hands it to a field inside it rather than taking it itself.
        page.requestFocus()
        assertFalse(page.isFocused)
        // The list may hold focus, for keys to scroll it, but never greys over.
        assertFalse(h.timeline.defaultFocusHighlightEnabled)
    }

    @Test fun `a taller status bar pushes the chrome and the list inset down together`() = withHome { h ->
        val statusBar = (24 * h.activity.resources.displayMetrics.density).roundToInt()
        h.topBar.setStatusBarInset(statusBar)
        ShadowLooper.idleMainLooper()
        assertEquals(statusBar, h.topBar.paddingTop)
        assertEquals(h.topBar.heightFor(statusBar), h.topBar.height)
        assertEquals(h.topBar.height, h.timeline.paddingTop)
    }

    @Test fun `the side circles centre on the mark and the capsule laps over its bottom`() = withHome { h ->
        val density = h.activity.resources.displayMetrics.density
        fun dp(value: Int) = (value * density).roundToInt()
        val statusBar = dp(24)
        h.topBar.setStatusBarInset(statusBar)
        ShadowLooper.idleMainLooper()
        val bar = h.topBar
        assertEquals("12 dp from the status bar to the mark", dp(12), bar.avatar.top - statusBar)
        assertEquals(dp(60), bar.avatar.height)
        val markCentre = (bar.avatar.top + bar.avatar.bottom) / 2
        val menu = bar.frostPatches().single { it.key == "menu" }.bounds
        assertEquals("40 dp menu circle", dp(40), menu.width())
        assertEquals(dp(40), menu.height())
        assertEquals("menu circle centred on the mark", markCentre, menu.centerY())
        assertEquals("48 dp touch target", dp(48), bar.menuButton.height)
        val icon = (bar.menuButton as android.view.ViewGroup).getChildAt(0)
        assertEquals("24 dp menu icon", dp(24), icon.width)
        assertEquals("16 dp gutter to the circle", dp(16), menu.left)
        bar.setCall(available = true, live = false)
        ShadowLooper.idleMainLooper()
        val call = bar.frostPatches().single { it.key == "call" }.bounds
        assertEquals("48 dp touch target", dp(48), bar.callButton.height)
        assertEquals("40 dp call circle", dp(40), call.width())
        assertEquals("call circle centred on the mark", markCentre, call.centerY())
        assertEquals("24 dp call icon", dp(24), (bar.callButton as android.view.ViewGroup).getChildAt(0).width)
        assertEquals("16 dp gutter to the call circle", dp(16), bar.width - call.right)
        assertEquals("capsule 26 dp high", dp(26), bar.capsule.height)
        assertEquals(dp(HomeTopBar.CAPSULE_OVERLAP_DP), bar.avatar.bottom - bar.capsule.top)
        assertEquals("12 dp under the capsule", dp(12), bar.height - bar.capsule.bottom)
        assertEquals(bar.capsule.height / 2f, bar.frostPatches().single { it.key == "capsule" }.radius)
        // The frost is whole down to the mark and gone only below the bar.
        assertTrue(bar.frostSolid in statusBar until bar.capsule.top)
        assertTrue(bar.frostBottom > bar.height)
    }

    @Test fun `the side buttons float without a drawn shadow`() = withHome { h ->
        assertTrue(h.topBar.menuButton.background is android.graphics.drawable.InsetDrawable)
        assertEquals(0f, h.topBar.menuButton.elevation)
        assertTrue(h.topBar.callButton.background is android.graphics.drawable.InsetDrawable)
        assertEquals(0f, h.topBar.callButton.elevation)
    }

    @Test fun `the capsule line is primary text at 90 percent`() = withHome { h ->
        val line = descendants(h.topBar.capsule).filterIsInstance<android.widget.TextView>()
            .single { it.text == h.activity.getString(R.string.chat_brand_name) }
        val primary = h.activity.getColor(R.color.token_text_primary)
        assertEquals(0xE6, android.graphics.Color.alpha(line.currentTextColor))
        assertEquals(primary and 0xFFFFFF, line.currentTextColor and 0xFFFFFF)
    }

    @Test fun `the menu button opens the sidebar and back closes it`() = withHome { h ->
        assertFalse(h.home.isOpen)
        assertEquals(View.INVISIBLE, h.home.sidebar.view.visibility)
        h.topBar.menuButton.performClick()
        ShadowLooper.idleMainLooper()
        assertTrue(h.home.isOpen)
        assertEquals(1f, h.home.root.drawerProgress, 0f)
        assertEquals(View.VISIBLE, h.home.sidebar.view.visibility)
        assertEquals(0, h.home.sidebar.view.left)
        assertEquals("the chat follows a third of the way", h.home.sidebar.view.width / 3f, h.screen.root.translationX, 1f)

        h.activity.onBackPressedDispatcher.onBackPressed()
        ShadowLooper.idleMainLooper()
        assertFalse(h.home.isOpen)
        assertEquals(0f, h.screen.root.translationX, 0f)
        assertFalse("back is the activity's again", h.activity.onBackPressedDispatcher.hasEnabledCallbacks())
    }

    @Test fun `a tap on the dimmed chat closes the sidebar`() = withHome { h ->
        h.home.open()
        ShadowLooper.idleMainLooper()
        assertEquals(View.VISIBLE, h.home.scrim.visibility)
        h.home.scrim.performClick()
        ShadowLooper.idleMainLooper()
        assertFalse(h.home.isOpen)
        assertEquals(View.GONE, h.home.scrim.visibility)
    }

    @Test fun `the call button starts a call and the account is only in the sidebar`() = withHome { h ->
        h.topBar.setCall(available = true, live = false)
        h.topBar.callButton.performClick()
        assertEquals(1, h.callsStarted.size)
        assertEquals(0, h.accountOpened.size)
        assertEquals(R.id.chat_call_button, h.topBar.callButton.id)
        assertTrue(descendants(h.topBar).none { it.id == R.id.chat_settings })
        val settings = h.activity.getString(R.string.settings_open)
        assertTrue(descendants(h.home.sidebar.view).any { it.contentDescription == settings })
    }

    @Test fun `the right side is empty until calls are available, and a live call keeps its button`() = withHome { h ->
        assertEquals("unknown availability hides the button", View.GONE, h.topBar.callButton.visibility)
        assertTrue(h.topBar.frostPatches().single { it.key == "call" }.bounds.isEmpty)
        h.topBar.setCall(available = true, live = false)
        assertEquals(View.VISIBLE, h.topBar.callButton.visibility)
        h.topBar.setCall(available = false, live = true)
        assertEquals(View.VISIBLE, h.topBar.callButton.visibility)
        val fill = ((h.topBar.callButton.background as android.graphics.drawable.InsetDrawable).drawable
            as android.graphics.drawable.GradientDrawable).color!!.defaultColor
        assertEquals("a live call fills it with the brand colour", h.activity.getColor(R.color.token_bg_brand_solid), fill)
        h.topBar.setCall(available = false, live = false)
        assertEquals(View.GONE, h.topBar.callButton.visibility)
    }

    @Test fun `the mark is Comma's black logo on a white circle with a hairline edge`() = withHome { h ->
        val mark = h.topBar.avatar
        assertEquals(R.drawable.ic_cue_mark, shadowOf(mark.drawable).createdFromResId)
        val circle = mark.background as android.graphics.drawable.GradientDrawable
        assertEquals(h.activity.getColor(R.color.token_mark_bg), circle.color!!.defaultColor)
        assertEquals(android.graphics.drawable.GradientDrawable.OVAL, circle.shape)
        // The logo fills 16 of its vector's 20 units.
        val logo = (mark.width - mark.paddingLeft - mark.paddingRight) * 16f / 20f
        assertTrue("logo is ${logo / mark.width} of the circle", logo / mark.width in 0.55f..0.6f)
    }

    @Test fun `the capsule always says Comma at one fixed width`() = withHome { h ->
        val lines = descendants(h.topBar).filterIsInstance<android.widget.TextView>().filter { it.text.isNotEmpty() }
        assertEquals(listOf(h.activity.getString(R.string.chat_brand_name)), lines.map { it.text.toString() })
        assertSame(h.topBar.capsule, lines.single())
        val dp = h.activity.resources.displayMetrics.density
        assertEquals((HomeTopBar.CAPSULE_DP * dp).roundToInt(), h.topBar.capsule.height)
        val hug = lines.first().paint.measureText("Comma") + 2 * (HomeTopBar.CAPSULE_PADDING_DP * dp).roundToInt()
        assertEquals("the capsule hugs the name", hug, h.topBar.capsule.width.toFloat(), 1.5f)
    }

    @Test fun `a tap on the capsule opens the sidebar`() = withHome { h ->
        assertFalse(h.home.isOpen)
        h.topBar.capsule.performClick()
        ShadowLooper.idleMainLooper()
        assertTrue(h.home.isOpen)
    }

    @Test fun `the connection notice hangs under the bar, hidden until there is something to say`() = withHome { h ->
        val notice = descendants(h.screen.root).filterIsInstance<ConnectionNoticeView>().single()
        assertEquals(View.GONE, notice.visibility)
        notice.show(ConnectionNotice.OFFLINE)
        ShadowLooper.idleMainLooper()
        assertEquals(View.VISIBLE, notice.visibility)
        assertEquals(h.activity.getString(R.string.chat_paused), notice.text.toString())
        assertEquals("right under the bar", h.topBar.bottom, notice.top)
        assertEquals(0, descendants(notice).filterIsInstance<android.widget.TextView>().single().layout.getEllipsisCount(0))
        notice.show(ConnectionNotice.FAILED)
        assertEquals(h.activity.getString(R.string.chat_session_retry), notice.text.toString())
        notice.show(null)
        ShadowLooper.idleMainLooper()
        assertEquals(View.GONE, notice.visibility)
    }

    @Test fun `sidebar entries open a task, the full list and settings`() = withHome { h ->
        val sidebar = h.home.sidebar
        sidebar.onOpenTask!!.invoke("task-3")
        shadowOf(h.activity).nextStartedActivity.let {
            assertEquals(TaskDetailActivity::class.java.name, it.component!!.className)
            assertEquals("task-3", it.getStringExtra(TaskPages.EXTRA_TASK_ID))
        }
        sidebar.viewAll.performClick()
        assertEquals(TaskListActivity::class.java.name, shadowOf(h.activity).nextStartedActivity.component!!.className)
        sidebar.settings.performClick()
        assertEquals(1, h.settingsOpened.size)
        assertSame(sidebar.view, h.activity.findViewById<View>(R.id.chat_sidebar))
    }

    @Test fun `drags that start on the composer never pull the sidebar`() = withHome { h ->
        val root = h.screen.root
        assertTrue(h.screen.excludesSidebarDragAt(root.width / 2f, root.height - 1f))
        assertFalse(h.screen.excludesSidebarDragAt(root.width / 2f, root.height / 2f))
    }

    private fun descendants(view: View): List<View> =
        listOf(view) + ((view as? ViewGroup)?.let { group -> (0 until group.childCount).flatMap { descendants(group.getChildAt(it)) } } ?: emptyList())
}
