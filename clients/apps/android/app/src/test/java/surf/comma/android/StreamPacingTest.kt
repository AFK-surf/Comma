package surf.comma.android

import surf.comma.android.chat.streaming.StreamRhythm
import surf.comma.android.chat.streaming.pacedBy
import surf.comma.android.chat.streaming.ChatStreamEvent
import java.io.IOException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.random.Random

/**
 * StreamRhythm 的启用路径：pacedBy 把 Delta 切小按节奏重放，
 * 但内容、事件顺序、错误语义必须与不加节奏器时完全一致。
 */
@OptIn(ExperimentalCoroutinesApi::class)
class StreamPacingTest {

    private fun rhythm() = StreamRhythm(Random(42))

    private fun completed() = ChatStreamEvent.Completed

    @Test
    fun textIsRevealedInSmallChunksAndReassemblesExactly() = runTest {
        val text = "流式不是匀速的：token 成簇到达，句号后的停顿明显长于逗号。恒速喂字一眼就能看出是假的。"
        val events = flow {
            emit(ChatStreamEvent.Delta(text))
            emit(completed())
        }.pacedBy(rhythm()).toList()

        val deltas = events.filterIsInstance<ChatStreamEvent.Delta>()
        assertTrue("expected multiple chunks, got ${deltas.size}", deltas.size >= 4)
        assertEquals(text, deltas.joinToString("") { it.text })
        assertTrue(currentTime > 0)
    }

    @Test
    fun completionIsHeldBackUntilTheLastChunkIsRevealed() = runTest {
        val events = flow {
            emit(ChatStreamEvent.Delta("最后一段和 completed 几乎同时到达。"))
            emit(completed())
        }.pacedBy(rhythm()).toList()

        assertTrue(events.last() is ChatStreamEvent.Completed)
        assertTrue(events.dropLast(1).all { it is ChatStreamEvent.Delta })
    }

    @Test
    fun anUpstreamFailureStillDeliversEverythingReceivedFirst() = runTest {
        val received = mutableListOf<ChatStreamEvent>()
        try {
            flow {
                emit(ChatStreamEvent.Delta("已经收到的内容"))
                emit(ChatStreamEvent.Delta("仍然保留。"))
                throw IOException("连接断了")
            }.pacedBy(rhythm()).collect { received += it }
            fail("expected the upstream failure to propagate")
        } catch (error: IOException) {
            assertEquals("连接断了", error.message)
        }
        assertEquals(
            "已经收到的内容仍然保留。",
            received.filterIsInstance<ChatStreamEvent.Delta>().joinToString("") { it.text },
        )
    }

    @Test
    fun aLargeBacklogCatchesUpInsteadOfFallingBehindForever() = runTest {
        // 整段回退路径：4000 字一次到达。逐包 12-27ms 不压缩要跑 10 秒以上；
        // 追平机制必须把总时长压到与积压量脱钩的量级。
        val text = "字".repeat(4000)
        val events = flow {
            emit(ChatStreamEvent.Delta(text))
            emit(completed())
        }.pacedBy(rhythm()).toList()

        assertEquals(text, events.filterIsInstance<ChatStreamEvent.Delta>().joinToString("") { it.text })
        assertTrue("took ${currentTime}ms", currentTime < 5_000)
        assertTrue(currentTime > 0)
    }

    @Test
    fun statusEventsPassThroughWithoutWaitingForTheBuffer() = runTest {
        val events = flow {
            emit(ChatStreamEvent.Delta("一大段还没揭示完的文字。".repeat(20)))
            emit(ChatStreamEvent.Status("reconnecting", ""))
            delay(5_000)
            emit(completed())
        }.pacedBy(rhythm()).toList()

        val statusIndex = events.indexOfFirst { it is ChatStreamEvent.Status }
        val lastDeltaIndex = events.indexOfLast { it is ChatStreamEvent.Delta }
        assertTrue(statusIndex in 0 until lastDeltaIndex)
    }
}
