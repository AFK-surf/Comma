package surf.comma.android.settings

import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.BackEventCompat
import androidx.activity.ComponentActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import java.util.concurrent.TimeUnit

/**
 * Settings in a wide window: the list keeps the leading column while pages push in beside it, and the first page
 * beside the list leaves with back without following the finger. Narrow windows stack every page full width.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class PageHostColumnsTest {
    private class Page(override val key: String, activity: ComponentActivity) : SettingsPage {
        override val view: View = View(activity)
    }

    private fun host(widthDp: Int, heightDp: Int): Triple<ComponentActivity, PageHost, Page> {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val host = PageHost(activity) {}.apply { keepsRoot = true }
        val density = activity.resources.displayMetrics.density
        activity.setContentView(FrameLayout(activity).apply {
            addView(host, FrameLayout.LayoutParams((widthDp * density).toInt(), (heightDp * density).toInt()))
        }, ViewGroup.LayoutParams(-1, -1))
        val root = Page("root", activity)
        host.push(root, animate = false)
        layout(host, widthDp, heightDp)
        return Triple(activity, host, root)
    }

    private fun layout(host: PageHost, widthDp: Int, heightDp: Int) {
        val density = host.resources.displayMetrics.density
        host.measure(View.MeasureSpec.makeMeasureSpec((widthDp * density).toInt(), View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec((heightDp * density).toInt(), View.MeasureSpec.EXACTLY))
        host.layout(0, 0, host.measuredWidth, host.measuredHeight)
        ShadowLooper.idleMainLooper(2, TimeUnit.SECONDS)
    }

    @Test
    fun wideWindowsKeepTheListBesideThePages() {
        val (activity, host, root) = host(1000, 800)
        assertTrue(host.columns)
        val detail = Page("detail", activity)
        host.push(detail)
        layout(host, 1000, 800)
        assertEquals(0, root.view.left)
        assertTrue("the list keeps a leading column", root.view.width in 1 until host.width)
        assertEquals("the page sits beside the list", root.view.width, detail.view.left)
        assertEquals(host.width, detail.view.right)
        assertEquals("the list does not slide aside", 0f, root.view.translationX)

        host.backCallback.handleOnBackStarted(BackEventCompat(10f, 10f, 0f, BackEventCompat.EDGE_LEFT))
        host.backCallback.handleOnBackProgressed(BackEventCompat(200f, 10f, 0.5f, BackEventCompat.EDGE_LEFT))
        assertEquals("the first page beside the list does not follow the finger", 0f, detail.view.translationX)
        host.backCallback.handleOnBackPressed()
        ShadowLooper.idleMainLooper(2, TimeUnit.SECONDS)
        assertEquals(listOf("root"), host.keys)
    }

    @Test
    fun narrowWindowsStackPagesFullWidth() {
        val (activity, host, root) = host(400, 800)
        assertFalse(host.columns)
        val detail = Page("detail", activity)
        host.push(detail, animate = false)
        layout(host, 400, 800)
        assertEquals(host.width, root.view.width)
        assertEquals(0, detail.view.left)
        assertEquals(host.width, detail.view.width)
    }

    @Test
    fun aPhoneOnItsSideKeepsOneColumn() {
        val (_, host, _) = host(900, 400)
        assertFalse(host.columns)
    }
}
