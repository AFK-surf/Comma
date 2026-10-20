package surf.comma.android

import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageSource
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.render.MessageContent
import surf.comma.android.chat.render.JsonParser
import surf.comma.android.chat.render.StatusTone
import surf.comma.android.chat.render.MessageContentParser
import surf.comma.android.chat.render.MarkdownStyle
import surf.comma.android.chat.render.MarkdownSpan
import surf.comma.android.chat.render.MarkdownText
import surf.comma.android.chat.render.Md
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MessageContentParserTest {

    @Test
    fun splitsParagraphsAndKeepsImageInDocumentOrder() {
        val contents = MessageContentParser.parse(
            message(
                "Intro line.\n\n" +
                    "![shot](https://example.com/a.png)\n\n" +
                    "A follow-up paragraph.",
            ),
        )
        assertEquals(3, contents.size)
        assertEquals(MessageContent.Paragraph(Md.plain("Intro line.")), contents[0])
        assertEquals(MessageContent.Image("https://example.com/a.png"), contents[1])
        assertEquals(MessageContent.Paragraph(Md.plain("A follow-up paragraph.")), contents[2])
    }

    /** A person's words are shown as written: the core parses an agent's Markdown, not a person's. */
    @Test
    fun aPersonsWordsAreShownAsWrittenAfterTheirPicture() {
        val contents = MessageContentParser.parse(
            ChatMessage(
                id = 2,
                conversationId = "c",
                role = ChatRole.USER,
                text = "look **here**",
                createdAt = 0,
                imageSource = "content://media/1",
            ),
        )
        assertEquals(
            listOf(
                MessageContent.Image("content://media/1"),
                MessageContent.Paragraph(Md.plain("look **here**")),
            ),
            contents,
        )
    }

    @Test
    fun extractsFencedCode() {
        val contents = MessageContentParser.parse(
            message("Before\n\n```kotlin\nval n = 1\n```\n\nAfter"),
        )
        assertEquals(3, contents.size)
        assertEquals(MessageContent.Paragraph(Md.plain("Before")), contents[0])
        assertEquals(MessageContent.Code("kotlin", "val n = 1"), contents[1])
        assertEquals(MessageContent.Paragraph(Md.plain("After")), contents[2])
    }

    @Test
    fun readsHeadingsListsAndInlineStylesFromTheTree() {
        val contents = MessageContentParser.parse(
            message("## 你的手机\n\n- 找照片：按**内容**搜索\n- 查 `日历`\n  1. 嵌套"),
        )
        assertEquals(MessageContent.Heading(2, Md.plain("你的手机")), contents[0])
        assertEquals(
            MessageContent.ListItem(false, 1,
                MarkdownText("找照片：按内容搜索", listOf(MarkdownSpan(5, 7, MarkdownStyle.BOLD)))),
            contents[1],
        )
        assertEquals(
            MessageContent.ListItem(false, 2, MarkdownText("查 日历", listOf(MarkdownSpan(2, 4, MarkdownStyle.CODE)))),
            contents[2],
        )
        assertEquals(MessageContent.ListItem(true, 1, Md.plain("嵌套"), depth = 1), contents[3])
    }

    @Test
    fun photoGridBecomesImageBlocks() {
        val contents = MessageContentParser.parse(
            ChatMessage(
                id = 3,
                conversationId = "c",
                role = ChatRole.AGENT,
                text = "here",
                createdAt = 0,
                cardKind = "photo.grid",
                cardPayload = """{"images":["/a.jpg","/b.jpg"]}""",
            ),
        )
        assertTrue(contents[0] is MessageContent.Image)
        assertTrue(contents[1] is MessageContent.Image)
        assertEquals(MessageContent.Paragraph(Md.plain("here")), contents[2])
    }

    @Test
    fun photoGridUnescapesJsonForwardSlashes() {
        val contents = MessageContentParser.parse(
            ChatMessage(
                id = 4,
                conversationId = "c",
                role = ChatRole.AGENT,
                text = "",
                createdAt = 0,
                cardKind = "photo.grid",
                cardPayload = """{"images":["\/data\/user\/0\/surf.comma.android\/cache\/agent_photos\/485.jpg","\/data\/user\/0\/surf.comma.android\/cache\/agent_photos\/484.jpg"]}""",
            ),
        )
        assertEquals(
            listOf(
                "/data/user/0/surf.comma.android/cache/agent_photos/485.jpg",
                "/data/user/0/surf.comma.android/cache/agent_photos/484.jpg",
            ),
            contents.filterIsInstance<MessageContent.Image>().map { it.source },
        )
    }

    @Test
    fun photoGridUsesARealParserWhenPathsContainClosingBracketsAndEscapes() {
        val contents = MessageContentParser.parse(
            ChatMessage(
                id = 5,
                conversationId = "c",
                role = ChatRole.AGENT,
                text = "",
                createdAt = 0,
                cardKind = "photo.grid",
                cardPayload =
                    """{"images":["/Pictures/album]one/a.jpg","/Pictures/a\"quote\".jpg"]}""",
            ),
        )

        assertEquals(
            listOf("/Pictures/album]one/a.jpg", "/Pictures/a\"quote\".jpg"),
            contents.filterIsInstance<MessageContent.Image>().map { it.source },
        )
    }

    @Test
    fun photoGridParserIsInjectableOnTheHost() {
        val parser = JsonParser { payload, key ->
            assertEquals("not-json-on-purpose", payload)
            assertEquals("images", key)
            listOf("/injected/a.jpg")
        }
        val contents = MessageContentParser.parse(
            ChatMessage(
                id = 6,
                conversationId = "c",
                role = ChatRole.AGENT,
                text = "",
                createdAt = 0,
                cardKind = "photo.grid",
                cardPayload = "not-json-on-purpose",
            ),
            jsonParser = parser,
        )

        assertEquals(
            listOf("/injected/a.jpg"),
            contents.filterIsInstance<MessageContent.Image>().map { it.source },
        )
    }

    @Test
    fun emptyStreamingAndFailedRowsStillRenderByStatus() {
        val running = MessageContentParser.parse(
            message("").copy(status = MessageStatus.STREAMING),
        )
        assertEquals(listOf(MessageContent.Status("正在响应")), running)

        val failed = MessageContentParser.parse(
            message("").copy(
                status = MessageStatus.FAILED,
                statusDetail = "turn_failed",
            ),
        )
        assertEquals(
            listOf(MessageContent.Status("未能完成", "turn_failed", StatusTone.ERROR)),
            failed,
        )
    }

    @Test
    fun failedStatesStayInsideTheAssistantTurn() {
        val failed = MessageContentParser.parse(
            message("").copy(
                status = MessageStatus.FAILED,
                statusDetail = "Nothing Core is unreachable",
            ),
        )
        assertEquals(
            listOf(
                MessageContent.Status(
                    "未能完成",
                    "Nothing Core is unreachable",
                    StatusTone.ERROR,
                ),
            ),
            failed,
        )
    }

    @Test
    fun voiceSourceDoesNotChangeParsedContents() {
        val typed = MessageContentParser.parse(message("先说结论。\n\n1. 接上\n2. 核对"))
        val voice = MessageContentParser.parse(
            message("先说结论。\n\n1. 接上\n2. 核对").copy(source = MessageSource.VOICE),
        )
        assertEquals(typed, voice)
    }

    /** A message that changed keeps every block before the first one that changed. */
    @Test
    fun blocksBeforeTheFirstChangeAreReused() {
        val before = listOf(MessageContent.Paragraph(Md.plain("a")), MessageContent.Code("kt", "x", closed = false),
            MessageContent.Paragraph(Md.plain("b")))
        val after = listOf(MessageContent.Paragraph(Md.plain("a")), MessageContent.Code("kt", "x", closed = true),
            MessageContent.Paragraph(Md.plain("b")))
        assertEquals(1, surf.comma.android.chat.render.sharedContentPrefix(before, after))
        assertEquals(3, surf.comma.android.chat.render.sharedContentPrefix(after, after))
    }

    private fun message(text: String) = ChatMessage(
        id = 1,
        conversationId = "c",
        role = ChatRole.AGENT,
        text = text,
        createdAt = 0,
        markdown = if (text.isEmpty()) null else Md.of(text),
    )
}
