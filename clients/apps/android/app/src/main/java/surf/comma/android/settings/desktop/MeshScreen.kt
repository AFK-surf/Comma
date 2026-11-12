package surf.comma.android.settings.desktop

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.view.Surface
import org.json.JSONObject
import surf.comma.android.core.CoreBytes
import surf.comma.android.core.CoreError
import surf.comma.android.core.ScreenFrame
import java.nio.ByteBuffer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * One view of a computer's screen, or of one of its devices, over the mesh: the core's `devices.openScreenView` gives
 * its frames as the call's progress (the core's screen-views.ts), MediaCodec decodes them onto a [Surface], and each
 * frame shown is acknowledged, which the station paces the next by. What the station says of the view (Watch or
 * Control, how a device stands, an agent's lease) goes to [onState]; input goes back through [send].
 */
internal class MeshScreenView(
    private val scope: WorkspaceScope,
    private val device: String,
    /** `display`, or a device the station lists (`simulator:<udid>`, `android:<serial>`). */
    val target: String,
    private val instance: String?,
    control: Boolean,
    /** A measured run (a debug build): keep the core busy meanwhile, to see whether pictures still come on time. */
    private val busy: Boolean = false,
    /** A measured run (a debug build): take the pictures as progress (JSON), as before the core handed them over. */
    private val asProgress: Boolean = false,
    private val onState: (MeshScreenState) -> Unit,
) {
    /** Pictures that came and were drawn since the last line of the log (`CommaScreen`), for a measured run. */
    private val received = java.util.concurrent.atomic.AtomicInteger()
    private val drawn = java.util.concurrent.atomic.AtomicInteger()

    /** What the page shows of the view. */
    var state = MeshScreenState(control = control)
        private set
    private var view: Int? = null
    private var switches = false
    private var surface: Surface? = null
    /** The open view's pictures, in the order they came (null between views). */
    @Volatile private var pictures: ScreenPictures<Pending>? = null

    val isDevice: Boolean get() = target.startsWith("simulator:") || target.startsWith("android:")

    /**
     * Opens the view and keeps it open until the page's work ends: a view that went after it showed comes back after
     * each of [AGAIN_AFTER_MS], and one the mesh does not reach is tried again every [UNREACHED_AGAIN_MS], as the
     * desktop's (meshScreenStream.ts, remoteScreenStream.ts). A refusal ends it. Called on the page's thread.
     */
    suspend fun run() = kotlinx.coroutines.coroutineScope {
        // A debug build's measured run: the pictures that came and were drawn, each second, in the log.
        val watching = if (surf.comma.android.BuildConfig.DEBUG) launch {
            while (true) {
                delay(1000)
                android.util.Log.i("CommaScreen", "screen-stats target=$target received=${received.getAndSet(0)} drawn=${drawn.getAndSet(0)} busy=$busy json=$asProgress")
            }
        } else null
        val load = if (busy) launch {
            while (true) {
                try { scope.core.call("devices.listScreens", JSONObject().put("workspace", scope.workspaceId).put("device", device)) } catch (e: CancellationException) { throw e } catch (_: Exception) {}
            }
        } else null
        try { keepOpen() } finally {
            watching?.cancel()
            load?.cancel()
        }
    }

    private suspend fun keepOpen() {
        var tries = 0
        while (true) {
            val ended = once() ?: return
            val wait = when {
                ended.code in REFUSALS -> return
                ended.code in NOT_HERE && !ended.wasLive -> UNREACHED_AGAIN_MS
                else -> AGAIN_AFTER_MS[minOf(tries++, AGAIN_AFTER_MS.lastIndex)]
            }
            if (ended.wasLive) tries = 0
            delay(wait)
            change(state.copy(phase = MeshScreenState.Phase.CONNECTING))
        }
    }

    private class Ended(val code: String, val wasLive: Boolean)

    /** One view, until it ends: how, or null when the page's work ended it. */
    private suspend fun once(): Ended? {
        val params = JSONObject().put("workspace", scope.workspaceId).put("device", device).put("target", target)
            .put("codecs", org.json.JSONArray().put("h264")).put("control", state.control)
        instance?.let { params.put("instance", it) }
        val wasLive = { state.phase == MeshScreenState.Phase.LIVE }
        // Pictures straight from the core where it hands them over (no JSON, no base64); else as progress.
        val made = pictures()
        pictures = made
        val sink = if (asProgress) null else scope.core.screenSink(::picture)
        sink?.let { params.put("sink", it.id) }
        return try {
            // Progress comes on the core's thread: each event is handled on the page's, in the order it came.
            scope.core.call("devices.openScreenView", params) { progress ->
                (progress as? JSONObject)?.let { told -> scope.work.launchOnPage { event(told) } }
            }
            val live = wasLive()
            change(state.copy(phase = MeshScreenState.Phase.FAILED, failure = null))
            Ended("screen_ended", live)
        } catch (e: CancellationException) {
            throw e
        } catch (e: CoreError) {
            if (e.code == "cancelled") return null
            val live = wasLive()
            val unreachable = e.code in NOT_HERE && !live
            change(state.copy(phase = MeshScreenState.Phase.FAILED, failure = if (unreachable) null else e.message, unreachable = unreachable))
            Ended(e.code, live)
        } finally {
            sink?.close()
            view = null
            pictures = null
            made.close()
        }
    }

    /**
     * A picture straight from the core ([ScreenFrame]), on the core's thread: a config and each frame go to the
     * decoder's thread in the order they came ([ScreenPictures]), as the progress's do from the page's.
     */
    private fun picture(frame: ScreenFrame) {
        val pictures = pictures ?: return
        when (frame.kind) {
            1, 2 -> configured(pictures, AvcConfig.parse(frame.bytes)?.let { Pending(it, frame.width, frame.height) })
            3, 4 -> {
                received.incrementAndGet()
                pictures.frame(frame.bytes, frame.ts, key = frame.kind == 4)
            }
        }
    }

    /** The surface the picture is drawn on, once it has one. */
    fun attach(surface: Surface?) {
        this.surface = surface
        pictures?.surface(surface)
    }

    /** Watch or Control, on the open view where the station switches it there. */
    fun control(on: Boolean) {
        if (on == state.control) return
        if (switches && view != null) send(JSONObject().put("control", on)) else change(state.copy(control = on))
    }

    /** A touch at [x], [y] (0..1 of the picture): a finger on a device, the left button on a computer. */
    fun touch(kind: String, x: Float, y: Float) {
        if (!state.control || state.phase != MeshScreenState.Phase.LIVE) return
        val px = x.coerceIn(0f, 1f).toDouble()
        val py = y.coerceIn(0f, 1f).toDouble()
        val input = if (isDevice) {
            JSONObject().put("t", "pointer").put("kind", kind).put("x", px).put("y", py).put("buttons", if (kind == "up") 0 else 1)
        } else {
            JSONObject().put("type", kind).put("x", px).put("y", py).put("button", 0).put("clicks", 1).put("mods", org.json.JSONArray())
        }
        send(JSONObject().put("input", input))
    }

    /** A simulator's Home: Simulator.app's ⌘⇧H (the station's sim-input.ts). */
    fun home() {
        if (!state.control || !target.startsWith("simulator:")) return
        for (kind in listOf("down", "up")) {
            send(JSONObject().put("input", JSONObject().put("t", "key").put("kind", kind).put("key", "h").put("code", "KeyH").put("mods", 4 or 8)))
        }
    }

    private fun event(event: JSONObject) {
        when (event.optString("type")) {
            "open" -> view = event.optInt("view")
            "config" -> {
                val description = runCatching { java.util.Base64.getDecoder().decode(event.optString("description")) }.getOrNull()
                pictures?.let { pictures ->
                    configured(pictures, description?.let { AvcConfig.parse(it) }?.let {
                        Pending(it, event.optInt("width"), event.optInt("height"))
                    })
                }
            }
            "video" -> {
                val ts = event.optLong("ts")
                val data = CoreBytes.read(event.opt("data"))
                received.incrementAndGet()
                if (data == null) ack(ts) else pictures?.frame(data, ts, key = event.optBoolean("key"))
            }
            "state" -> event.optJSONObject("state")?.let(::stated)
        }
    }

    /** A stream's config: to the decoder's thread in its turn, and its size to the page. */
    private fun configured(pictures: ScreenPictures<Pending>, config: Pending?) {
        pictures.config(config)
        if (config != null) scope.work.launchOnPage { change(state.copy(width = config.width, height = config.height)) }
    }

    private fun stated(said: JSONObject) {
        if (said.has("switches")) switches = said.optBoolean("switches")
        var next = state
        if (said.has("control")) next = next.copy(control = said.optBoolean("control"))
        if (said.has("orientation")) next = next.copy(orientation = said.optInt("orientation"))
        if (said.has("refused")) next = next.copy(refused = said.optString("refused").ifEmpty { null })
        val leased = if (said.has("agent")) said.optBoolean("agent") else state.agent
        val leaseChanged = leased != state.agent
        if (leaseChanged) next = next.copy(agent = leased, agentPointer = null)
        said.optJSONObject("agentPointer")?.let { at ->
            next = next.copy(agentPointer = if (at.optBoolean("down")) (at.optDouble("x").toFloat() to at.optDouble("y").toFloat()) else null)
        }
        change(next)
        // As the desktop's panel does: Watch while an agent drives, so its input reaches the device.
        if (leaseChanged) control(!leased)
    }

    /**
     * The pictures of one view: a thread of their own ([DECODER_THREAD]) that takes the configs and frames in order,
     * and MediaCodec on it. The page hears each picture's size; the station each frame shown, a frame acknowledged
     * undecoded, and a key frame asked where the decoder needs one.
     */
    private fun pictures(): ScreenPictures<Pending> {
        val serial = surf.comma.android.ui.Background.serial(DECODER_THREAD)
        val made = ScreenPictures<Pending>(
            post = serial.post,
            make = { config: Pending, surface: Any, broke: () -> Unit ->
                FrameDecoder(config, surface as Surface, serial.handler!!, ::shown, dropped = { ts: Long ->
                    scope.work.launchOnPage {
                        ack(ts)
                        send(JSONObject().put("keyframe", true))
                    }
                }, broke = broke)
            },
            // (what the station hears goes from the page's thread, as all else it is told)
            ack = { ts: Long -> scope.work.launchOnPage { ack(ts) } },
            askKey = { scope.work.launchOnPage { send(JSONObject().put("keyframe", true)) } },
            ended = serial.quit,
        )
        surface?.let { made.surface(it) }
        return made
    }

    /** A frame drawn: the page is live, and the station hears it. On the decoder's thread. */
    private fun shown(ts: Long) {
        drawn.incrementAndGet()
        scope.work.launchOnPage {
            if (state.phase != MeshScreenState.Phase.LIVE) change(state.copy(phase = MeshScreenState.Phase.LIVE, failure = null))
            ack(ts)
        }
    }

    private fun ack(ts: Long) = send(JSONObject().put("ack", ts))

    private fun send(fields: JSONObject) {
        val view = view ?: return
        fields.put("view", view)
        scope.work.launchOnPage {
            try { scope.core.call("devices.sendToScreenView", fields) } catch (_: Exception) {}
        }
    }

    private fun change(next: MeshScreenState) {
        state = next
        onState(next)
    }

    private class Pending(val avc: AvcConfig, val width: Int, val height: Int)

    /**
     * H.264 on MediaCodec, onto a surface: each access unit in as Annex B, each frame out rendered as it comes. Made,
     * fed and closed on [handler]'s thread (the view's [ScreenPictures]), which its callbacks come on too.
     */
    private class FrameDecoder(
        config: Pending,
        surface: Surface,
        private val handler: Handler,
        private val shown: (Long) -> Unit,
        /** A frame it could not take (not AVCC as its config says). */
        private val dropped: (Long) -> Unit,
        /** The codec failed: it takes nothing more. */
        private val broke: () -> Unit,
    ) : PictureDecoder {
        private val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        private val nalLength = config.avc.nalLength
        private val inputs = ArrayDeque<Int>()
        private val queued = ArrayDeque<Pair<ByteArray, Long>>()
        @Volatile private var closed = false

        init {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, config.width.coerceAtLeast(16), config.height.coerceAtLeast(16))
            format.setByteBuffer("csd-0", ByteBuffer.wrap(config.avc.sps))
            format.setByteBuffer("csd-1", ByteBuffer.wrap(config.avc.pps))
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            codec.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                    if (closed) return
                    val next = queued.removeFirstOrNull()
                    if (next == null) inputs.addLast(index) else feed(index, next.first, next.second)
                }

                override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    if (closed) return
                    codec.releaseOutputBuffer(index, true)
                    shown(info.presentationTimeUs)
                }

                override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                    if (!closed) broke()
                }
                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {}
            }, handler)
            codec.configure(format, surface, null, 0)
            codec.start()
        }

        /** Takes one access unit (AVCC), turned into Annex B. On the decoder's thread. */
        override fun decode(avcc: ByteArray, ts: Long) {
            if (closed) return
            val annexB = if (nalLength == 4) AvcConfig.annexBInPlace(avcc) else AvcConfig.annexB(avcc, nalLength)
            if (annexB == null) {
                dropped(ts)
                return
            }
            val index = inputs.removeFirstOrNull()
            if (index == null) queued.addLast(annexB to ts) else feed(index, annexB, ts)
        }

        private fun feed(index: Int, data: ByteArray, ts: Long) {
            val buffer = codec.getInputBuffer(index) ?: return
            buffer.clear()
            buffer.put(data)
            codec.queueInputBuffer(index, 0, data.size, ts, 0)
        }

        /** On the decoder's thread. */
        override fun close() {
            closed = true
            runCatching { codec.stop() }
            runCatching { codec.release() }
        }
    }

    companion object {
        /** The codes that say the mesh did not reach the screen, not that it cannot be shown (the desktop's NOT_HERE). */
        val NOT_HERE = setOf("unsupported", "unreachable", "unavailable", "timeout", "unknown_call")
        /** Codes that end a view for good: trying again cannot help (screenFailure.ts `screenFailureRetries`). */
        val REFUSALS = setOf("forbidden", "unauthorized", "screen_refused", "not_found", "invalid")
        /** A view that went after it showed comes back after each of these (ms), as the desktop's. */
        val AGAIN_AFTER_MS = longArrayOf(500, 1000, 2000, 4000, 8000)
        /** A computer the mesh did not reach is tried again this often (ms), as the desktop's. */
        const val UNREACHED_AGAIN_MS = 30_000L
        /** The thread a view's pictures are decoded on. */
        const val DECODER_THREAD = "comma-screen-decoder"
    }
}

