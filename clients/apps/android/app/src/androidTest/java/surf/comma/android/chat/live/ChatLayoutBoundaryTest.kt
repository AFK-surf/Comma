package surf.comma.android.chat.live

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.net.Uri
import android.os.SystemClock
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import androidx.core.view.ViewCompat
import androidx.core.content.FileProvider
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.lifecycleScope
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.launch
import org.junit.Assert.*
import org.junit.Test
import surf.comma.android.R
import surf.comma.android.chat.model.ChatAttachment
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.media.*
import surf.comma.android.ui.composer.AttachmentUploadState
import surf.comma.android.ui.composer.ComposerView
import surf.comma.android.ui.composer.demo.ComposerDemoActivity
import java.io.File
import kotlin.math.roundToInt

/** Offline device regression using the real composer, image rows, send flight and :scroll list. */
class ChatLayoutBoundaryTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun settle() { SystemClock.sleep(1200); instrumentation.waitForIdleSync() }

    @Test fun imagesKeyboardAndHistoryShareTheComposerBoundary() {
        ActivityScenario.launch(ComposerDemoActivity::class.java).use { scenario ->
            lateinit var fixture: ChatSendFixture
            scenario.onActivity { fixture = ChatSendFixture(it) }
            settle()

            // Text + a vertical image, sent with a real IME and a multiline composer open.
            main { fixture.draft("Layout sample\nsecond line\nthird line", 1); fixture.keyboard(true) }
            settle()
            main {
                assertTrue("real IME opened", fixture.composer.liftPx > 0f)
                assertNotNull("synthetic thumbnail loaded", fixture.composer.captureSendSnapshot().attachments.first().bitmap)
                fixture.send()
            }
            SystemClock.sleep(120)
            main { assertTrue("send flight active", fixture.flight.isFlying) }
            capture("text-tall-flight")
            settle()
            main { fixture.assertGap(); assertFalse(fixture.flight.isFlying) }
            capture("text-tall-ime")

            // Keyboard descent/ascent and attachment-strip collapse keep exactly the same gap.
            for (shown in listOf(false, true, false)) {
                main { fixture.keyboard(shown) }
                settle()
                main { fixture.assertGap() }
            }
            capture("keyboard-closed")

            for (count in listOf(1, 3)) {
                main { fixture.draft("", count); fixture.keyboard(true) }
                settle()
                main { fixture.send() }
                settle()
                main {
                    fixture.assertGap()
                    assertFalse(fixture.flight.isFlying)
                    assertTrue("older images remain scrollable", fixture.timeline.canScrollVertically(-1))
                }
                capture("images-$count-ime")
            }

            main { fixture.keyboard(false); fixture.timeline.revealRow(1) }
            settle()
            var anchor: ChatTimelineView.VisibleAnchor? = null
            main {
                assertFalse(fixture.timeline.isPinnedToEnd())
                anchor = fixture.timeline.visibleAnchor()
                assertNotNull(anchor)
                fixture.appendHistoryUpdate()
            }
            settle()
            main {
                assertFalse(fixture.timeline.isPinnedToEnd())
                assertEquals(anchor, fixture.timeline.visibleAnchor())
                fixture.keyboard(true)
            }
            settle()
            main {
                assertFalse(fixture.timeline.isPinnedToEnd())
                assertEquals(anchor, fixture.timeline.visibleAnchor())
            }
            capture("reading-history")
        }
    }

    private fun capture(name: String) {
        val image = instrumentation.uiAutomation.takeScreenshot()
        val directory = File(instrumentation.targetContext.getExternalFilesDir(null), "chat-layout-check").apply { mkdirs() }
        File(directory, "$name.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()
    }
}
