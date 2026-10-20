package surf.comma.android.platform.asr

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import surf.comma.android.platform.logging.AppLog
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Doubao (Volcengine) big-model streaming ASR over an OkHttp WebSocket, `bigmodel_async` flavour.
 *
 * - Authentication is the `X-Api-Key` handshake header; there is no app id.
 * - Every frame is a 4-byte header + 4-byte big-endian payload size + payload, uncompressed:
 *   full client request `11 10 10 00` (JSON), audio `11 20 00 00` (raw PCM),
 *   last audio `11 22 00 00` (flag 0b0010, empty payload).
 * - Server frames are header(4) + optional sequence(4, when flag 0b0001) + size(4) + JSON.
 *   The text is `result.text` (cumulative, not a delta); flag 0b0010 marks the last frame.
 *
 * Audio is 16 kHz / mono / PCM16 LE from [AudioRecorder]. A client instance is single-use.
 *
 * Errors surface as [AsrError] codes only. Server and transport details go to the log without
 * request headers, so the key can never leak through an error message.
 */
class DoubaoAsrClient(
    private val credentials: AsrCredentials,
    private val endpoint: String = DEFAULT_ENDPOINT,
    /** Where the socket is opened: the shared client, or a test's server in memory. */
    private val sockets: WebSocket.Factory = HTTP_CLIENT,
) {
    interface Listener {
        /** Cumulative recognition so far, for live display. */
        fun onPartial(text: String)
        /** The final frame; [text] is the complete result. */
        fun onFinal(text: String)
        fun onError(error: AsrError)
    }

    private val stateLock = Any()
    private var webSocket: WebSocket? = null
    private var listener: Listener? = null
    private val sendQueue = AsrSendQueue()
    private var started = false
    private var terminal = false

    fun start(listener: Listener) {
        synchronized(stateLock) {
            check(!started) { "DoubaoAsrClient is single-use" }
            started = true
            this.listener = listener
            terminal = false
        }
        val request = Request.Builder()
            .url(endpoint)
            .header("X-Api-Key", credentials.apiKey)
            .header("X-Api-Resource-Id", credentials.resourceId)
            .header("X-Api-Connect-Id", UUID.randomUUID().toString())
            .header("X-Api-Request-Id", UUID.randomUUID().toString())
            .header("X-Api-Sequence", "-1")
            .build()
        val socket = sockets.newWebSocket(request, socketListener)
        synchronized(stateLock) {
            if (terminal) socket.cancel() else webSocket = socket
        }
    }

    /** Sends one frame of 16-bit little-endian PCM. */
    fun sendAudio(pcm: ByteArray, length: Int) {
        val failedSocket = synchronized(stateLock) {
            val socket = webSocket ?: return@synchronized null
            socket.takeUnless {
                sendQueue.audio(pcm, length).all { outbound -> sendFrame(outbound, socket) }
            }
        }
        if (failedSocket != null) fail(failedSocket, AsrError.NETWORK, "Audio frame send failed")
    }

    /** Release: send the empty last frame and wait for the final result. */
    fun finish() {
        val failedSocket = synchronized(stateLock) {
            val socket = webSocket ?: return@synchronized null
            socket.takeUnless { sendQueue.finish().all { outbound -> sendFrame(outbound, socket) } }
        }
        if (failedSocket != null) fail(failedSocket, AsrError.NETWORK, "Final frame send failed")
    }

    /** Cancel: close immediately without waiting for a result. */
    fun cancel() {
        val socket = synchronized(stateLock) {
            sendQueue.cancel()
            terminal = true
            listener = null
            webSocket.also { webSocket = null }
        }
        socket?.cancel()
    }

    private val socketListener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            val sent = synchronized(stateLock) {
                sendQueue.opened().all { sendFrame(it, webSocket) }
            }
            if (!sent) fail(webSocket, AsrError.NETWORK, "Configuration send failed")
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            val parsed = try {
                parseServerFrame(bytes.toByteArray())
            } catch (error: Exception) {
                AppLog.warn(TAG, error, "Unparseable ASR frame")
                fail(webSocket, AsrError.SERVER, "Unparseable frame")
                return
            }
            when (parsed) {
                is AsrServerFrame.Error ->
                    fail(webSocket, AsrError.SERVER, "Server error ${parsed.code}")
                is AsrServerFrame.Result -> {
                    val partial = synchronized(stateLock) {
                        listener.takeIf { !terminal && parsed.text.isNotEmpty() }
                    }
                    partial?.onPartial(parsed.text)
                    if (parsed.last) {
                        val callback = synchronized(stateLock) {
                            if (terminal) return@synchronized null
                            terminal = true
                            sendQueue.cancel()
                            if (this@DoubaoAsrClient.webSocket === webSocket) {
                                this@DoubaoAsrClient.webSocket = null
                            }
                            listener.also { listener = null }
                        }
                        callback?.onFinal(parsed.text)
                        webSocket.close(1000, "done")
                    }
                }
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            val code = response?.code
            response?.close()
            val error = if (code == 401 || code == 403) AsrError.UNAUTHORIZED else AsrError.NETWORK
            // Only the status code and exception class: the request (and its headers) stay out.
            fail(webSocket, error, "Connection failed: ${code ?: "-"} ${t.javaClass.simpleName}")
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            fail(webSocket, AsrError.NETWORK, "Closed before the final frame")
        }
    }

    private fun sendFrame(outbound: AsrOutbound, socket: WebSocket): Boolean =
        when (outbound.kind) {
            AsrOutbound.Kind.CONFIGURATION -> {
                val json = JSONObject().apply {
                    put("audio", JSONObject().apply {
                        put("format", "pcm")
                        put("rate", AudioRecorder.SAMPLE_RATE)
                        put("bits", 16)
                        put("channel", 1)
                    })
                    put("request", JSONObject().apply {
                        put("model_name", "bigmodel")
                        put("enable_itn", true)
                        put("enable_punc", true)
                    })
                }
                socket.send(encodeFrame(FULL_CLIENT_HEADER, json.toString().toByteArray(Charsets.UTF_8)))
            }
            AsrOutbound.Kind.AUDIO -> socket.send(encodeFrame(AUDIO_HEADER, outbound.payload))
            AsrOutbound.Kind.FINAL -> socket.send(encodeFrame(LAST_HEADER, EMPTY, 0))
        }

    private fun fail(socket: WebSocket, error: AsrError, logMessage: String) {
        val callback = synchronized(stateLock) {
            if (terminal) return
            terminal = true
            sendQueue.cancel()
            if (webSocket === socket) webSocket = null
            listener.also { listener = null }
        }
        AppLog.warn(TAG, "$error: $logMessage")
        socket.cancel()
        callback?.onError(error)
    }

    private companion object {
        const val TAG = "DoubaoAsr"
        const val DEFAULT_ENDPOINT = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
        val HTTP_CLIENT: OkHttpClient = OkHttpClient.Builder()
            .pingInterval(10, TimeUnit.SECONDS)
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
        val FULL_CLIENT_HEADER = byteArrayOf(0x11, 0x10, 0x10, 0x00)
        val AUDIO_HEADER = byteArrayOf(0x11, 0x20, 0x00, 0x00)
        val LAST_HEADER = byteArrayOf(0x11, 0x22, 0x00, 0x00)
        val EMPTY = ByteArray(0)
    }
}

