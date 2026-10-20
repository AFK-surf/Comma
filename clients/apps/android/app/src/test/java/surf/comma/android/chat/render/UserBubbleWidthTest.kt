package surf.comma.android.chat.render

import androidx.activity.ComponentActivity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import kotlin.math.abs
import kotlin.math.ceil

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class UserBubbleWidthTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val density = activity.resources.displayMetrics.density

    @Test fun `a message shorter than the minimum bubble is centred in it`() {
        val item = prepare("hi")
        val text = item.blocks.single() as PreparedContentBlock.Text
        val textWidth = ceil(text.layout.getLineWidth(0)).toInt()
        val left = item.horizontalPaddingPx + text.padPx + text.leftInsetPx
        val right = item.bubbleWidthPx - left - textWidth

        assertTrue("the bubble should be widened to its minimum", item.bubbleWidthPx > textWidth + item.horizontalPaddingPx * 2)
        assertTrue("left $left vs right $right", abs(left - right) <= 1)
    }

    @Test fun `a message wider than the minimum keeps its usual padding`() {
        val text = prepare("a longer message than the minimum").blocks.single() as PreparedContentBlock.Text

        assertEquals(0, text.leftInsetPx)
    }

    private fun prepare(text: String): PreparedChatMessage = runBlocking {
        MessageLayoutPrecomputer().prepare(
            listOf(ChatMessage(id = 1, conversationId = "c", turnId = "r:1", role = ChatRole.USER, text = text,
                createdAt = 1, status = MessageStatus.COMPLETED, requestId = "1")),
            viewportWidthPx = 1080, density = density, fontScale = 1f, darkTheme = false,
        ).single()
    }
}
