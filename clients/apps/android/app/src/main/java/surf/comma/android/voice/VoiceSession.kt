package surf.comma.android.voice

import java.io.Closeable
import java.io.IOException
import java.util.ArrayDeque
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.time.Duration.Companion.nanoseconds
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import surf.comma.android.ui.Background

/**
 * Own one call; no microphone, speaker, UI or service dependencies. Its requests go through [calls] and its socket
 * through [sockets] (the OkHttp client by default), and the uplink keeps time with [nanoTime] and [scope]'s delays: a
 * test gives it an in-memory server and a virtual clock.
 */
class VoiceSession internal constructor(
    private val credentials: VoiceCredentials,
    private val sink: PlaybackSink,
    versionName: String,
    displayName: String?,
    httpClient: OkHttpClient,
    scope: CoroutineScope,
    calls: Call.Factory?,
    sockets: WebSocket.Factory?,
    private val nanoTime: () -> Long,
) : Closeable {
    constructor(
        credentials: VoiceCredentials,
        sink: PlaybackSink,
        versionName: String,
        displayName: String? = null,
        httpClient: OkHttpClient = OkHttpClient(),
        scope: CoroutineScope = CoroutineScope(Background.files),
    ) : this(credentials, sink, versionName, displayName, httpClient, scope, null, null, System::nanoTime)

    private val lock = Any()
    private val ownerJob = SupervisorJob(scope.coroutineContext[Job])
    private val work = CoroutineScope(scope.coroutineContext + ownerJob)
    internal val client = httpClient.newBuilder().pingInterval(20, TimeUnit.SECONDS)
        .connectTimeout(10, TimeUnit.SECONDS).readTimeout(10, TimeUnit.SECONDS)
        .callTimeout(10, TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false).build()
    private val calls: Call.Factory = calls ?: client
    private val sockets: WebSocket.Factory = sockets ?: client
    private val startMessage = VoiceProtocol.start(versionName, displayName)
    private val mutableState = MutableStateFlow(CallState())
    val state = mutableState.asStateFlow()
    private val mutableTranscripts = MutableSharedFlow<VoiceMessage.Transcript>(extraBufferCapacity = 32)
    /** Ephemeral events, never written to diagnostics or retained after the call. */
    val transcripts = mutableTranscripts.asSharedFlow()
    private val mutableDiagnostics = MutableSharedFlow<VoiceDiagnostic>(replay = 1, extraBufferCapacity = 32)
    /** Best-effort metadata only; slow observers never backpressure audio or protocol processing. */
    val diagnostics = mutableDiagnostics.asSharedFlow()
    private var socket: WebSocket? = null
    private val closingSockets = mutableSetOf<WebSocket>()
    private var preparing: Job? = null
    private var pacer: Job? = null
    private var ending: Job? = null
    private var retried = false
    private var disposed = false
    private var muted = false
    private var opened = false
    private val uplink = ArrayDeque<ByteString>()
    private val silence = ByteArray(VoiceProtocol.FRAME_BYTES).toByteString()
    private class Mark(val name: String)
    private val marks = ArrayDeque<Mark>()
    private var receivedMarks = 0L
    private var acknowledgedMarks = 0L
    private var sentFrames = 0L
    private var stalledFrames = 0L
    private var droppedMicFrames = 0L

    fun playbackReceipts(): VoicePlaybackReceipts = synchronized(lock) {
        VoicePlaybackReceipts(receivedMarks, acknowledgedMarks, marks.size, socket?.queueSize() ?: 0)
    }

    fun uplink(): VoiceUplinkStats = synchronized(lock) {
        VoiceUplinkStats(sentFrames, stalledFrames, droppedMicFrames)
    }

    init {
        ownerJob.invokeOnCompletion {
            synchronized(lock) {
                disposed = true
                transition(CallSignal.Finished(state.value.generation, CallResult.Ended))
                cleanup()
                closingSockets.forEach { it.cancel() }
                closingSockets.clear()
            }
        }
    }

    /** Permission must already be granted by the owner. Repeated starts during a call are ignored. */
    fun start() = synchronized(lock) {
        if (disposed) return@synchronized
        val next = CallStateReducer.reduce(state.value, CallSignal.Begin(state.value.generation + 1))
        if (next == state.value) return@synchronized
        cleanup()
        mutableState.value = next
        retried = false
        receivedMarks = 0
        acknowledgedMarks = 0
        sentFrames = 0
        stalledFrames = 0
        droppedMicFrames = 0
        muted = false
        prepare(next.generation, invalidate = false)
    }

    /** One 20 ms frame. Returns false for invalid size, a full 100 ms queue, mute or an inactive call. */
    fun offerAudio(pcm: ByteArray): Boolean = synchronized(lock) {
        if (pcm.size != VoiceProtocol.FRAME_BYTES || muted || !opened ||
            state.value.phase !in setOf(CallPhase.Calling, CallPhase.Connected)) return false
        if (uplink.size >= 5) { droppedMicFrames++; return false }
        uplink.addLast(pcm.toByteString())
        true
    }

    fun setMuted(value: Boolean) = synchronized(lock) {
        muted = value
        if (value) uplink.clear()
    }

    fun hangUp() = synchronized(lock) {
        val generation = state.value.generation
        transition(CallSignal.HangUp(generation))
        if (state.value.phase != CallPhase.Ending || ending != null) return@synchronized
        preparing?.cancel()
        pacer?.cancel()
        uplink.clear()
        val ws = socket
        if (!opened || ws == null) {
            finish(generation, CallResult.Ended)
        } else {
            if (!ws.send(VoiceProtocol.end())) {
                finish(generation, CallResult.Ended)
                return@synchronized
            }
            ending = work.launch {
                delay(2_000)
                synchronized(lock) {
                    if (current(generation, ws) && state.value.phase == CallPhase.Ending) finish(generation, CallResult.Ended, forceClose = true)
                }
            }
        }
    }

    fun dismissFailure() = synchronized(lock) { transition(CallSignal.DismissFailure(state.value.generation)) }

    /** Immediate teardown when the owner is destroyed; use hangUp for a normal protocol end. */
    override fun close() = synchronized(lock) {
        disposed = true
        transition(CallSignal.Finished(state.value.generation, CallResult.Ended))
        cleanup()
        closingSockets.forEach { it.cancel() }
        closingSockets.clear()
        work.cancel()
    }

    private fun prepare(generation: Long, invalidate: Boolean) {
        preparing = work.launch {
            try {
                if (invalidate) credentials.invalidate()
                val endpoint = credentials.endpoint()
                readiness(endpoint)
                synchronized(lock) {
                    if (!current(generation) || state.value.phase != CallPhase.Preparing) return@synchronized
                    transition(CallSignal.Ready(generation))
                    val request = Request.Builder().url(endpoint.sessionsUrl)
                        .header("Authorization", "Bearer ${endpoint.bearer}")
                        .header("Sec-WebSocket-Protocol", VoiceProtocol.SUBPROTOCOL).build()
                    socket = sockets.newWebSocket(request, listener(generation))
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                synchronized(lock) {
                    if (current(generation)) failed(generation, (e as? VoiceFailure)?.result ?: CallResult.Interrupted)
                }
            }
        }
    }

    private suspend fun readiness(endpoint: VoiceEndpoint) = suspendCancellableCoroutine { continuation ->
        val call = calls.newCall(Request.Builder().url(endpoint.readinessUrl)
            .header("Authorization", "Bearer ${endpoint.bearer}").build())
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                continuation.resumeWithException(VoiceFailure(CallResult.Interrupted))
            }
            override fun onResponse(call: Call, response: Response) {
                val result = runCatching {
                    response.use {
                        val json = boundedJson(it)
                        if (!it.isSuccessful) throw VoiceFailure(VoiceProtocol.result(it.code, json?.optString("error")))
                        if (json == null) throw VoiceFailure(CallResult.Unavailable)
                        if (!json.optBoolean("ready")) throw VoiceFailure(VoiceProtocol.result(503, json.optString("reason")))
                        if (json.optBoolean("busy")) throw VoiceFailure(CallResult.Busy)
                    }
                }
                result.fold({ continuation.resume(Unit) }, {
                    continuation.resumeWithException(if (it is VoiceFailure) it else VoiceFailure(CallResult.Interrupted))
                })
            }
        })
    }

    private fun listener(generation: Long) = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) = synchronized(lock) {
            if (!current(generation, webSocket)) { webSocket.cancel(); return@synchronized }
            if (response.header("Sec-WebSocket-Protocol") != VoiceProtocol.SUBPROTOCOL) {
                diagnose(VoiceDiagnostic.Kind.SubprotocolRejected)
                failed(generation, CallResult.Interrupted)
                return@synchronized
            }
            // First frame, sent directly from onOpen; no audio or asynchronous work can precede it.
            if (!webSocket.send(startMessage)) {
                diagnose(VoiceDiagnostic.Kind.SendFailed)
                failed(generation, CallResult.Interrupted)
                return@synchronized
            }
            opened = true
            pacer = work.launch {
                // Absolute deadlines: a relative delay per frame runs slower than the microphone,
                // which then overflows the queue and drops caller audio. After a long delay the
                // schedule restarts instead of bursting to catch up.
                var due = nanoTime()
                while (true) {
                    due += FRAME_NANOS
                    val wait = due - nanoTime()
                    if (wait > 0) delay(wait.nanoseconds)
                    else if (-wait > MAX_PACER_LAG_NANOS) due = nanoTime()
                    synchronized(lock) {
                        if (!current(generation, webSocket) || state.value.phase == CallPhase.Ending) return@launch
                        val audio = if (muted || uplink.isEmpty()) silence else uplink.removeFirst()
                        // During a network stall, skip frames instead of queueing them: the server
                        // tolerates stalls but caps the catch-up burst. OkHttp's ping detects a dead link.
                        if (webSocket.queueSize() > MAX_UPLINK_BYTES) stalledFrames++
                        else if (webSocket.send(audio)) sentFrames++
                        else {
                            diagnose(VoiceDiagnostic.Kind.SendFailed)
                            failed(generation, CallResult.Interrupted)
                            return@launch
                        }
                    }
                }
            }
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) = synchronized(lock) {
            if (!current(generation, webSocket)) return@synchronized
            if (!VoiceProtocol.validAudio(bytes.size)) {
                diagnose(VoiceDiagnostic.Kind.InvalidDownlink)
                failed(generation, CallResult.Interrupted)
                return@synchronized
            }
            if (bytes.size == 0) return@synchronized
            try {
                if (!state.value.receivedAudio) diagnose(VoiceDiagnostic.Kind.FirstAudio)
                sink.audio(bytes.toByteArray())
                transition(CallSignal.Audio(generation))
            } catch (_: Exception) {
                diagnose(VoiceDiagnostic.Kind.PlaybackRejected)
                failed(generation, CallResult.Interrupted)
            }
        }

        override fun onMessage(webSocket: WebSocket, text: String) = synchronized(lock) {
            if (!current(generation, webSocket)) return@synchronized
            try {
                when (val message = VoiceProtocol.decode(text)) {
                    is VoiceMessage.Started -> {
                        diagnose(VoiceDiagnostic.Kind.Started)
                        if (message.audioFormat != VoiceProtocol.AUDIO_FORMAT) {
                            diagnose(VoiceDiagnostic.Kind.AudioFormatRejected)
                            failed(generation, CallResult.Interrupted)
                            return@synchronized
                        }
                        transition(CallSignal.Started(generation, message))
                    }
                    is VoiceMessage.Mark -> {
                        if (marks.size >= 1024) {
                            diagnose(VoiceDiagnostic.Kind.MarkOverflow)
                            failed(generation, CallResult.Interrupted)
                            return@synchronized
                        }
                        val mark = Mark(message.name)
                        receivedMarks++
                        marks.addLast(mark)
                        sink.mark(mark.name) {
                            synchronized(lock) {
                                if (current(generation, webSocket) && marks.contains(mark)) {
                                    acknowledge(webSocket, mark)
                                }
                            }
                        }
                    }
                    VoiceMessage.Clear -> {
                        diagnose(VoiceDiagnostic.Kind.OutputClear)
                        sink.clear()
                        acknowledge(webSocket)
                    }
                    is VoiceMessage.Transcript -> mutableTranscripts.tryEmit(message)
                    is VoiceMessage.Ended -> {
                        diagnose(VoiceDiagnostic.Kind.SessionEnded, reason = VoiceProtocol.diagnosticReason(message.reason))
                        val result = VoiceProtocol.endedResult(message.reason)
                        if (result == CallResult.Ended) finish(generation, result) else failed(generation, result)
                    }
                    is VoiceMessage.Error -> {
                        diagnose(VoiceDiagnostic.Kind.ServerError, message.code)
                        failed(generation, VoiceProtocol.errorResult(message.code, message.message))
                    }
                    null -> Unit
                }
            } catch (_: Exception) {
                diagnose(VoiceDiagnostic.Kind.InvalidDownlink)
                failed(generation, CallResult.Interrupted)
            }
            Unit
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) = synchronized(lock) {
            if (current(generation, webSocket)) {
                diagnose(VoiceDiagnostic.Kind.SocketClose, code, reason = VoiceProtocol.diagnosticReason(reason))
            }
            webSocket.close(code, null)
            if (current(generation, webSocket)) failed(generation, VoiceProtocol.closeResult(code, reason))
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = synchronized(lock) {
            if (current(generation, webSocket)) failed(generation, VoiceProtocol.closeResult(code, reason))
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            val result = response?.use { VoiceProtocol.result(it.code, boundedJson(it)?.optString("error")) }
                ?: CallResult.Interrupted
            synchronized(lock) { if (current(generation, webSocket)) {
                val failure = when (t) {
                    is java.net.SocketTimeoutException -> VoiceDiagnostic.TransportFailure.Timeout
                    is java.io.EOFException -> VoiceDiagnostic.TransportFailure.EndOfStream
                    is IOException -> VoiceDiagnostic.TransportFailure.Io
                    else -> VoiceDiagnostic.TransportFailure.Other
                }
                diagnose(VoiceDiagnostic.Kind.TransportFailure, response?.code, failure)
                failed(generation, result)
            } }
        }
    }

    private fun acknowledge(ws: WebSocket, through: Mark? = null) {
        while (marks.isNotEmpty()) {
            val mark = marks.removeFirst()
            if (!ws.send(VoiceProtocol.played(mark.name))) {
                diagnose(VoiceDiagnostic.Kind.SendFailed)
                failed(state.value.generation, CallResult.Interrupted)
                return
            }
            acknowledgedMarks++
            if (mark === through) return
        }
    }

    private fun failed(generation: Long, result: CallResult) {
        if (result == CallResult.CredentialsExpired) {
            val canRetry = !retried && state.value.phase != CallPhase.Ending
            cleanup()
            if (canRetry) {
                retried = true
                val next = generation + 1
                transition(CallSignal.RetryCredentials(next))
                prepare(next, invalidate = true)
            } else {
                preparing = work.launch {
                    try { credentials.invalidate() } catch (e: CancellationException) { throw e } catch (_: Exception) { /* Already rejected. */ }
                    synchronized(lock) { if (current(generation)) finish(generation, result) }
                }
            }
        } else finish(generation, result)
    }

    private fun finish(generation: Long, result: CallResult, forceClose: Boolean = false) {
        transition(CallSignal.Finished(generation, result))
        val ws = socket
        cleanup(cancelSocket = forceClose || result != CallResult.Ended)
        if (!forceClose && result == CallResult.Ended && ws != null) {
            ws.close(1000, null)
            closingSockets.add(ws)
            work.launch {
                delay(2_000)
                synchronized(lock) { closingSockets.remove(ws); ws.cancel() }
            }
        }
    }

    private fun cleanup(cancelSocket: Boolean = true) {
        val old = socket
        socket = null
        opened = false
        preparing?.cancel(); preparing = null
        pacer?.cancel(); pacer = null
        ending?.cancel(); ending = null
        uplink.clear()
        marks.clear()
        if (cancelSocket) old?.cancel()
        try { sink.clear() } catch (_: Exception) { /* Cleanup must release the transport even if playback failed. */ }
    }

    private fun current(generation: Long, ws: WebSocket? = null): Boolean = !disposed &&
        state.value.generation == generation && state.value.phase in ongoing && (ws == null || socket === ws)

    private fun transition(signal: CallSignal) { mutableState.value = CallStateReducer.reduce(state.value, signal) }

    private fun diagnose(
        kind: VoiceDiagnostic.Kind, code: Int? = null,
        failure: VoiceDiagnostic.TransportFailure? = null, reason: String? = null,
    ) {
        mutableDiagnostics.tryEmit(VoiceDiagnostic(kind, code = code, transportFailure = failure, reason = reason))
    }

    private fun boundedJson(response: Response): JSONObject? = try {
        val source = response.body?.source()
        if (source == null || source.request(VoiceProtocol.MAX_FRAME_BYTES + 1L)) null else JSONObject(source.readUtf8())
    } catch (_: Exception) { null }

    companion object {
        private const val MAX_UPLINK_BYTES = 48_000L
        private const val FRAME_NANOS = VoiceProtocol.FRAME_MILLIS * 1_000_000L
        /** The microphone queue holds five frames; never send more than that late. */
        private const val MAX_PACER_LAG_NANOS = FRAME_NANOS * 5
        private val ongoing = setOf(CallPhase.Preparing, CallPhase.Calling, CallPhase.Connected, CallPhase.Ending)
    }
}