/** What went wrong, as a code the UI maps to copy. Never carries server or transport text. */
enum class AsrError { NOT_CONFIGURED, MICROPHONE, NETWORK, UNAUTHORIZED, SERVER }

internal sealed interface AsrServerFrame {
    data class Result(val text: String, val last: Boolean) : AsrServerFrame
    data class Error(val code: Long, val message: String) : AsrServerFrame
}

internal fun encodeFrame(header: ByteArray, payload: ByteArray, length: Int = payload.size): ByteString {
    val out = ByteArray(8 + length)
    System.arraycopy(header, 0, out, 0, 4)
    out[4] = (length ushr 24).toByte()
    out[5] = (length ushr 16).toByte()
    out[6] = (length ushr 8).toByte()
    out[7] = length.toByte()
    if (length > 0) System.arraycopy(payload, 0, out, 8, length)
    return out.toByteString()
}

private fun int32(b: ByteArray, at: Int): Long =
    ((b[at].toLong() and 0xff) shl 24) or ((b[at + 1].toLong() and 0xff) shl 16) or
        ((b[at + 2].toLong() and 0xff) shl 8) or (b[at + 3].toLong() and 0xff)

internal fun parseServerFrame(b: ByteArray): AsrServerFrame {
    val messageType = (b[1].toInt() shr 4) and 0x0f
    val flags = b[1].toInt() and 0x0f
    if (messageType == 0b1111) {
        val code = int32(b, 4)
        val size = int32(b, 8).toInt()
        return AsrServerFrame.Error(code, String(b, 12, size, Charsets.UTF_8))
    }
    var offset = 4
    if (flags and 0b0001 != 0) offset += 4 // optional sequence number
    val size = int32(b, offset).toInt()
    offset += 4
    val json = JSONObject(String(b, offset, size, Charsets.UTF_8))
    val text = json.optJSONObject("result")?.optString("text").orEmpty()
    return AsrServerFrame.Result(text, last = flags and 0b0010 != 0)
}

