package surf.comma.android.chat.live

import android.os.SystemClock
import android.view.MotionEvent
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import surf.comma.android.ui.composer.demo.ComposerDemoActivity

/** Real IME, finger coordinates and detach while images fly, using only generated local media. */
class ChatImagesInteractionDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun settle() { SystemClock.sleep(1500); instrumentation.waitForIdleSync() }

    @Test fun imageFlightSurvivesKeyboardDragAndConversationReplacement() {
        ActivityScenario.launch(ComposerDemoActivity::class.java).use { scenario ->
            lateinit var fixture: ChatSendFixture
            scenario.onActivity {
                it.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                fixture = ChatSendFixture(it)
            }
            settle()
            main { fixture.draft("An image with text", 1); fixture.keyboard(true) }
            settle()
            main { fixture.send() }
            SystemClock.sleep(100)
            main { assertTrue(fixture.flight.isFlying); fixture.keyboard(false) }
            settle()
            main { fixture.assertGap(); assertFalse(fixture.flight.isFlying) }

            main { fixture.draft("", 3) }
            settle()
            main { fixture.send() }
            SystemClock.sleep(130)
            var x = 0f
            var y = 0f
            main {
                val location = IntArray(2)
                fixture.timeline.getLocationOnScreen(location)
                x = location[0] + fixture.timeline.width / 2f
                y = location[1] + fixture.timeline.height / 3f
            }
            val down = SystemClock.uptimeMillis()
            instrumentation.sendPointerSync(MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, x, y, 0))
            for (step in 1..8) instrumentation.sendPointerSync(MotionEvent.obtain(down, down + 16L * step,
                MotionEvent.ACTION_MOVE, x, y + 30f * step, 0))
            instrumentation.sendPointerSync(MotionEvent.obtain(down, down + 150, MotionEvent.ACTION_UP, x, y + 240f, 0))
            settle()
            main { assertFalse(fixture.flight.isFlying); assertTrue(fixture.timeline.hiddenRows.isEmpty()) }

            main { fixture.timeline.jumpToLatest(); fixture.draft("Changing conversation", 1) }
            settle()
            main { fixture.send() }
            SystemClock.sleep(150)
            val old = fixture
            val images = ArrayList<surf.comma.android.media.SendImagePresentation>()
            main {
                assertTrue(old.flight.isFlying)
                old.rows.forEach { row -> (old.timeline.viewForRow(row.id) as? AttachmentView)?.flightImage?.let(images::add) }
            }
            scenario.onActivity { fixture = ChatSendFixture(it) }
            settle()
            main {
                assertFalse(old.flight.isFlying)
                assertTrue(old.timeline.hiddenRows.isEmpty())
                assertTrue(images.isNotEmpty())
                images.forEach { assertNull(it.preview); assertNull(it.target); assertFalse(it.held) }
                assertTrue(fixture.rows.isEmpty())
            }
        }
    }
}
