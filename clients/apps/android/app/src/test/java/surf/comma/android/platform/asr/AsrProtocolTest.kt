package surf.comma.android.platform.asr

import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AsrProtocolTest {
    @Test
    fun `quick release flushes buffered audio before exactly one final frame`() {
        val queue = AsrSendQueue(maxPendingAudioBytes = 32)
        val audio = byteArrayOf(1, 2, 3, 4)

        assertTrue(queue.audio(audio, audio.size).isEmpty())
        assertTrue(queue.finish().isEmpty())

        val opened = queue.opened()
        assertEquals(
            listOf(AsrOutbound.Kind.CONFIGURATION, AsrOutbound.Kind.AUDIO, AsrOutbound.Kind.FINAL),
            opened.map(AsrOutbound::kind),
        )
        assertEquals(audio.toList(), opened[1].payload.toList())
        assertTrue(queue.finish().isEmpty())
    }

    @Test
    fun `pending audio is memory bounded`() {
        val queue = AsrSendQueue(maxPendingAudioBytes = 4)
        queue.audio(byteArrayOf(1, 2, 3), 3)
        queue.audio(byteArrayOf(4, 5, 6), 3)

        val audio = queue.opened().filter { it.kind == AsrOutbound.Kind.AUDIO }
        assertEquals(1, audio.size)
        assertEquals(listOf<Byte>(4, 5, 6), audio.single().payload.toList())
    }

    @Test
    fun `server result frames parse with and without a sequence number`() {
        val json = JSONObject().put("result", JSONObject().put("text", "你好")).toString().toByteArray()
        val plain = encodeFrame(byteArrayOf(0x11, 0x90.toByte(), 0x10, 0x00), json).toByteArray()
        assertEquals(AsrServerFrame.Result("你好", last = false), parseServerFrame(plain))

        // flags 0b0011: carries a sequence number and marks the last frame.
        val size = json.size
        val sequenced = byteArrayOf(0x11, 0x93.toByte(), 0x10, 0x00, 0, 0, 0, 7) +
            byteArrayOf((size ushr 24).toByte(), (size ushr 16).toByte(), (size ushr 8).toByte(), size.toByte()) +
            json
        assertEquals(AsrServerFrame.Result("你好", last = true), parseServerFrame(sequenced))
    }

    @Test
    fun `a streamed session parses as growing partial text and then the final text`() {
        val parsed = STREAM.map { parseServerFrame(it.toByteArray()) }

        assertEquals(
            listOf(
                AsrServerFrame.Result("", last = false),
                AsrServerFrame.Result("今天", last = false),
                AsrServerFrame.Result("今天天气", last = false),
                AsrServerFrame.Result("今天天气怎么样", last = false),
                AsrServerFrame.Result("今天天气怎么样？", last = true),
            ),
            parsed,
        )
    }

    /**
     * The ASR server in memory: what the client sends reaches [onFrame] at once, and what the server sends back
     * reaches the client when the test calls [deliver].
     */
    private class MemoryAsrServer(private val onFrame: (MemoryAsrServer, ByteString) -> Unit) : WebSocket.Factory {
        private val pending = ArrayDeque<() -> Unit>()
        private lateinit var socket: WebSocket
        private lateinit var listener: WebSocketListener

        fun send(frame: ByteString) = pending.addLast { listener.onMessage(socket, frame) }

        fun deliver() {
            while (pending.isNotEmpty()) pending.removeFirst()()
        }

        override fun newWebSocket(request: Request, listener: WebSocketListener): WebSocket {
            this.listener = listener
            socket = object : WebSocket {
                var open = true
                override fun request() = request
                override fun queueSize() = 0L
                override fun send(text: String) = error("The client sends binary frames")
                override fun send(bytes: ByteString): Boolean {
                    if (open) onFrame(this@MemoryAsrServer, bytes)
                    return open
                }
                override fun close(code: Int, reason: String?): Boolean = open.also { open = false }
                override fun cancel() { open = false }
            }
            val opened = Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(101).message("").build()
            pending.addLast { listener.onOpen(socket, opened) }
            return socket
        }
    }

    @Test
    fun `the client reports each partial as it arrives and ends with the final text`() {
        val received = mutableListOf<Byte>()
        val server = MemoryAsrServer { server, bytes ->
            received += bytes[1]
            when (bytes[1]) {
                // The configuration opens the session; each audio frame yields the next partial.
                CONFIGURATION_TYPE -> server.send(STREAM[0])
                AUDIO_TYPE -> STREAM.getOrNull(received.count { it == AUDIO_TYPE })?.takeIf { it != STREAM.last() }
                    ?.let(server::send)
                LAST_AUDIO_TYPE -> server.send(STREAM.last())
            }
        }
        val partials = mutableListOf<String>()
        var final: String? = null
        var failure: AsrError? = null
        val client = DoubaoAsrClient(AsrCredentials("test-key", "test-resource"), "wss://asr.test/", server)
        client.start(object : DoubaoAsrClient.Listener {
            override fun onPartial(text: String) {
                partials += text
            }

            override fun onFinal(text: String) {
                final = text
            }

            override fun onError(error: AsrError) {
                failure = error
            }
        })
        server.deliver()
        val frame = ByteArray(AudioRecorder.FRAME_BYTES)
        repeat(3) { index ->
            client.sendAudio(frame, frame.size)
            server.deliver()
            assertEquals(index + 1, partials.size)
        }
        client.finish()
        server.deliver()

        // The empty acknowledgement is not shown; each longer partial is, before the final text.
        assertEquals(listOf("今天", "今天天气", "今天天气怎么样", "今天天气怎么样？"), partials.toList())
        assertEquals("今天天气怎么样？", final)
        assertEquals(null, failure)
        assertEquals(CONFIGURATION_TYPE, received.first())
        assertEquals(LAST_AUDIO_TYPE, received.last())
    }

    private companion object {
        const val CONFIGURATION_TYPE: Byte = 0x10
        const val AUDIO_TYPE: Byte = 0x20
        const val LAST_AUDIO_TYPE: Byte = 0x22

        /** What the server sends for one utterance: an empty acknowledgement, growing partials, the final. */
        val STREAM = listOf(
            serverFrame(sequence = 1, text = ""),
            serverFrame(sequence = 2, text = "今天"),
            serverFrame(sequence = 3, text = "今天天气"),
            serverFrame(sequence = 4, text = "今天天气怎么样"),
            serverFrame(sequence = -5, text = "今天天气怎么样？", last = true),
        )

        /** A full server response: JSON payload, a sequence number, and the last flag on the final one. */
        fun serverFrame(sequence: Int, text: String, last: Boolean = false): ByteString {
            val json = JSONObject().put("result", JSONObject().put("text", text)).toString().toByteArray()
            val flags = if (last) 0b0011 else 0b0001
            val out = byteArrayOf(0x11, (0b1001 shl 4 or flags).toByte(), 0x10, 0x00) +
                int32(sequence) + int32(json.size) + json
            return out.toByteString()
        }

        fun int32(value: Int) = byteArrayOf((value ushr 24).toByte(), (value ushr 16).toByte(), (value ushr 8).toByte(), value.toByte())
    }
}
