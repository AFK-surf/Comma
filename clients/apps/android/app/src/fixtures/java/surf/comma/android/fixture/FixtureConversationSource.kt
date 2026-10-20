package surf.comma.android.fixture

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext
import surf.comma.android.chat.data.ConversationSource
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.chat.streaming.ChatStreamEvent
import surf.comma.android.chat.streaming.StreamRhythm
import surf.comma.android.chat.streaming.pacedBy
import kotlin.random.Random

/** Deterministic local test fixture, compiled ONLY into debug and devBenchmark. */
class FixtureConversationSource : ConversationSource {
    override val canReplay = true
    private var history: List<ChatMessage> = emptyList()

    override suspend fun load(): List<ChatMessage> = withContext(Dispatchers.Default) {
        List(MESSAGE_COUNT) { index ->
            val id = index + 1L
            val image = FixtureImages.at(index)
            ChatMessage(
                id = id, conversationId = "fixture-conversation", turnId = "turn-${index / 2}",
                role = if (index % 2 == 0) ChatRole.USER else ChatRole.AGENT,
                text = when (index) {
                    998 -> "请逐段解释聊天页面的流畅度。"
                    999 -> "点击下方按钮播放回复。"
                    else -> body(index)
                },
                imageSource = image?.source, imageDimensions = image?.dimensions,
                createdAt = 1_700_000_000_000L + index * 1_000L,
            )
        }.also { history = it }
    }

    override fun replay(): Flow<List<ChatMessage>> = replay(FixtureReply.text)

    /** The waiting row alone for [WAITING_MS], then the opening of the reply in its place. */
    override fun replayAfterWaiting(): Flow<List<ChatMessage>> = flow {
        check(history.size == MESSAGE_COUNT) { "Load the fixture before replay" }
        emit(history.dropLast(1) + ChatMessage(
            id = MESSAGE_COUNT + 1L, conversationId = "fixture-conversation", turnId = history.last().turnId,
            role = ChatRole.AGENT, text = "", createdAt = 0L, cardKind = TimelineBlockKinds.LIVE_STATUS,
        ))
        delay(WAITING_MS)
        emitAll(replay(FixtureReply.text.take(SHORT_REPLY_CHARS)))
    }

    private fun replay(response: String): Flow<List<ChatMessage>> = flow {
        check(history.size == MESSAGE_COUNT) { "Load the fixture before replay" }
        val completed = StringBuilder()
        fun snapshot(status: MessageStatus) = history.dropLast(1) + history.last().copy(
            text = completed.toString(), status = status,
        )
        emit(snapshot(MessageStatus.STREAMING))
        // Simulated upstream bursts; pacing preserves punctuation pauses and catch-up behavior.
        flow {
            val packets = Random(72658)
            var offset = 0
            while (offset < response.length) {
                delay(packets.nextLong(40, 131))
                val end = (offset + packets.nextInt(16, 49)).coerceAtMost(response.length)
                emit(ChatStreamEvent.Delta(response.substring(offset, end)))
                offset = end
            }
            emit(ChatStreamEvent.Completed)
        }.pacedBy(StreamRhythm(Random(42))).collect { event ->
            when (event) {
                is ChatStreamEvent.Delta -> {
                    completed.append(event.text)
                    emit(snapshot(MessageStatus.STREAMING))
                }
                ChatStreamEvent.Completed -> emit(snapshot(MessageStatus.COMPLETED))
                is ChatStreamEvent.Status -> Unit
            }
        }
    }

    private fun body(index: Int): String = when (index % 8) {
        0, 1, 2 -> "消息 ${index + 1}：今天也保持简单、清晰。"
        3 -> "## 第 ${index + 1} 条长回复\n\n" +
            (1..8).joinToString("\n\n") { "**段落 $it**：后台排版让滚动时主线程只需绑定。".repeat(4) }
        4 -> "```kotlin\n" + (1..18).joinToString("\n") {
            "val item$it = messages.getOrNull($it)?.copy(text = \"消息 ${index + 1}\")"
        } + "\n```"
        5 -> "| 项目 | 状态 | 说明 |\n| --- | --- | --- |\n" +
            (1..12).joinToString("\n") { "| $it | 已准备 | 第 ${index + 1} 条消息，固定内容 |" }
        6 -> "> 引用保持段落层级。\n\n- 有上限的缓存\n- 稳定 ID\n- 复用已完成的文本块\n\n---\n\n普通正文。"
        else -> "消息 ${index + 1}：短回复与长回复交错，覆盖不同的行高。"
    }

    companion object {
        const val MESSAGE_COUNT = 1000
        private const val WAITING_MS = 4_000L
        private const val SHORT_REPLY_CHARS = 240
    }
}
