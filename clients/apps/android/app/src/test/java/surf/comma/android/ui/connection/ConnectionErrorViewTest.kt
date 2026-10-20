package surf.comma.android.ui.connection

import android.content.res.Configuration
import android.graphics.Rect
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "en-rUS-mdpi")
class ConnectionErrorViewTest {
    @Test fun `builds on the chat screen's own theme`() {
        // The chat screen mounts this page under Theme.Chat, a framework theme, not a Material one.
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Chat)
            controller.setup()
            val page = ConnectionErrorView(activity)
            page.render(ConnectionErrorState(ConnectionErrorReason.OFFLINE, ConnectionRetryTarget.CONVERSATION))
            activity.setContentView(page)
            assertTrue(page.findViewById<View>(R.id.connection_error_retry).isClickable)
        }
    }

    @Test fun `retry progress preserves geometry in the auth and chat hosts in both themes`() {
        for (hostTheme in listOf(R.style.Theme_Comma_Auth, R.style.Theme_Chat))
        for (night in listOf(Configuration.UI_MODE_NIGHT_NO, Configuration.UI_MODE_NIGHT_YES)) {
            Robolectric.buildActivity(ComponentActivity::class.java).use { activityController ->
                val activity = activityController.get()
                activity.setTheme(hostTheme)
                activityController.setup()
                val context = activity.createConfigurationContext(Configuration(activity.resources.configuration).apply { uiMode = night })
                val themed = android.view.ContextThemeWrapper(context, hostTheme)
                val page = ConnectionErrorView(themed)
                activity.setContentView(page)
                val idle = ConnectionErrorState(ConnectionErrorReason.UNREACHABLE, ConnectionRetryTarget.SESSION)
                page.render(idle)
                layout(page, 320, 640)
                val ids = listOf(R.id.connection_error_title, R.id.connection_error_detail, R.id.connection_error_retry, R.id.connection_error_account)
                val before = ids.associateWith { bounds(page, it) }
                for (rect in before.values) {
                    assertTrue(rect.toString(), rect.left >= 0 && rect.right <= 320 && rect.top >= 0 && rect.bottom <= 640)
                }
                var retries = 0
                page.onRetry = { retries++ }
                page.findViewById<View>(R.id.connection_error_retry).performClick()
                assertEquals(1, retries)
                page.render(idle.copy(busy = true))
                layout(page, 320, 640)
                ids.forEach { assertEquals(before[it], bounds(page, it)) }
                assertEquals(View.VISIBLE, page.findViewById<View>(R.id.connection_error_progress).visibility)
                assertFalse(page.findViewById<View>(R.id.connection_error_retry).isClickable)
                assertTrue(page.findViewById<View>(R.id.connection_error_account).isClickable)
            }
        }
    }

    @Test fun `short large text viewport can scroll and keeps full copy`() {
        RuntimeEnvironment.setFontScale(2f)
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Comma_Auth)
            controller.setup()
            val context = activity.createConfigurationContext(Configuration(activity.resources.configuration).apply { fontScale = 2f })
            val page = ConnectionErrorView(android.view.ContextThemeWrapper(context, R.style.Theme_Comma_Auth))
            activity.setContentView(page)
            page.render(ConnectionErrorState(ConnectionErrorReason.OFFLINE, ConnectionRetryTarget.SESSION))
            layout(page, 320, 400)
            val detail = page.findViewById<TextView>(R.id.connection_error_detail)
            assertEquals(context.getString(R.string.connection_offline_detail), detail.text.toString())
            assertNull(detail.ellipsize)
            assertTrue(detail.layout.getEllipsisCount(detail.lineCount - 1) == 0)
            val scroll = page.getChildAt(0) as surf.comma.android.scroll.widget.ScrollContainer
            page.findFocus()?.clearFocus()
            scroll.fullScroll(View.FOCUS_UP)
            assertTrue("page=${page.width}x${page.height}, detail=${bounds(page, R.id.connection_error_detail)}, action=${bounds(page, R.id.connection_error_account)}",
                scroll.fullScroll(View.FOCUS_DOWN))
            val account = Rect()
            assertTrue(page.findViewById<View>(R.id.connection_error_account).getGlobalVisibleRect(account))
            assertTrue("visible account bounds: $account", account.height() >= 48)
        }
    }

    @Test fun `content sits just above the middle in the auth and chat hosts`() {
        for (hostTheme in listOf(R.style.Theme_Comma_Auth, R.style.Theme_Chat))
        for (reason in ConnectionErrorReason.entries) {
            val page = page(hostTheme)
            page.render(ConnectionErrorState(reason, ConnectionRetryTarget.SESSION))
            layout(page, 360, 760)
            val group = Rect()
            leaves(page).forEach { group.union(bounds(page, it)) }
            val centre = group.exactCenterY() / 760
            assertTrue("$reason: centre at $centre of the page, $group", centre in 0.36f..0.48f)
        }
    }

    @Test fun `retry is the primary action and switch account the quiet one`() {
        for (hostTheme in listOf(R.style.Theme_Comma_Auth, R.style.Theme_Chat)) {
            val page = page(hostTheme)
            page.render(ConnectionErrorState(ConnectionErrorReason.SERVICE, ConnectionRetryTarget.SESSION))
            layout(page, 360, 760)
            val retry = page.findViewById<TextView>(R.id.connection_error_retry)
            val account = page.findViewById<TextView>(R.id.connection_error_account)
            val brand = page.context.getColor(R.color.token_bg_brand_solid)
            // Primary: first, filled with the brand colour, larger text.
            assertTrue(bounds(page, R.id.connection_error_retry).bottom <= bounds(page, R.id.connection_error_account).top)
            assertEquals(brand, retry.backgroundTintList!!.defaultColor)
            assertEquals(android.graphics.Color.WHITE, retry.currentTextColor)
            assertTrue(retry.textSize > account.textSize)
            // Secondary: no fill, no brand colour, only as wide as its label, still a full touch target.
            assertEquals(android.graphics.Color.TRANSPARENT, account.backgroundTintList!!.defaultColor)
            assertEquals(page.context.getColor(R.color.token_text_tertiary), account.currentTextColor)
            val box = bounds(page, R.id.connection_error_account)
            assertTrue("secondary $box against primary ${bounds(page, R.id.connection_error_retry)}",
                box.width() < retry.width / 2 && box.width() >= 48 && box.height() >= 48)
            assertTrue(account.isClickable)
        }
    }

    @Test fun `each reason has its own title and the offline badge differs from the server one`() {
        val page = page(R.style.Theme_Comma_Auth)
        val titles = ConnectionErrorReason.entries.map { reason ->
            page.render(ConnectionErrorState(reason, ConnectionRetryTarget.SESSION))
            page.findViewById<TextView>(R.id.connection_error_title).text.toString()
        }
        assertEquals(titles.size, titles.toSet().size)
        fun badge(reason: ConnectionErrorReason): Int {
            page.render(ConnectionErrorState(reason, ConnectionRetryTarget.SESSION))
            return org.robolectric.Shadows.shadowOf(page.findViewById<android.widget.ImageView>(R.id.connection_error_badge).drawable).createdFromResId
        }
        assertEquals(R.drawable.ic_connection_offline, badge(ConnectionErrorReason.OFFLINE))
        assertNotEquals(badge(ConnectionErrorReason.OFFLINE), badge(ConnectionErrorReason.SERVICE))
    }

    @Test fun `the page itself never takes focus`() {
        // With a keyboard the page used to take focus and tint itself with the focus highlight.
        val page = page(R.style.Theme_Chat)
        page.render(ConnectionErrorState(ConnectionErrorReason.OFFLINE, ConnectionRetryTarget.SESSION))
        layout(page, 360, 760)
        assertFalse(page.isFocusable)
        assertTrue(page.isClickable)
        assertTrue(page.findViewById<View>(R.id.connection_error_retry).isFocusable)
    }

    private fun page(hostTheme: Int): ConnectionErrorView {
        val controller = Robolectric.buildActivity(ComponentActivity::class.java)
        val activity = controller.get()
        activity.setTheme(hostTheme)
        controller.setup()
        return ConnectionErrorView(activity).also { activity.setContentView(it) }
    }

    /** Every visible view that draws something itself. */
    private fun leaves(view: View): List<View> = when {
        view.visibility != View.VISIBLE -> emptyList()
        view is android.view.ViewGroup && view.childCount > 0 -> (0 until view.childCount).flatMap { leaves(view.getChildAt(it)) }
        view.width > 0 && view.height > 0 && view !is android.view.ViewGroup -> listOf(view)
        else -> emptyList()
    }
    private fun bounds(page: FrameLayout, view: View) =
        Rect(0, 0, view.width, view.height).also { page.offsetDescendantRectToMyCoords(view, it) }

    private fun layout(page: View, width: Int, height: Int) {
        ShadowLooper.idleMainLooper()
        repeat(2) {
            page.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
            page.layout(0, 0, width, height)
        }
        assertEquals(width, page.width)
        assertEquals(height, page.height)
    }
    private fun bounds(page: FrameLayout, id: Int): Rect {
        val view = page.findViewById<View>(id)
        return Rect(0, 0, view.width, view.height).also { page.offsetDescendantRectToMyCoords(view, it) }
    }
}
