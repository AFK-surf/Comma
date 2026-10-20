package surf.comma.android.fixture

import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test
import surf.comma.android.chat.model.MessageStatus

class FixtureConversationSourceTest {
    @Test fun thousandMessagesHaveStableIdentityAndMixedMarkdown() = runTest {
        val first = FixtureConversationSource().load()
        val second = FixtureConversationSource().load()
        assertEquals(1000, first.size)
        assertEquals(first, second)
        assertEquals(1000, first.map { it.id }.toSet().size)
        assertTrue(first.any { it.text.length > 500 })
        assertTrue(first.any { it.text.startsWith("```kotlin") })
        assertTrue(first.any { it.text.contains("| --- |") })
    }

    @Test fun localImagesAreDistributedWithKnownShapesAndNoNetworkSources() = runTest {
        val messages = FixtureConversationSource().load()
        val images = messages.filter { it.imageSource != null }
        assertEquals(25, images.size)
        assertEquals(25, images.map { it.imageSource }.toSet().size)
        assertTrue(images.all { it.imageSource!!.startsWith("android.resource://") })
        assertEquals(5, images.map { it.imageDimensions }.toSet().size)
        assertTrue(images.all { it.imageDimensions != null })
        assertEquals(listOf(19L, 955L), listOf(images.first().id, images.last().id))
    }

    @Test fun streamingOnlyChangesTheLastRowAndCompletesWithoutLosingText() = runTest {
        val source = FixtureConversationSource()
        val original = source.load()
        var previousText = ""
        var updates = 0
        var finalStatus = MessageStatus.STREAMING
        source.replay().collect { messages ->
            assertEquals(original.dropLast(1), messages.dropLast(1))
            assertEquals(original.last().id, messages.last().id)
            assertTrue(messages.last().text.startsWith(previousText))
            previousText = messages.last().text
            finalStatus = messages.last().status
            updates++
        }
        assertTrue(updates > 10)
        assertTrue(previousText.endsWith("测量完成后再比较真实设备上的帧耗时。"))
        assertTrue(previousText.length in 2000..3000)
        assertTrue(previousText.count { it in '\u4e00'..'\u9fff' } in 2000..3000)
        assertEquals(FixtureReply.text, previousText)
        assertEquals(MessageStatus.COMPLETED, finalStatus)
    }
}
