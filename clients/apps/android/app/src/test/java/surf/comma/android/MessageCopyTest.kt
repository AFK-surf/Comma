package surf.comma.android

import surf.comma.android.chat.render.CopyTarget
import surf.comma.android.chat.render.MessageContent
import surf.comma.android.chat.render.MessageCopy
import surf.comma.android.chat.render.MarkdownText
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 长按复制。以前全项目零 ClipboardManager 命中——一段代码或一个地址
 * 只能靠重新手打。
 */
class MessageCopyTest {

    @Test
    fun aPlainAnswerOffersTheWholeText() {
        val targets = MessageCopy.targets(
            "  今天下午三点有个会  ",
            listOf(MessageContent.Paragraph(MarkdownText.plain("今天下午三点有个会"))),
        )
        assertEquals(listOf(CopyTarget.FULL to "今天下午三点有个会"), targets)
    }

    /** 带代码块的回答里，用户要的是那一段，不是围栏加说明。 */
    @Test
    fun codeComesFirstAndArrivesWithoutTheFence() {
        val text = "这样写：\n```kotlin\nval x = 1\n```\n就行了"
        val targets = MessageCopy.targets(
            text,
            listOf(
                MessageContent.Paragraph(MarkdownText.plain("这样写：")),
                MessageContent.Code("kotlin", "val x = 1"),
                MessageContent.Paragraph(MarkdownText.plain("就行了")),
            ),
        )
        assertEquals(CopyTarget.CODE, targets.first().first)
        assertEquals("val x = 1", targets.first().second)
        assertEquals(CopyTarget.FULL to text, targets[1])
    }

    @Test
    fun severalCodeBlocksCopyAsOnePiece() {
        val targets = MessageCopy.targets(
            "两段",
            listOf(
                MessageContent.Code("sh", "adb devices"),
                MessageContent.Code("sh", "adb shell"),
            ),
        )
        assertEquals("adb devices\n\nadb shell", targets.first().second)
    }

    /** 卡片行没有正文：菜单一条都不给，而不是弹一个空菜单。 */
    @Test
    fun aMessageWithNothingToCopyOffersNothing() {
        assertEquals(emptyList<Any>(), MessageCopy.targets("   ", emptyList()))
    }
}
