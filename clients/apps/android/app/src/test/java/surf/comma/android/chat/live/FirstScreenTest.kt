package surf.comma.android.chat.live

import android.net.Uri
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.chat.model.ChatAttachment
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.media.ImageDimensions
import surf.comma.android.media.MediaAttachment
import surf.comma.android.media.MediaSource
import surf.comma.android.media.ViewerImage
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.PreparedChatMessage

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class FirstScreenTest {
    private val rows = List(100) { ChatMessage(id = it.toLong(), conversationId = "c", role = ChatRole.AGENT, text = "$it", createdAt = 0) }

    /** Every row is [height] px tall; records how many rows each call laid out. */
    private class Layout(private val height: Int) {
        val calls = ArrayList<Int>()
        fun prepare(rows: List<ChatMessage>): List<PreparedChatMessage> {
            calls += rows.size
            return rows.map { row ->
                PreparedChatMessage(message = row, cacheKey = "${row.id}", contents = emptyList(), blocks = emptyList(),
                    bubbleWidthPx = 0, bubbleHeightPx = 0, bubbleTopPx = 0, cellHeightPx = height, horizontalPaddingPx = 0,
                    verticalPaddingPx = 0, sideMarginPx = 0, topMarginPx = 0, cornerRadiusPx = 0f, drawBubble = false,
                    imageCornerRadiusPx = 0f, imageSources = emptyList())
            }
        }
    }

    @Test fun `only enough newest rows to fill the target are laid out`() = runBlocking {
        val layout = Layout(height = 100)
        val first = prepareFirstScreen(rows, targetHeightPx = 1500) { layout.prepare(it) }
        assertEquals(listOf(8, 16), layout.calls)
        assertEquals((84L..99L).toList(), first.map { it.message.id })
    }

    @Test fun `tall rows stop after the first batch`() = runBlocking {
        val layout = Layout(height = 400)
        val first = prepareFirstScreen(rows, targetHeightPx = 1500) { layout.prepare(it) }
        assertEquals(listOf(8), layout.calls)
        assertEquals(99L, first.last().message.id)
    }

    @Test fun `a short history is laid out whole`() = runBlocking {
        val layout = Layout(height = 10)
        val first = prepareFirstScreen(rows.take(20), targetHeightPx = 5000) { layout.prepare(it) }
        assertEquals(listOf(8, 16, 20), layout.calls)
        assertEquals(20, first.size)
    }

    @Test fun `image geometry and local previews survive the first screen and anchored history prepend`() = runBlocking {
        val source = MediaSource.UploadedFile("/uploads/abcdefghijklmnopqrstuv-photo.png")
        val local = ViewerImage.Local(Uri.parse("content://photos/local"), "image/png")
        // Portrait, landscape and the frozen square fallback used before dimensions are known.
        val sizes = listOf(ImageDimensions(540, 960),
            ImageDimensions(960, 540), ImageDimensions(1, 1))
        val images = rows.mapIndexed { index, row -> row.copy(
            role = if (index % 3 == 0) ChatRole.USER else ChatRole.AGENT,
            text = "", cardKind = LiveRowKinds.ATTACHMENT,
            attachment = ChatAttachment(
                file = MediaAttachment("photo.png", "image/png", 123, source),
                dimensions = sizes[index % sizes.size], preview = if (index % 2 == 0) local else null,
            ),
        ) }
        val layout = MessageLayoutPrecomputer()
        var previous = emptyList<PreparedChatMessage>()
        val first = prepareFirstScreen(images, targetHeightPx = 1500) { tail ->
            layout.prepareChanged(previous, tail, viewportWidthPx = 400, density = 1f, fontScale = 1f,
                darkTheme = false, firstPreviousRole = images.getOrNull(images.size - tail.size - 1)?.role)
                .also { previous = it }
        }
        assertTrue(first.size < images.size)
        val full = layout.prepareChanged(first, images, viewportWidthPx = 400, density = 1f, fontScale = 1f, darkTheme = false)
        val restored = full.associateBy { it.message.id }
        first.forEach { row ->
            val after = restored.getValue(row.message.id)
            assertEquals(row.cellHeightPx, after.cellHeightPx)
            assertEquals(row.topMarginPx, after.topMarginPx)
            assertEquals(row.message.attachment!!.dimensions, after.message.attachment!!.dimensions)
            assertEquals(row.message.attachment!!.preview, after.message.attachment!!.preview)
        }
    }

}
