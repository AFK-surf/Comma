package surf.comma.android.platform.asr

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import surf.comma.android.platform.logging.AppLog
import kotlin.concurrent.thread

/**
 * Microphone capture at 16 kHz / mono / PCM16 little-endian: the format the ASR endpoint
 * expects and what [AudioRecord] produces natively, so frames are forwarded without conversion.
 *
 * Each read block (100 ms) is handed to `onFrame` on the capture thread.
 * The caller must hold RECORD_AUDIO before calling [start].
 */
class AudioRecorder {
    private var record: AudioRecord? = null
    @Volatile private var running = false
    private var worker: Thread? = null

    /** @return false when the microphone is busy or could not be initialised. */
    @SuppressLint("MissingPermission")
    @Synchronized
    fun start(onFrame: (ByteArray, Int) -> Unit): Boolean {
        if (running) return true
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) return false
        val rec = try {
            AudioRecord(
                AUDIO_SOURCE,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf, FRAME_BYTES * 2),
            )
        } catch (error: Exception) {
            AppLog.warn(TAG, error, "Unable to create AudioRecord")
            return false
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return false
        }
        record = rec
        running = true
        try {
            rec.startRecording()
        } catch (error: Exception) {
            AppLog.warn(TAG, error, "Unable to start recording")
            running = false
            record = null
            rec.release()
            return false
        }
        worker = thread(name = "asr-audio") {
            val buf = ByteArray(FRAME_BYTES)
            try {
                while (running) {
                    val count = rec.read(buf, 0, buf.size)
                    if (count <= 0) break
                    if (running) onFrame(buf, count)
                }
            } finally {
                running = false
            }
        }
        return true
    }

    @Synchronized
    fun stop() {
        running = false
        val activeRecord = record
        // read() may block: stop the source first, then wait for the worker.
        activeRecord?.let {
            runCatching { it.stop() }
                .onFailure { error -> AppLog.debug(TAG, error, "Stop raced release") }
        }
        worker?.join(300)
        worker?.takeIf(Thread::isAlive)?.interrupt()
        worker = null
        activeRecord?.release()
        record = null
    }

    companion object {
        /**
         * The plain microphone, with the device's own gain control. The speech-recognition
         * source skips that gain on some phones: speech then peaks near -55 dBFS, which the
         * recogniser still copes with but which never opens the voice bars' noise gate.
         */
        const val AUDIO_SOURCE = MediaRecorder.AudioSource.MIC
        const val SAMPLE_RATE = 16_000
        /** 100 ms of 16 kHz / 16-bit / mono. */
        const val FRAME_BYTES = 3_200
        private const val TAG = "AudioRecorder"
    }
}
