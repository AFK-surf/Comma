package surf.comma.android.chat.render

import androidx.activity.ComponentActivity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus

/** The copy button in a code block's header speaks the app's language. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CodeBlockLabelTest {
    private fun headerCopy(): String {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val prepared = runBlocking {
            MessageLayoutPrecomputer().prepare(
                listOf(ChatMessage(id = 1, conversationId = "c", turnId = "r:1", role = ChatRole.AGENT,
                    text = "```kotlin\nval x = 1\n```", createdAt = 1, status = MessageStatus.COMPLETED,
                    markdown = Md.of("```kotlin\nval x = 1\n```"))),
                viewportWidthPx = 1080, density = activity.resources.displayMetrics.density, fontScale = 1f,
                darkTheme = false, codeLabels = codeLabels(activity),
            ).single()
        }
        val code = prepared.blocks.filterIsInstance<PreparedContentBlock.Code>().single()
        return code.copyLayout.text.toString()
    }

    @Config(qualifiers = "en")
    @Test fun `english shows Copy`() = assertEquals("Copy", headerCopy())

    @Config(qualifiers = "zh")
    @Test fun `chinese shows 复制`() = assertEquals("复制", headerCopy())
}
