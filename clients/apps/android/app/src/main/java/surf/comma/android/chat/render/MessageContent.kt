package surf.comma.android.chat.render

import surf.comma.android.chat.model.ImageDimensions
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.CoreMediaRef
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.TimelineBlockKinds

/** 表格列的对齐，来自 `|:---|:---:|---:|` 那一行。 */
enum class TableAlign { LEFT, CENTER, RIGHT }

/**
 * One piece of a message, in document order: a paragraph, heading, list item, code, quote, table, divider, formula or
 * picture, read from the client core's parse of the message ([MarkdownTree]); text blocks carry their inline styles.
 */
sealed class MessageContent {
    data class Paragraph(val text: MarkdownText) : MessageContent()
    data class Heading(val level: Int, val text: MarkdownText) : MessageContent()

    /** [depth] 是嵌套层级，0 是顶层。项目符号随层级换形，序号列表保留自己的编号。 */
    data class ListItem(
        val ordered: Boolean,
        val index: Int,
        val text: MarkdownText,
        val depth: Int = 0,
    ) : MessageContent()

    /**
     * 围栏代码块。[closed] 为 false 表示收尾的 ``` 还没到——流式中间态，
     * 块已经占住位置，内容还在长。
     */
    data class Code(
        val language: String,
        val text: String,
        val closed: Boolean = true,
    ) : MessageContent()

    /** `>` 引用。[depth] 是 `>` 的层数，画成左边线的层数。 */
    data class Quote(val text: MarkdownText, val depth: Int = 1) : MessageContent()

    /**
     * GFM 管道表格。[delimited] 为 false 表示 `|---|` 那行还没到，
     * 此时 [alignments] 全是 LEFT——表头已经能画，对齐随后补。
     */
    data class Table(
        val header: List<MarkdownText>,
        val alignments: List<TableAlign>,
        val rows: List<List<MarkdownText>>,
        val delimited: Boolean,
    ) : MessageContent()

    /**
     * A display formula on lines of its own: `$$…$$` or `\[…\]`. [latex] is what is between the
     * delimiters; [source] is the lines as written, shown in its place if the formula cannot be
     * drawn. [closed] is false while the closing delimiter has not arrived.
     */
    data class Math(
        val latex: String,
        val source: String,
        val closed: Boolean = true,
    ) : MessageContent()

    /** `---` / `***` / `___`。 */
    data object Divider : MessageContent()

    /**
     * One picture block.
     *
     * [media] is present only for an image Core sent. It carries the two facts a
     * gallery picture usually cannot supply before it is decoded — the displayed size,
     * so the row can reserve the right shape instead of a fixed box that jumps
     * when the bytes land, and the orientation, which only the original needs.
     * A local source can also supply [dimensions] explicitly before decoding.
     */
    data class Image(
        val source: String,
        val media: CoreMediaRef? = null,
        val dimensions: ImageDimensions? = null,
    ) : MessageContent()
    data class Status(
        val label: String,
        val detail: String? = null,
        val tone: StatusTone = StatusTone.NEUTRAL,
    ) : MessageContent()
}

/** 状态行的语气。ERROR 走红字——「失败标红」靠它，而不是靠读者猜文案。 */
enum class StatusTone { NEUTRAL, ERROR }

/** 长按能复制什么。CODE 排在前面：带代码的回答里，用户十有八九要的是那一段。 */
enum class CopyTarget { CODE, FULL }

object MessageCopy {
    /**
     * 一条消息的可复制内容，按优先级排序。
     *
     * 代码块拼在一起整块给出——把 ``` 围栏和说明文字一起复制走的话，
     * 粘到终端里第一件事还是手动删。
     */
    fun targets(text: String, contents: List<MessageContent>): List<Pair<CopyTarget, String>> {
        val full = text.trim()
        val code = contents.filterIsInstance<MessageContent.Code>()
            .joinToString("\n\n") { it.text }
            .trim()
        return buildList {
            if (code.isNotEmpty()) add(CopyTarget.CODE to code)
            if (full.isNotEmpty()) add(CopyTarget.FULL to full)
        }
    }

    /**
     * A whole reply that came as several messages, as one markdown document: each message's
     * source, separated by a blank line so each one starts a new block.
     */
    fun reply(messages: List<String>): String =
        messages.map(String::trim).filter(String::isNotEmpty).joinToString("\n\n")
}

/**
 * 状态行文案。跟 [MessageActionLabels] 同一个理由：解析层不碰 Context，
 * 文案由 UI 层带进来，纯 JVM 测试才跑得动。
 */
data class MessageStatusLabels(
    val undelivered: String = "未送达",
    val unfinished: String = "未能完成",
    val answerInterrupted: String = "回答中断",
    val inProgress: String = "正在响应",
)

object MessageContentParser {

    fun parse(
        message: ChatMessage,
        labels: MessageStatusLabels = MessageStatusLabels(),
        jsonParser: JsonParser = OrgJsonParser,
    ): List<MessageContent> {
        val seen = LinkedHashSet<String>()
        val out = ArrayList<MessageContent>()

        if (message.cardKind == TimelineBlockKinds.LIVE_STATUS ||
            message.cardKind == TimelineBlockKinds.TOOL_PLACEHOLDER
        ) {
            message.text.takeIf(String::isNotBlank)?.let { out.add(MessageContent.Status(it)) }
            return out
        }

        if (message.cardKind == TimelineBlockKinds.REPLY_ERROR) {
            out.add(MessageContent.Paragraph(MarkdownText.bold(message.text)))
            message.cardPayload?.takeIf(String::isNotBlank)?.let { out.add(MessageContent.Status(it)) }
            return out
        }

        if (message.cardKind == TimelineBlockKinds.PHOTO_GRID) {
            MessageLayoutPrecomputer.cardImages(message, jsonParser).forEach { source ->
                if (seen.add(source)) out.add(MessageContent.Image(source))
            }
        } else if (!message.imageSource.isNullOrBlank()) {
            if (seen.add(message.imageSource)) {
                // The reference travels with the block, not through a registry
                // keyed by media id. A row that is on screen is the only thing
                // that knows which Core its picture belongs to, and handing that
                // down the render path keeps it that way.
                out.add(MessageContent.Image(message.imageSource, message.coreMedia?.media, message.imageDimensions))
            }
        }

        // An agent's message as the client core parsed it; anything else (a person's words, a notice) as written.
        val markdown = message.markdown
        if (markdown != null) {
            MarkdownTree.blocks(org.json.JSONArray(markdown)).forEach { block ->
                if (block !is MessageContent.Image || seen.add(block.source)) out.add(block)
            }
        } else if (message.text.isNotBlank()) out.add(MessageContent.Paragraph(MarkdownText.plain(message.text.trim())))

        // 重试不再是「点整格」——失败行尾有显式按钮，所以状态行只说发生了什么。
        when (message.status) {
            // A user message that did not send says so outside its bubble, not inside it.
            MessageStatus.FAILED -> if (message.role != ChatRole.USER) out.add(
                MessageContent.Status(
                    label = when {
                        message.role == ChatRole.USER -> labels.undelivered
                        message.text.isBlank() -> labels.unfinished
                        else -> labels.answerInterrupted
                    },
                    detail = message.statusDetail,
                    tone = StatusTone.ERROR,
                ),
            )
            MessageStatus.PENDING, MessageStatus.STREAMING -> if (out.isEmpty()) {
                out.add(MessageContent.Status(labels.inProgress))
            }
            else -> Unit
        }

        if (out.isEmpty() && message.role != ChatRole.SYSTEM) {
            return emptyList()
        }
        return out
    }
}
