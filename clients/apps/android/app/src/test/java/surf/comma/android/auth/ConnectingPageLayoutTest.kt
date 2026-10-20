package surf.comma.android.auth

import android.animation.ValueAnimator
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.ImageView
import android.widget.TextView
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import java.util.concurrent.TimeUnit

/** Geometry of the connecting page and of its hand-over to the connection error page. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "en-rUS-w360dp-h760dp-xhdpi")
class ConnectingPageLayoutTest {
    private lateinit var controller: ActivityController<AuthActivity>
    private lateinit var activity: AuthActivity
    private val steps = ConnectionStep.entries.map { AuthState.Connecting(it) }

    @Before fun setUp() {
        controller = Robolectric.buildActivity(AuthActivity::class.java).setup()
        activity = controller.get()
        // Let the repository settle, then stop collecting so only the test drives render().
        ShadowLooper.idleMainLooper()
        controller.pause().stop()
        ShadowLooper.idleMainLooper()
    }

    @After fun tearDown() {
        setAnimatorScale(1f)
        controller.close()
    }

    @Test fun contentSitsJustAboveTheMiddle() {
        for (state in steps) {
            show(state)
            val group = union(content())
            val centre = group.exactCenterY() / pageHeight()
            assertTrue("$state: centre at $centre of the page, $group", centre in 0.36f..0.48f)
        }
    }

    @Test fun changingTheStepMovesNothing() {
        // A retry countdown makes the longest line; it must not push anything either.
        val states = steps + AuthState.Connecting(ConnectionStep.WORKSPACE, retryAtMillis = System.currentTimeMillis() + 30_000)
        val seen = states.map { state ->
            show(state)
            listOf(bounds(mark()).top, bounds(title()).top, bounds(spinner()), bounds(switchAccount()))
        }
        seen.forEachIndexed { index, geometry -> assertEquals("${states[index]}", seen[0], geometry) }
    }

    @Test fun spinnerIsTheSameSizeInEveryState() {
        val expected = dp(24)
        for (animatorScale in listOf(1f, 0f)) {
            setAnimatorScale(animatorScale)
            for (state in listOf(AuthState.Starting) + steps) {
                show(state)
                val spinner = spinner()
                assertEquals("$state", expected, spinner.width)
                assertEquals("$state", expected, spinner.height)
                // What is drawn matters as much as the view's size: an arc that has collapsed
                // to a point still sits in a full-size view.
                val ink = ink(spinner)
                assertTrue("$state, animator scale $animatorScale: drew $ink in $expected px",
                    ink.width() >= expected * 0.75f && ink.height() >= expected * 0.75f)
            }
        }
    }

    @Test fun switchAccountIsQuietButStillTappable() {
        show(steps[1])
        val button = switchAccount()
        val box = bounds(button)
        assertEquals(activity.getColor(R.color.token_text_quaternary), button.currentTextColor)
        assertTrue(button.textSize < body().textSize)
        assertTrue("below the content, near the bottom: $box", box.top > pageHeight() * 0.7f)
        assertTrue(button.isClickable && button.isEnabled)
        assertTrue("touch target $box", box.width() >= dp(48) && box.height() >= dp(48))
    }

    @Test fun markAndTitleStayPutWhenConnectingFails() {
        show(steps[0])
        val connecting = bounds(mark()) to bounds(title()).top
        show(AuthState.Retry(AuthProblem.NETWORK))
        val page = activity.findViewById<ViewGroup>(R.id.connection_error_page)
        assertEquals(View.VISIBLE, page.visibility)
        val failed = bounds(visible(page).filterIsInstance<ImageView>().minBy { bounds(it).top }) to
            bounds(page.findViewById(R.id.connection_error_title)).top
        assertEquals(connecting, failed)
        // Retrying keeps the same page, so nothing moves on the way back either.
        show(steps[0])
        assertEquals(View.VISIBLE, page.visibility)
        assertEquals(failed.second, bounds(page.findViewById(R.id.connection_error_title)).top)
    }

    private fun show(state: AuthState) {
        activity.render(state)
        ShadowLooper.idleMainLooper(1, TimeUnit.SECONDS)
        val decor = activity.window.decorView
        decor.measure(View.MeasureSpec.makeMeasureSpec(decor.width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(decor.height, View.MeasureSpec.EXACTLY))
        decor.layout(0, 0, decor.width, decor.height)
    }

    private fun pageHeight() = activity.findViewById<View>(android.R.id.content).height.also { assertTrue(it > 0) }

    /** Views a person can see on the page in front, in drawing order. */
    private fun visible(root: View = activity.findViewById(android.R.id.content)): List<View> {
        val out = mutableListOf<View>()
        fun walk(view: View) {
            if (view.visibility != View.VISIBLE || view.alpha == 0f) return
            out += view
            if (view is ViewGroup) for (i in 0 until view.childCount) walk(view.getChildAt(i))
        }
        walk(root)
        return out
    }

    private fun text(resource: Int) = visible().filterIsInstance<TextView>().single { it.text.toString() == activity.getString(resource) }
    private fun title() = text(R.string.auth_connecting_title)
    private fun body() = visible().filterIsInstance<TextView>().first { it !is Button && it !== title() && it.text.isNotEmpty() }
    private fun mark() = visible().filterIsInstance<ImageView>().single()
    private fun switchAccount() = text(R.string.auth_switch_account)
    private fun spinner() = visible().single { it.javaClass.simpleName in setOf("ProgressBar", "ConnectionSpinner") }

    /** The mark, the two lines of text and the spinner: what reads as the page's content. */
    private fun content() = listOf(mark(), title(), body(), spinner())

    private fun bounds(view: View): Rect {
        val root = activity.findViewById<ViewGroup>(android.R.id.content)
        return Rect(0, 0, view.width, view.height).also { root.offsetDescendantRectToMyCoords(view, it) }
    }
    private fun union(views: List<View>) = Rect().apply { views.forEach { union(bounds(it)) } }

    /** Bounding box of the pixels a view draws. */
    private fun ink(view: View): Rect {
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        val box = Rect()
        for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
            if (bitmap.getPixel(x, y) ushr 24 > 32) box.union(x, y, x + 1, y + 1)
        }
        return box
    }

    private fun setAnimatorScale(scale: Float) {
        ValueAnimator::class.java.getMethod("setDurationScale", Float::class.javaPrimitiveType).invoke(null, scale)
    }

    private fun dp(value: Int) = (value * activity.resources.displayMetrics.density).toInt()
}