internal data class AsrOutbound(
    val kind: Kind,
    val payload: ByteArray = ByteArray(0),
) {
    enum class Kind { CONFIGURATION, AUDIO, FINAL }
}

/**
 * Serializes ASR output around WebSocket connection setup.
 *
 * Audio can arrive while OkHttp is still handshaking. Keep only a short bounded tail, then emit
 * it after the protocol configuration. A quick release is remembered and becomes one final frame
 * immediately after that buffered tail.
 */
internal class AsrSendQueue(
    private val maxPendingAudioBytes: Int = DEFAULT_PENDING_AUDIO_BYTES,
) {
    private enum class State { CONNECTING, OPEN, FINISH_REQUESTED, FINAL_SENT, CLOSED }

    private val pending = ArrayDeque<ByteArray>()
    private var pendingBytes = 0
    private var state = State.CONNECTING

    init {
        require(maxPendingAudioBytes >= 0)
    }

    @Synchronized
    fun audio(pcm: ByteArray, length: Int): List<AsrOutbound> {
        if (length <= 0 || length > pcm.size) return emptyList()
        val copy = pcm.copyOf(length)
        return when (state) {
            State.CONNECTING -> {
                if (copy.size <= maxPendingAudioBytes) {
                    while (pendingBytes + copy.size > maxPendingAudioBytes && pending.isNotEmpty()) {
                        pendingBytes -= pending.removeFirst().size
                    }
                    pending.addLast(copy)
                    pendingBytes += copy.size
                }
                emptyList()
            }
            State.OPEN -> listOf(AsrOutbound(AsrOutbound.Kind.AUDIO, copy))
            State.FINISH_REQUESTED, State.FINAL_SENT, State.CLOSED -> emptyList()
        }
    }

    @Synchronized
    fun finish(): List<AsrOutbound> = when (state) {
        State.CONNECTING -> {
            state = State.FINISH_REQUESTED
            emptyList()
        }
        State.OPEN -> {
            state = State.FINAL_SENT
            listOf(AsrOutbound(AsrOutbound.Kind.FINAL))
        }
        State.FINISH_REQUESTED, State.FINAL_SENT, State.CLOSED -> emptyList()
    }

    @Synchronized
    fun opened(): List<AsrOutbound> {
        if (state != State.CONNECTING && state != State.FINISH_REQUESTED) return emptyList()
        val finishAfterFlush = state == State.FINISH_REQUESTED
        state = if (finishAfterFlush) State.FINAL_SENT else State.OPEN
        return buildList {
            add(AsrOutbound(AsrOutbound.Kind.CONFIGURATION))
            pending.forEach { add(AsrOutbound(AsrOutbound.Kind.AUDIO, it)) }
            if (finishAfterFlush) add(AsrOutbound(AsrOutbound.Kind.FINAL))
        }.also {
            pending.clear()
            pendingBytes = 0
        }
    }

    @Synchronized
    fun cancel() {
        state = State.CLOSED
        pending.clear()
        pendingBytes = 0
    }

    private companion object {
        // Two seconds of 16 kHz, 16-bit mono PCM.
        const val DEFAULT_PENDING_AUDIO_BYTES = 64_000
    }
}