/** What a view says of itself, for the page to draw. */
internal data class MeshScreenState(
    val phase: Phase = Phase.CONNECTING,
    val control: Boolean = false,
    val width: Int = 0,
    val height: Int = 0,
    val orientation: Int = 0,
    val refused: String? = null,
    val failure: String? = null,
    /** The mesh did not reach the computer. */
    val unreachable: Boolean = false,
    val agent: Boolean = false,
    /** Where an agent's finger is, as a share of the picture. */
    val agentPointer: Pair<Float, Float>? = null,
) {
    enum class Phase { CONNECTING, LIVE, FAILED }
}

/** An avcC's parameter sets and NAL length, and access units turned from AVCC into Annex B for MediaCodec. */
internal class AvcConfig(val sps: ByteArray, val pps: ByteArray, val nalLength: Int) {
    companion object {
        private val START = byteArrayOf(0, 0, 0, 1)

        /** The avcC [box] says, or null when it is not one. */
        fun parse(box: ByteArray): AvcConfig? {
            if (box.size < 7 || box[0].toInt() != 1) return null
            val nalLength = (box[4].toInt() and 3) + 1
            var at = 5
            fun sets(count: Int): ByteArray? {
                val out = java.io.ByteArrayOutputStream()
                repeat(count) {
                    if (at + 2 > box.size) return null
                    val length = ((box[at].toInt() and 0xff) shl 8) or (box[at + 1].toInt() and 0xff)
                    at += 2
                    if (at + length > box.size) return null
                    out.write(START)
                    out.write(box, at, length)
                    at += length
                }
                return out.toByteArray()
            }
            val sps = sets(box[at++].toInt() and 0x1f) ?: return null
            if (at >= box.size) return null
            val pps = sets(box[at++].toInt() and 0xff) ?: return null
            return AvcConfig(sps, pps, nalLength)
        }

        /**
         * [avcc]'s NAL units with 4-byte lengths turned into start codes where they are, the same size: no copy. Null
         * (and [avcc] left as it was) when they do not add up.
         */
        fun annexBInPlace(avcc: ByteArray): ByteArray? {
            var at = 0
            while (at < avcc.size) {
                if (at + 4 > avcc.size) return null
                val length = ((avcc[at].toInt() and 0xff) shl 24) or ((avcc[at + 1].toInt() and 0xff) shl 16) or
                    ((avcc[at + 2].toInt() and 0xff) shl 8) or (avcc[at + 3].toInt() and 0xff)
                if (length <= 0 || length > avcc.size - at - 4) return null
                at += 4 + length
            }
            at = 0
            while (at < avcc.size) {
                val length = ((avcc[at].toInt() and 0xff) shl 24) or ((avcc[at + 1].toInt() and 0xff) shl 16) or
                    ((avcc[at + 2].toInt() and 0xff) shl 8) or (avcc[at + 3].toInt() and 0xff)
                avcc[at] = 0; avcc[at + 1] = 0; avcc[at + 2] = 0; avcc[at + 3] = 1
                at += 4 + length
            }
            return avcc.takeIf { it.isNotEmpty() }
        }

        /** [avcc]'s NAL units, each length-prefixed in [nalLength] bytes, as Annex B; null when they do not add up. */
        fun annexB(avcc: ByteArray, nalLength: Int): ByteArray? {
            val out = java.io.ByteArrayOutputStream(avcc.size + 16)
            var at = 0
            while (at < avcc.size) {
                if (at + nalLength > avcc.size) return null
                var length = 0
                repeat(nalLength) { length = (length shl 8) or (avcc[at + it].toInt() and 0xff) }
                at += nalLength
                if (length <= 0 || at + length > avcc.size) return null
                out.write(START)
                out.write(avcc, at, length)
                at += length
            }
            return out.toByteArray().takeIf { it.isNotEmpty() }
        }
    }
}

/** Runs [block] on the page's thread (the scope's own), whatever thread asks, in the order asked. */
private fun CoroutineScope.launchOnPage(block: suspend () -> Unit) {
    launch { block() }
}
