package surf.comma.android.chat.streaming

import surf.comma.android.chat.streaming.ChatStreamEvent
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.launch
import kotlin.math.min

/**
 * 把 transport 吐出的 Delta 按 [StreamRhythm] 的节奏切小重放，其余事件保持原语义：
 *
 * 从原 runtime 提取；事件只描述本地文字、状态与完成，不包含服务端协议。
 * - Completed 押后到全部文字揭示完才转发。SSE 的最后一个 delta 和 completed 几乎同时
 *   到达，不押后的话结尾整段闪现，节奏器等于没装。非 SSE 整段回退路径（单个大 Delta +
 *   Completed）也因此获得同样的逐段揭示。
 * - 上游异常时先把缓冲里已收到的文字放出去再抛——「已收到的内容仍然保留」的承诺不变。
 * - 积压超过 [catchUpChars] 时按比例压缩间隔，永远追得上真实流。
 */
internal fun Flow<ChatStreamEvent>.pacedBy(
    rhythm: StreamRhythm,
    catchUpChars: Int = 96,
): Flow<ChatStreamEvent> = channelFlow {
    val inbox = Channel<ChatStreamEvent>(Channel.UNLIMITED)
    launch {
        try {
            collect { inbox.send(it) }
            inbox.close()
        } catch (error: Throwable) {
            inbox.close(error)
        }
    }

    val pending = StringBuilder()
    var completion: ChatStreamEvent.Completed? = null
    var closed = false
    var closedCause: Throwable? = null

    suspend fun flushPending() {
        if (pending.isNotEmpty()) {
            send(ChatStreamEvent.Delta(pending.toString()))
            pending.setLength(0)
        }
    }

    suspend fun handle(event: ChatStreamEvent) {
        when (event) {
            is ChatStreamEvent.Delta -> pending.append(event.text)
            is ChatStreamEvent.Completed -> completion = event
            is ChatStreamEvent.Status -> send(event)
        }
    }

    while (true) {
        if (pending.isEmpty()) {
            if (closed) break
            val received = inbox.receiveCatching()
            if (received.isClosed) {
                closed = true
                closedCause = received.exceptionOrNull()
                continue
            }
            handle(received.getOrThrow())
        } else {
            // 先消化已排队的事件，再处理完成或异常。
            while (true) {
                val received = inbox.tryReceive()
                if (received.isSuccess) {
                    handle(received.getOrThrow())
                    continue
                }
                if (received.isClosed && !closed) {
                    closed = true
                    closedCause = received.exceptionOrNull()
                }
                break
            }
            if (pending.isEmpty()) continue
            if (closedCause != null) {
                // 上游已经报错：把剩下的字一次放完，让错误尽快浮上去。
                flushPending()
                break
            }
            val take = min(rhythm.chunkSize(), pending.length)
            val chunk = pending.substring(0, take)
            pending.delete(0, take)
            send(ChatStreamEvent.Delta(chunk))
            if (pending.isEmpty() && closed) break
            var pause = rhythm.delayAfter(chunk, 0, chunk.length)
            if (pending.length > catchUpChars) {
                pause = (pause * catchUpChars / pending.length).coerceAtLeast(1L)
            }
            delay(pause)
        }
    }
    // 不能直接 throw：flush 出去的 Delta 还躺在 channelFlow 的缓冲里，异常会抢在它
    // 前面把整条流掐掉。close(cause) 让下游先排空缓冲，异常最后才到。
    closedCause?.let {
        close(it)
        return@channelFlow
    }
    completion?.let { send(it) }
}
