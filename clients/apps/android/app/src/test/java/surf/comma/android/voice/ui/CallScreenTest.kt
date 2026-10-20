package surf.comma.android.voice.ui

import android.Manifest
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.graphics.ColorUtils
import androidx.core.view.children
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.voice.CallController
import surf.comma.android.voice.CallPhase
import surf.comma.android.voice.CallResult
import surf.comma.android.voice.CallState
import kotlin.math.roundToInt

/** The call surface over the chat: when it shows, what it says, and how it folds into its card. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w360dp-h740dp-xxhdpi")
class CallScreenTest {
    @Before fun reset() {
        // Springs land at once, as with "remove animations"; the motion itself is checked on a device.
        setDurationScale(0f)
        CallController::class.java.getDeclaredField("instance").apply { isAccessible = true }.set(null, null)
        CallUiMemory.minimized = false
        CallUiMemory.presentedKey = null
        CallUiMemory.terminalAt.clear()
        CallUiMemory.dismissed.clear()
        CallUiMemory.ending.clear()
    }

    @After fun restore() = setDurationScale(1f)

    private fun setDurationScale(scale: Float) {
        android.animation.ValueAnimator::class.java.getDeclaredMethod("setDurationScale", Float::class.javaPrimitiveType)
            .invoke(null, scale)
    }

    private class Call(val activity: ComponentActivity, val screen: CallScreen, val controller: CallController) {
        val status: TextView get() = screen.findViewById(R.id.call_status)
        val id: Long get() = controller.state.value.id
        fun string(res: Int) = activity.getString(res)
        fun update(phase: CallPhase, connectedAt: Long? = null) {
            controller.update(id) { it.copy(call = CallState(phase = phase), connectedAtElapsedRealtime = connectedAt) }
            ShadowLooper.idleMainLooper()
        }
        fun finish(phase: CallPhase, result: CallResult) {
            controller.finish(id, CallState(phase = phase, result = result))
            ShadowLooper.idleMainLooper()
        }
    }

    private fun <T> withCall(block: (Call) -> T): T =
        Robolectric.buildActivity(ComponentActivity::class.java).use { built ->
            val activity = built.get()
            activity.setTheme(R.style.Theme_Chat)
            built.setup()
            shadowOf(activity.application).grantPermissions(Manifest.permission.RECORD_AUDIO)
            activity.setContentView(FrameLayout(activity))
            val controller = CallController.get(activity)
            val screen = CallScreen(activity, controller)
            activity.addContentView(screen, FrameLayout.LayoutParams(-1, -1))
            ShadowLooper.idleMainLooper()
            block(Call(activity, screen, controller))
        }

    private fun Call.start() {
        controller.start()
        screen.expand()
        ShadowLooper.idleMainLooper()
    }

    @Test fun `nothing shows without a call`() = withCall { c ->
        assertEquals(View.GONE, c.screen.visibility)
    }

    @Test fun `a new call opens the full page, calling`() = withCall { c ->
        c.start()
        assertEquals(View.VISIBLE, c.screen.visibility)
        assertEquals(c.string(R.string.call_calling), c.status.text.toString())
        assertEquals("the page fills the screen", 0f, c.screen.cardTop(), 0f)
        assertEquals(c.screen.height.toFloat(), c.screen.cardBottom(), 0f)
        assertTrue(c.screen.findViewById<View>(R.id.call_end).isClickable)
    }

    @Test fun `connected, the status is a timer from the connection`() = withCall { c ->
        c.start()
        c.update(CallPhase.Connected, connectedAt = SystemClock.elapsedRealtime() - 27_400)
        assertEquals("0:27", c.status.text.toString())
        ShadowLooper.idleMainLooper(1_000L, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals("0:28", c.status.text.toString())
    }

    @Test fun `the page puts minimize above the identity and mute end output evenly across the bottom`() = withCall { c ->
        c.start()
        fun bounds(id: Int): android.graphics.Rect {
            val view = c.screen.findViewById<View>(id)
            val location = IntArray(2).also(view::getLocationInWindow)
            return android.graphics.Rect(location[0], location[1], location[0] + view.width, location[1] + view.height)
        }
        val mute = bounds(R.id.call_mute)
        val end = bounds(R.id.call_end)
        val output = bounds(R.id.call_output)
        val minimize = bounds(R.id.call_toggle)
        assertTrue("Mute is on the left, End in the middle, Output on the right",
            mute.right < end.left && end.right < output.left)
        assertEquals("controls share the same baseline", mute.top, output.top)
        assertTrue("controls have equal spacing", kotlin.math.abs(
            (end.centerX() - mute.centerX()) - (output.centerX() - end.centerX())) <= 1)
        assertTrue("minimize is in the top-left corner", minimize.right < c.screen.width / 2 && minimize.bottom < c.status.y)
        assertTrue("identity sits between the header and controls", c.status.y > c.screen.height / 3 && c.status.y < mute.top)
        val commands = mutableListOf<CallController.Command>()
        c.controller.attach(c.id) { commands += it }
        c.screen.findViewById<View>(R.id.call_mute).performClick()
        assertEquals("the left button still sends mute", listOf(CallController.Command.Mute(true)), commands)
        assertTrue("rearranging the controls does not end the call", c.controller.state.value.busy)
    }

    @Test
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun `the avatar stays legible when the light page folds into its dark card`() = withCall(::checkAvatarContrast)

    @Test
    @Config(qualifiers = "w360dp-h740dp-night-xxhdpi")
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun `the avatar stays legible on the dark page and card`() = withCall(::checkAvatarContrast)

    private fun checkAvatarContrast(c: Call) {
        c.start()
        val avatar = c.screen.children.filterIsInstance<CallAvatar>().single()
        val bitmap = Bitmap.createBitmap(avatar.width, avatar.height, Bitmap.Config.ARGB_8888)
        try {
            for (minimized in listOf(false, true, false)) {
                if (minimized) c.screen.minimize() else c.screen.expand()
                ShadowLooper.idleMainLooper()
                avatar.draw(Canvas(bitmap))
                val mark = bitmap.getPixel(bitmap.width / 2, bitmap.height / 2)
                val surface = bitmap.getPixel(bitmap.width / 2, bitmap.height / 4)
                assertTrue("the rendered mark contrasts with its circle, minimized=$minimized",
                    ColorUtils.calculateContrast(mark, surface) >= 3.0)
            }
        } finally {
            bitmap.recycle()
        }
    }

    @Test fun `minimized, it is a card hanging from the top and the chat around it takes touches`() = withCall { c ->
        c.start()
        c.screen.findViewById<View>(R.id.call_toggle).performClick()
        ShadowLooper.idleMainLooper()
        val density = c.activity.resources.displayMetrics.density
        assertEquals((8 * density), c.screen.cardTop(), 0.5f)
        val tall = (c.screen.cardBottom() - c.screen.cardTop()) / density
        assertTrue("about 300 dp tall under a status bar, not $tall", tall in 220f..320f)
        assertTrue(c.screen.findViewById<View>(R.id.call_card_end).isClickable)
        assertFalse(c.screen.findViewById<View>(R.id.call_end).isClickable)
        val below = MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, 100f, c.screen.height - 10f, 0)
        assertFalse("a tap below the card goes to the chat", c.screen.dispatchTouchEvent(below))
        val toggle = c.screen.findViewById<View>(R.id.call_toggle)
        assertEquals(c.string(R.string.call_expand), toggle.contentDescription)
        toggle.performClick()
        ShadowLooper.idleMainLooper()
        assertEquals(0f, c.screen.cardTop(), 0f)
        assertEquals((48 * density).roundToInt(), toggle.width)
    }

    @Test fun `back minimizes an expanded call instead of ending it`() = withCall { c ->
        c.start()
        c.activity.onBackPressedDispatcher.onBackPressed()
        ShadowLooper.idleMainLooper()
        assertTrue(CallUiMemory.minimized)
        assertTrue(c.controller.state.value.busy)
        assertEquals(View.VISIBLE, c.screen.visibility)
    }

    @Test fun `the card's End ends the call in one tap, says so, then goes`() = withCall { c ->
        c.start()
        c.screen.minimize()
        ShadowLooper.idleMainLooper()
        c.screen.findViewById<View>(R.id.call_card_end).performClick()
        assertTrue(c.id in CallUiMemory.ending)
        assertEquals(c.string(R.string.call_ended), c.status.text.toString())
        assertFalse(c.screen.findViewById<View>(R.id.call_card_end).isEnabled)
        ShadowLooper.idleMainLooper(700L, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals(View.VISIBLE, c.screen.visibility)
        ShadowLooper.idleMainLooper(1_000L, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals("gone without the service closing the call", View.GONE, c.screen.visibility)
    }

    @Test fun `the page's End ends the call in one tap and the service's Ended does not stretch the beat`() = withCall { c ->
        c.start()
        c.screen.findViewById<View>(R.id.call_end).performClick()
        assertEquals(c.string(R.string.call_ended), c.status.text.toString())
        ShadowLooper.idleMainLooper(300L, java.util.concurrent.TimeUnit.MILLISECONDS)
        c.finish(CallPhase.Ended, CallResult.Ended)
        ShadowLooper.idleMainLooper(1_400L, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals(View.GONE, c.screen.visibility)
    }

    @Test fun `an ended call says so for a second and a half, then goes`() = withCall { c ->
        c.start()
        c.finish(CallPhase.Ended, CallResult.Ended)
        assertEquals(c.string(R.string.call_ended), c.status.text.toString())
        assertFalse(c.screen.findViewById<View>(R.id.call_end).isEnabled)
        ShadowLooper.idleMainLooper(1_400L, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals(View.VISIBLE, c.screen.visibility)
        ShadowLooper.idleMainLooper(200L, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals(View.GONE, c.screen.visibility)
    }

    @Test fun `a call that did not connect says why for four seconds`() = withCall { c ->
        c.start()
        c.finish(CallPhase.Failed, CallResult.Busy)
        assertEquals(c.string(R.string.call_not_connected), c.status.text.toString())
        ShadowLooper.idleMainLooper(3_900L, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals(View.VISIBLE, c.screen.visibility)
        ShadowLooper.idleMainLooper(200L, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals(View.GONE, c.screen.visibility)
    }

    @Test fun `a start refused for the microphone explains, and explains again the next time`() = withCall { c ->
        shadowOf(c.activity.application).denyPermissions(Manifest.permission.RECORD_AUDIO)
        c.controller.start()
        c.screen.revealCurrent()
        ShadowLooper.idleMainLooper()
        assertEquals(c.string(R.string.call_microphone_settings), c.status.text.toString())
        ShadowLooper.idleMainLooper(4_100L, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertEquals(View.GONE, c.screen.visibility)
        c.controller.start()
        c.screen.revealCurrent()
        ShadowLooper.idleMainLooper()
        assertEquals(View.VISIBLE, c.screen.visibility)
    }

    @Test fun `mute and its label follow the call`() = withCall { c ->
        c.start()
        c.controller.update(c.id) { it.copy(muted = true) }
        ShadowLooper.idleMainLooper()
        val mute = c.screen.findViewById<View>(R.id.call_mute)
        assertEquals(c.string(R.string.call_unmute), mute.contentDescription)
    }
}
