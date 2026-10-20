package surf.comma.android.chat.live

import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Bitmap
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.RootMatchers.isPlatformPopup
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import surf.comma.android.R
import surf.comma.android.chat.demo.ChatBubblesDemoActivity
import surf.comma.android.chat.render.ChatMessageCell
import surf.comma.android.chat.render.FlightTarget
import surf.comma.android.ui.composer.demo.ComposerDemoActivity
import java.io.File

/**
 * On a device, with made-up messages only: a sent message flies into a bubble with a tail; long
 * press opens the message menu, whose copy, like the reply's copy button and a code block's copy,
 * puts the right text on the clipboard. Screens are saved to the app's external files, under
 * `bubbles/`, for review.
 */
@RunWith(AndroidJUnit4::class)
class ChatBubblesDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val out = File(context.getExternalFilesDir(null), "bubbles").apply { mkdirs() }

    private fun shot(name: String) {
        instrumentation.waitForIdleSync()
        val bitmap = instrumentation.uiAutomation.takeScreenshot() ?: return
        File(out, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private fun settle(ms: Long = 900) {
        instrumentation.waitForIdleSync()
        SystemClock.sleep(ms)
    }

    private fun <T> main(block: () -> T): T {
        var result: T? = null
        instrumentation.runOnMainSync { result = block() }
        @Suppress("UNCHECKED_CAST") return result as T
    }

    private fun clipboard(): String = main {
        context.getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.text?.toString().orEmpty()
    }

    /**
     * Waits until the system's clipboard preview, shown after each copy, has gone: it sits over
     * the bottom of the screen and would take the next touch there.
     */
    private fun awaitNoClipboardOverlay() {
        val until = SystemClock.uptimeMillis() + 12_000
        while (SystemClock.uptimeMillis() < until) {
            val titles = instrumentation.uiAutomation.windows.map { it.title?.toString().orEmpty() }
            if (titles.none { it.contains("clipboard", ignoreCase = true) }) return
            SystemClock.sleep(250)
        }
    }

    /** A real touch on the screen at [x], [y], held for [holdMs]. */
    private fun press(x: Float, y: Float, holdMs: Long) {
        val down = SystemClock.uptimeMillis()
        fun event(action: Int, at: Long) = MotionEvent.obtain(down, at, action, x, y, 0).apply {
            source = InputDevice.SOURCE_TOUCHSCREEN
        }
        instrumentation.uiAutomation.injectInputEvent(event(MotionEvent.ACTION_DOWN, down), true)
        SystemClock.sleep(holdMs)
        instrumentation.uiAutomation.injectInputEvent(event(MotionEvent.ACTION_UP, SystemClock.uptimeMillis()), true)
        instrumentation.waitForIdleSync()
    }

    private fun screenCenter(view: View, dxFraction: Float = 0.5f, dy: Float = view.height / 2f): Pair<Float, Float> {
        val at = IntArray(2)
        view.getLocationOnScreen(at)
        return at[0] + view.width * dxFraction to at[1] + dy
    }

    private fun demo(scene: String, night: Boolean) = ActivityScenario.launch<ChatBubblesDemoActivity>(
        Intent(context, ChatBubblesDemoActivity::class.java).putExtra("scene", scene).putExtra("night", night))

    @Test fun sentMessageFliesIntoATailedBubble() {
        awaitNoClipboardOverlay()
        ActivityScenario.launch(ComposerDemoActivity::class.java).use { scenario ->
            lateinit var fixture: ChatSendFixture
            scenario.onActivity { fixture = ChatSendFixture(it, bubbles = true) }
            settle()
            main { fixture.draft("Earlier message", 0); fixture.send() }
            settle()
            val turn = main { fixture.lastSend().single().turnId }
            main { fixture.reply(turn, "A reply") }
            settle()
            main { fixture.draft("Short sample", 0) }
            settle(300)
            shot("flight-0-before")
            main { fixture.send() }
            for (ms in listOf(60L, 140L, 260L, 420L)) {
                SystemClock.sleep(if (ms == 60L) 60 else 100)
                instrumentation.uiAutomation.takeScreenshot()?.let { bitmap ->
                    File(out, "flight-1-${ms}ms.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                }
            }
            settle()
            shot("flight-2-landed")
            val id = main { fixture.lastSend().single().id }
            val cell = main { fixture.timeline.viewForRow(id) } as ChatMessageCell
            assertTrue("the landed bubble has its tail", main { (cell as FlightTarget).flightTailPx } > 0f)
            assertEquals("fully shown once landed", 1f, main { cell.alpha }, 0f)
            main { fixture.assertGap() }
            // The tail is drawn in the bubble's own colour (still translucent while sending): just
            // below the bubble near its right side, the screen matches the inside of the bubble.
            val bitmap = instrumentation.uiAutomation.takeScreenshot()
            val bounds = android.graphics.RectF()
            main { (cell as FlightTarget).flightBounds(bounds) }
            val at = IntArray(2)
            main { cell.getLocationOnScreen(at) }
            val density = context.resources.displayMetrics.density
            val x = (at[0] + bounds.right - 12 * density).toInt()
            val y = (at[1] + bounds.bottom + 2 * density).toInt()
            val inside = bitmap.getPixel((at[0] + bounds.left + 6 * density).toInt(), (at[1] + bounds.centerY()).toInt())
            assertEquals(inside, bitmap.getPixel(x, y))
            assertTrue("not the page", inside != bitmap.getPixel(x, (at[1] + bounds.bottom + 9 * density).toInt()))
        }
    }

    private fun longPressMenuCopiesTheMessage(night: Boolean) {
        demo("notice", night).use { scenario ->
            settle(1500)
            lateinit var activity: ChatBubblesDemoActivity
            scenario.onActivity { activity = it }
            val timeline = activity.timeline
            val firstAnswer = "Creating it now."
            val row = main {
                (0 until timeline.childCount).map(timeline::getChildAt).filterIsInstance<ChatMessageCell>()
                    .first { it.contentDescription?.toString()?.endsWith(firstAnswer) == true }
            }
            awaitNoClipboardOverlay()
            val (x, y) = main { screenCenter(row, 0.25f) }
            press(x, y, 800)
            settle(400)
            onView(withText(R.string.action_copy_message)).inRoot(isPlatformPopup()).check(matches(isDisplayed()))
            shot("menu-${if (night) "dark" else "light"}")
            onView(withText(R.string.action_copy_message)).inRoot(isPlatformPopup()).perform(click())
            settle(300)
            assertEquals(firstAnswer, clipboard())

            // The reply's copy button copies both answers around the system notice, once.
            val actions = main {
                (0 until timeline.childCount).map(timeline::getChildAt).filterIsInstance<ReplyActionsRow>()
            }
            assertEquals("one set of buttons for the reply", 1, actions.size)
            awaitNoClipboardOverlay()
            val (bx, by) = main { screenCenter(actions.single().getChildAt(0)) }
            press(bx, by, 60)
            settle(300)
            shot("reply-copied-${if (night) "dark" else "light"}")
            assertEquals("Creating it now.\n\nDone. I invited the team.", clipboard())
        }
    }

    @Test fun longPressMenuAndReplyCopyInLight() = longPressMenuCopiesTheMessage(night = false)

    @Test fun longPressMenuAndReplyCopyInDark() = longPressMenuCopiesTheMessage(night = true)

    @Test fun codeBlockCopyButtonCopiesTheCode() {
        demo("code", false).use { scenario ->
            settle(1500)
            lateinit var activity: ChatBubblesDemoActivity
            scenario.onActivity { activity = it }
            val timeline = activity.timeline
            val row = main {
                (0 until timeline.childCount).map(timeline::getChildAt).filterIsInstance<ChatMessageCell>()
                    .first { it.contentDescription?.toString()?.contains("```kotlin") == true }
            }
            assertNotNull(row)
            // The copy label sits at the right end of the code block's header, the first block after one line of text.
            val density = context.resources.displayMetrics.density
            val bubbleLeft = main { IntArray(2).also(row::getLocationOnScreen) }
            val bubbleWidth = main { (row.width - 28 * density * 2 - 42 * density) }
            // Find the header by scanning down the bubble's right inner edge for the code box.
            val shot = instrumentation.uiAutomation.takeScreenshot()
            val x = (bubbleLeft[0] + 28 * density + bubbleWidth - 13 * density - 20 * density).toInt()
            val box = context.getColor(R.color.token_bg_primary)
            // From inside the grey bubble, under its top margin, down to the code box.
            var y = maxOf(bubbleLeft[1] + (34 * density).toInt(), (40 * density).toInt())
            while (y < bubbleLeft[1] + row.height && shot.getPixel(x, y) != box) y++
            awaitNoClipboardOverlay()
            press(x.toFloat(), y + 17 * density, 60)
            settle(300)
            assertTrue("copied the code: ${clipboard()}", clipboard().startsWith("suspend fun <T> retrying"))
            shot("code-copied")
        }
    }
}
