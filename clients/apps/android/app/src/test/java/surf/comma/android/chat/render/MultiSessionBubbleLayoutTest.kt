package surf.comma.android.chat.render

import androidx.activity.ComponentActivity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class MultiSessionBubbleLayoutTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val density = activity.resources.displayMetrics.density

    @Test
    fun `multi-session worker row stays flat text with session label when bubbles is false`() {
        val precomputer = MessageLayoutPrecomputer(bubbles = false)
        val workerSessionRow = ChatMessage(
            id = 1L,
            conversationId = "cnv_multi",
            turnId = "t1",
            role = ChatRole.AGENT,
            text = "Audited the contract.",
            createdAt = 1_000L,
            otherWriterName = "Reviewer @reviewer",
            otherWriterId = null,
            writerLabel = true,
            speaker = "worker",
            participantId = "prt_rev",
        )
        val otherPersonRow = ChatMessage(
            id = 2L,
            conversationId = "cnv_multi",
            turnId = "t1",
            role = ChatRole.AGENT,
            text = "Looks good to me.",
            createdAt = 1_001L,
            otherWriterName = "Alice",
            otherWriterId = "usr_alice",
            writerLabel = true,
            speaker = "person:usr_alice",
        )

        val prepared = runBlocking {
            precomputer.prepareChanged(
                emptyList(),
                listOf(workerSessionRow, otherPersonRow),
                viewportWidthPx = (411 * density).toInt(),
                density = density,
                fontScale = 1f,
                darkTheme = false,
            )
        }

        val workerPrepared = prepared.single { it.message.id == 1L }
        assertFalse("multi-session worker row must not draw a bubble when bubbles=false", workerPrepared.drawBubble)
        assertNotNull("multi-session worker row must draw its session label", workerPrepared.writerLabel)

        val personPrepared = prepared.single { it.message.id == 2L }
        assertTrue("another person's message in a Task together keeps its bubble", personPrepared.drawBubble)
        assertNotNull(personPrepared.writerLabel)
    }
}
