package surf.comma.android.voice

import android.Manifest
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.NoiseSuppressor
import android.os.Process
import androidx.annotation.RequiresPermission
import java.util.concurrent.atomic.AtomicBoolean
import surf.comma.android.platform.logging.AppLog

/** One microphone per owner. Call start/close on IO; VoiceSession alone controls mute/pacing. */
class CallRecorder(
    private val session: VoiceSession,
    private val onFailure: () -> Unit,
) : AutoCloseable {
    private val recording = AtomicBoolean(false)
    private var record: AudioRecord? = null

    @Synchronized
    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    fun start() {
        if (recording.get()) return
        check(record == null) { "Recorder is still shutting down" }
        val minimum = AudioRecord.getMinBufferSize(24_000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        check(minimum > 0) { "Call PCM input is unsupported" }
        val input = AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, 24_000,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minimum, VoiceProtocol.FRAME_BYTES * 5))
        val effects = mutableListOf<AudioEffect>()
        try {
            check(input.state == AudioRecord.STATE_INITIALIZED) { "Could not initialize call input" }
            attachEffect(effects) {
                if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(input.audioSessionId) else null
            }
            attachEffect(effects) {
                if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(input.audioSessionId) else null
            }
            input.startRecording()
            check(input.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "Could not start call input" }
            record = input
            recording.set(true)
            Thread({
                try {
                    Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
                    readCallFrames(recording::get, { bytes, offset, count ->
                        input.read(bytes, offset, count, AudioRecord.READ_BLOCKING)
                    }, session::offerAudio)
                } catch (_: Exception) {
                    if (recording.getAndSet(false)) onFailure()
                } finally {
                    synchronized(this) {
                        recording.set(false)
                        effects.forEach { runCatching { it.release() } }
                        runCatching { input.release() }
                        record = null
                    }
                }
            }, "call-pcm-recorder").start()
        } catch (failure: Exception) {
            recording.set(false)
            record = null
            effects.forEach { runCatching { it.release() } }
            input.release()
            throw failure
        }
    }

    @Synchronized
    override fun close() {
        recording.set(false)
        // stop unblocks READ_BLOCKING. Its reader owns release, so no release/read race or join.
        record?.let { runCatching { it.stop() } }
    }

    private fun attachEffect(effects: MutableList<AudioEffect>, create: () -> AudioEffect?) {
        try {
            create()?.let { effect ->
                effects.add(effect)
                if (effect.setEnabled(true) != AudioEffect.SUCCESS) {
                    AppLog.warn("CallRecorder", "A call microphone effect could not be enabled")
                }
            }
        } catch (_: RuntimeException) {
            AppLog.warn("CallRecorder", "A call microphone effect is unavailable")
        }
    }
}

/** AudioRecord provides the clock. Short reads assemble one frame; rejected frames are discarded. */
internal fun readCallFrames(
    active: () -> Boolean,
    read: (ByteArray, Int, Int) -> Int,
    offer: (ByteArray) -> Boolean,
) {
    val frame = ByteArray(VoiceProtocol.FRAME_BYTES)
    var offset = 0
    while (active()) {
        val count = read(frame, offset, frame.size - offset)
        if (!active()) return
        check(count in 0..(frame.size - offset)) { "Call microphone read failed" }
        if (count == 0) { Thread.yield(); continue }
        offset += count
        if (offset == frame.size) {
            offer(frame) // VoiceSession copies accepted frames; a false result is never retried.
            offset = 0
        }
    }
}
