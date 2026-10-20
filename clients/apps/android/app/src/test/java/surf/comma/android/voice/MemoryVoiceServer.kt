package surf.comma.android.voice

import java.io.EOFException
import java.io.IOException
import java.util.ArrayDeque
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import okio.Timeout
import org.json.JSONObject

/**
 * The voice server in memory, as a [VoiceSession] reaches it through OkHttp: readiness requests and call sockets.
 * What OkHttp would tell the session later (a socket opened or failed, a close answered) waits in [pending] until the
 * test delivers it; nothing runs on another thread, so a test decides the order.
 */
internal class MemoryVoiceServer {
    private val pending = ArrayDeque<() -> Unit>()

    /** Tells the session what the network has for it; false when there was nothing. */
    fun deliver(): Boolean {
        if (pending.isEmpty()) return false
        while (pending.isNotEmpty()) pending.removeFirst()()
        return true
    }

    /** Every request the session made, readiness and socket upgrades, in order. */
    val requests = mutableListOf<Request>()
    /** How the next requests are answered, in order; an empty queue answers 404. */
    private val answers = ArrayDeque<(Request) -> Answer>()
    /** Down: every request fails as an unreachable server's does. */
    var down = false

    sealed interface Answer
    class Reply(val code: Int, val body: String) : Answer
    /** A socket upgrade the server accepts; [peer] is the server's side of it. */
    class Upgrade(val peer: Peer, val protocol: String? = VoiceProtocol.SUBPROTOCOL) : Answer

    fun reply(code: Int, body: String) = answers.addLast { Reply(code, body) }
    fun ready(busy: Boolean = false) = reply(200, """{"ready":true,"busy":$busy}""")

    /** The server answers readiness and accepts the next socket: the peer it talks to the call through. */
    fun upgrade(protocol: String? = VoiceProtocol.SUBPROTOCOL): Peer {
        ready()
        return Peer().also { peer -> answers.addLast { Upgrade(peer, protocol) } }
    }

    private fun answer(request: Request): Answer {
        requests += request
        return answers.pollFirst()?.invoke(request) ?: Reply(404, "{}")
    }

    val calls = Call.Factory { request -> ReadinessCall(request) }

    val sockets = WebSocket.Factory { request, listener ->
        val socket = ClientSocket(request, listener, pending)
        if (down) {
            pending.addLast { listener.onFailure(socket, IOException("unreachable"), null) }
            return@Factory socket
        }
        when (val answer = answer(request)) {
            is Reply -> {
                val refused = response(request, answer.code, answer.body)
                pending.addLast { listener.onFailure(socket, IOException("upgrade refused"), refused) }
            }
            is Upgrade -> {
                answer.peer.attach(socket)
                val response = response(request, 101, "").newBuilder()
                    .apply { answer.protocol?.let { header("Sec-WebSocket-Protocol", it) } }.build()
                pending.addLast { if (!socket.canceled) listener.onOpen(socket, response) }
            }
        }
        socket
    }

    private fun response(request: Request, code: Int, body: String) = Response.Builder().request(request)
        .protocol(Protocol.HTTP_1_1).code(code).message("").body(body.toResponseBody()).build()

    private inner class ReadinessCall(private val request: Request) : Call {
        private var canceled = false
        private var executed = false
        override fun request() = request
        override fun execute(): Response = error("The session asks asynchronously")
        override fun enqueue(responseCallback: Callback) {
            executed = true
            if (down) return responseCallback.onFailure(this, IOException("unreachable"))
            when (val answer = answer(request)) {
                is Reply -> responseCallback.onResponse(this, response(request, answer.code, answer.body))
                is Upgrade -> error("A socket was accepted where readiness was asked")
            }
        }
        override fun cancel() { canceled = true }
        override fun isExecuted() = executed
        override fun isCanceled() = canceled
        override fun timeout() = Timeout.NONE
        override fun clone(): Call = ReadinessCall(request)
    }

    /** The call's side of a socket: what it sends reaches its [Peer] at once. */
    class ClientSocket(
        private val request: Request,
        val listener: WebSocketListener,
        private val pending: ArrayDeque<() -> Unit>,
    ) : WebSocket {
        var peer: Peer? = null
        /** Bytes the network has not taken yet; a stalled network keeps them. */
        var queued = 0L
        /** The network stopped taking what the call sends. */
        var stalled = false
        var closedByClient: Int? = null
        var canceled = false
        override fun request() = request
        override fun queueSize() = queued
        override fun send(text: String): Boolean {
            if (closedByClient != null || canceled) return false
            peer?.text?.addLast(text)
            return true
        }
        override fun send(bytes: ByteString): Boolean {
            if (closedByClient != null || canceled) return false
            if (stalled) queued += bytes.size else peer?.audio?.addLast(bytes)
            return true
        }
        override fun close(code: Int, reason: String?): Boolean {
            if (closedByClient != null || canceled) return false
            closedByClient = code
            // A server that closed answers the call's close.
            if (peer?.closing == true) pending.addLast { listener.onClosed(this, code, reason.orEmpty()) }
            return true
        }
        override fun cancel() { canceled = true }
    }

    /** The server's side of one call's socket. */
    class Peer {
        lateinit var socket: ClientSocket
        val text = ArrayDeque<String>()
        val audio = ArrayDeque<ByteString>()
        var closing = false

        fun attach(socket: ClientSocket) {
            this.socket = socket
            socket.peer = this
        }

        fun send(value: String) = socket.listener.onMessage(socket, value)
        fun pcm(size: Int = 960) = socket.listener.onMessage(socket, ByteArray(size) { 7 }.toByteString())
        fun nextText(): JSONObject = JSONObject(requireNotNull(text.pollFirst()) { "The call sent no text" })
        fun nextAudio(): ByteString = requireNotNull(audio.pollFirst()) { "The call sent no audio" }

        /** The server closes the socket; the call answers the close. */
        fun close(code: Int, reason: String) {
            closing = true
            socket.listener.onClosing(socket, code, reason)
        }

        /** The connection breaks. */
        fun drop() = socket.listener.onFailure(socket, EOFException(), null)

        /** The network takes what queued in a stall. */
        fun drain() {
            socket.stalled = false
            socket.queued = 0
        }
    }
}
