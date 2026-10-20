package surf.comma.android.ui.composer

import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.children
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.R

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class HoldOverlayViewTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get().apply {
        setTheme(R.style.Theme_Chat)
    }
    private val overlay = HoldOverlayView(activity, ComposerStyle(activity))

    @Test fun `partial transcripts replace the listening placeholder as they arrive`() {
        assertEquals(activity.getString(R.string.composer_listening), overlay.bubble.text.toString())

        listOf("今天", "今天天气", "今天天气怎么样").forEach { partial ->
            overlay.setTranscript(partial)
            assertEquals(partial, overlay.bubble.text.toString())
        }
        overlay.setTranscript("今天天气怎么样？")
        assertEquals("今天天气怎么样？", overlay.bubble.text.toString())
    }

    @Test fun `the cancel zone keeps the words, dims them and says release cancels`() {
        overlay.setTranscript("今天天气")
        val sendColour = overlay.bubble.currentTextColor

        overlay.setCancelZone(true)
        assertEquals("今天天气", overlay.bubble.text.toString())
        assertTrue(overlay.bubble.currentTextColor != sendColour)
        assertEquals(activity.getString(R.string.composer_hold_cancel_hint), caption().text.toString())

        overlay.setCancelZone(false)
        assertEquals(sendColour, overlay.bubble.currentTextColor)
        assertEquals(activity.getString(R.string.composer_hold_hint), caption().text.toString())
    }

    @Test fun `releasing keeps the heard words while the final text is awaited`() {
        overlay.setTranscript("今天天气")
        overlay.showRecognizing()
        assertEquals("今天天气", overlay.bubble.text.toString())
        assertEquals(View.INVISIBLE, caption().visibility)

        overlay.reset()
        overlay.setTranscript("")
        overlay.showRecognizing()
        assertEquals(activity.getString(R.string.composer_recognizing), overlay.bubble.text.toString())
    }

    @Test fun `long dictation keeps the newest words in the bubble`() {
        val long = "开头" + "字".repeat(300) + "结尾"
        overlay.setTranscript(long)

        val shown = overlay.bubble.text.toString()
        assertTrue(shown.startsWith("…"))
        assertTrue(shown.endsWith("结尾"))
        assertTrue(shown.length < long.length)
    }

    @Test fun `the bubble is centred on the page and the hint sits above the composer`() {
        val bubble = overlay.bubble.layoutParams as FrameLayout.LayoutParams
        assertEquals(android.view.Gravity.CENTER, bubble.gravity)

        overlay.setBottomClearance(200)
        val hint = caption().layoutParams as FrameLayout.LayoutParams
        assertTrue(hint.bottomMargin > 200)
    }

    private fun caption(): TextView = overlay.children.filterIsInstance<TextView>().single { it !== overlay.bubble }
}
