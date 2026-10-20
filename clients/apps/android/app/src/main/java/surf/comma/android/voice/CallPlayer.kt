package surf.comma.android.voice

import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Process
import java.util.ArrayDeque
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.locks.LockSupport

/** Minimal hardware boundary so queueing, interruption and hardware-clock tests run on the JVM. */
internal interface CallPcmTrack : AutoCloseable {
    val headPosition: Int
    val underruns: Int get() = 0
    fun play()
    fun write(pcm: ByteArray, offset: Int, count: Int): Int
    fun pauseAndFlush()
}

data class CallPlaybackProgress(val epoch: Long, val queued: Long, val written: Long, val played: Long, val underruns: Int)

/**
 * One continuously fed AudioTrack. Only nonblocking writes run under the queue monitor;
 * creation, release and owner callbacks never run under it. Mute/routing do not touch this queue.
 *
 * The writer runs on its own thread and owner callbacks on [callbacks]. With [ownThread] false
 * nothing runs by itself: a test runs the writer with [pump], so the order of events is its own.
 */
class CallPlayer internal constructor(
    private val trackFactory: () -> CallPcmTrack,
    private val onPlaybackStarted: () -> Unit,
    private val onFailure: () -> Unit,
    private val prioritize: () -> Unit,
    // A slow WebSocket callback must never hold up feeding the audio device.
    private val callbacks: Executor = Executors.newSingleThreadExecutor { Thread(it, "call-playback-events") },
    ownThread: Boolean = true,
) : PlaybackSink, AutoCloseable {
    constructor(onPlaybackStarted: () -> Unit, onFailure: () -> Unit) : this(
        ::AndroidCallPcmTrack, onPlaybackStarted, onFailure,
        { Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO) },
    )

    private class Chunk(val bytes: ByteArray, var offset: Int = 0)
    private class Mark(val frame: Long, val callback: () -> Unit)
    private val lock = Any()
    private val chunks = ArrayDeque<Chunk>()
    private val marks = ArrayDeque<Mark>()
    private val clock = PlaybackClock()
    private var track: CallPcmTrack? = null
    private var epoch = 0L
    private var playing = false
    private var reportedStart = false
    private var closed = false
    private var failed = false
    private val writer = if (ownThread) Thread(::writeLoop, "call-pcm-writer").apply { start() } else null

    /** Sample from an observer, never log from the writer. Counts are PCM frames, not bytes. */
    fun progress(): CallPlaybackProgress = synchronized(lock) {
        CallPlaybackProgress(epoch, clock.queuedFrames, clock.writtenFrames, clock.playedFrames,
            runCatching { track?.underruns ?: 0 }.getOrDefault(0))
    }

    override fun audio(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        require(VoiceProtocol.validAudio(pcm.size))
        synchronized(lock) {
            check(!closed && !failed) { "Call player unavailable" }
            check(clock.queuedFrames - clock.playedFrames + pcm.size / 2 <= MAX_PENDING_FRAMES) {
                "Call playback queue exceeded its bound"
            }
            chunks.addLast(Chunk(pcm))
            clock.enqueue(pcm.size)
        }
        LockSupport.unpark(writer)
    }

    override fun mark(name: String, onPlayed: () -> Unit) {
        synchronized(lock) {
            check(!closed && !failed) { "Call player unavailable" }
            marks.addLast(Mark(clock.queuedFrames, onPlayed))
        }
        LockSupport.unpark(writer)
    }

    override fun clear() {
        synchronized(lock) {
            epoch++
            chunks.clear()
            marks.clear()
            clock.reset()
            playing = false
            reportedStart = false
            // Pause/flush discard hardware-buffered data now, without waiting for the writer.
            // stop() on a streaming track can drain pending data, so it is deliberately unused.
            track?.pauseAndFlush()
        }
        LockSupport.unpark(writer)
    }

    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            runCatching { clear() }
        }
        LockSupport.unpark(writer)
        // The writer releases its own track. Never join here from a VoiceSession callback.
    }

    private enum class Step { WROTE, WAIT, STOP }

    private fun writeLoop() {
        try {
            prioritize()
        } catch (_: Exception) {
            stop(failure = true)
            return
        }
        while (true) when (advance()) {
            Step.WROTE -> Unit
            // Polling only observes hardware progress; time/tick counts never advance marks.
            // Fill all available buffer capacity before waiting, including after a delayed wake.
            Step.WAIT -> LockSupport.parkNanos(this, 5_000_000L)
            Step.STOP -> return
        }
    }

    /** Runs the writer on the caller until it would wait for the hardware ([ownThread] false). */
    internal fun pump() {
        while (advance() == Step.WROTE) Unit
    }

    private fun advance(): Step {
        val step = try {
            step()
        } catch (_: Exception) {
            stop(failure = true)
            return Step.STOP
        }
        if (step == Step.STOP) stop(failure = false)
        return step
    }

    /** The writer ends: a failure is reported unless the owner closed first, and the device is released. */
    private fun stop(failure: Boolean) {
        if (failure) {
            val notify = synchronized(lock) { failed = true; !closed }
            if (notify) callbacks.execute(onFailure)
        }
        val old = synchronized(lock) { track.also { track = null } }
        runCatching { old?.pauseAndFlush() }
        runCatching { old?.close() }
        (callbacks as? ExecutorService)?.shutdown()
    }

    private fun step(): Step {
        val needTrack = synchronized(lock) {
            if (closed || failed) return Step.STOP
            track == null && chunks.isNotEmpty()
        }
        if (needTrack) {
            val created = trackFactory()
            val keep = synchronized(lock) {
                if (closed) false else { track = created; true }
            }
            if (!keep) { created.close(); return Step.STOP }
        }
        synchronized(lock) {
            if (closed) return Step.STOP
            val active = track
            if (active != null) {
                clock.update(active.headPosition)
                if (!reportedStart && clock.playedFrames > 0) {
                    reportedStart = true
                    dispatch(epoch, onPlaybackStarted)
                }
            }
            while (marks.isNotEmpty() && clock.reached(marks.first.frame)) {
                dispatch(epoch, marks.removeFirst().callback)
            }
            val chunk = chunks.peekFirst()
            if (active != null && chunk != null) {
                if (!playing) { active.play(); playing = true }
                val remaining = chunk.bytes.size - chunk.offset
                val count = active.write(chunk.bytes, chunk.offset, minOf(remaining, VoiceProtocol.FRAME_BYTES))
                check(count in 0..minOf(remaining, VoiceProtocol.FRAME_BYTES) && count % 2 == 0) {
                    "Call audio write failed"
                }
                if (count > 0) {
                    chunk.offset += count
                    clock.written(count)
                    if (chunk.offset == chunk.bytes.size) chunks.removeFirst()
                    return Step.WROTE
                }
            }
        }
        return Step.WAIT
    }

    private fun dispatch(generation: Long, callback: () -> Unit) {
        callbacks.execute {
            val valid = synchronized(lock) { !closed && !failed && generation == epoch }
            // VoiceSession also checks callback identity if clear races with this invocation.
            if (valid) callback()
        }
    }

    private companion object {
        /*
         * The server writes at most ~0.6 s ahead of its real-time schedule and tolerates playback
         * up to 8 s behind it, expecting audio delayed by a downlink stall to arrive in one burst
         * and still be played. This bound only caps memory; it must stay above that window.
         */
        const val MAX_PENDING_FRAMES = 24_000L * 10
    }
}

private class AndroidCallPcmTrack : CallPcmTrack {
    private val track: AudioTrack
    init {
        val minimum = AudioTrack.getMinBufferSize(24_000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        check(minimum > 0) { "Call PCM output is unsupported" }
        val created = AudioTrack.Builder()
            .setAudioAttributes(callAudioAttributes())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(24_000)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(maxOf(minimum, 24_000 * 2 * 120 / 1_000))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        try {
            check(created.state == AudioTrack.STATE_INITIALIZED) { "Could not initialize call output" }
            created.setStartThresholdInFrames(1)
            track = created
        } catch (failure: Exception) { created.release(); throw failure }
    }

    override val headPosition: Int get() = track.playbackHeadPosition
    override val underruns: Int get() = track.underrunCount
    override fun play() = track.play()
    override fun write(pcm: ByteArray, offset: Int, count: Int): Int =
        track.write(pcm, offset, count, AudioTrack.WRITE_NON_BLOCKING)
    override fun pauseAndFlush() { track.pause(); track.flush() }
    override fun close() = track.release()
}
