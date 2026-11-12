package surf.comma.android.ui.composer

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Handler
import android.os.HandlerThread
import kotlinx.coroutines.android.asCoroutineDispatcher
import kotlinx.coroutines.withContext
import surf.comma.android.platform.logging.AppLog
import surf.comma.android.voice.CallController
import java.io.File
import java.util.UUID

/**
 * Records dictation to an m4a file: 16 kHz mono AAC, which the server's transcription takes as `audio/mp4`.
 *
 * Starting the recorder takes a noticeable part of a second, so nothing here runs on the main thread. Everything runs
 * in order on one process-wide thread, so a stop always ends before the next start begins, and one composer's
 * recording refuses another's.
 *
 * Cost while recording: one amplitude read every [SAMPLE_MS], at most one recorder in the process.
 */
internal class DictationRecorder(context: Context) : DictationMicrophone {
    private val app = context.applicationContext
    private val manager = app.getSystemService(AudioManager::class.java)
    private val directory = File(app.cacheDir, "dictation")

    override suspend fun start(ended: () -> Unit): DictationCapture = withContext(dispatcher) { open(ended) }

    private fun open(ended: () -> Unit): DictationCapture {
        // A voice call holds the microphone; dictating would take its audio from it.
        if (manager.mode in CALL_MODES || CallController.get(app).state.value.busy) {
            throw DictationRefused(DictationFailure.VOICE_CALL)
        }
        if (active != null) throw DictationRefused(DictationFailure.MICROPHONE_UNAVAILABLE)
        // What an earlier process left when it died mid-recording.
        directory.listFiles()?.forEach { it.delete() }
        directory.mkdirs()
        val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANT)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setOnAudioFocusChangeListener({ change ->
                // A duck is a passing sound; these are something taking the audio for itself, such as a phone call.
                if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) ended()
            }, handler)
            .build()
        if (manager.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_FAILED) {
            throw DictationRefused(DictationFailure.VOICE_CALL)
        }
        val file = File(directory, "${UUID.randomUUID()}.m4a")
        val recorder = MediaRecorder(app)
        try {
            recorder.setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recorder.setAudioSamplingRate(SAMPLE_RATE)
            recorder.setAudioChannels(1)
            recorder.setAudioEncodingBitRate(BIT_RATE)
            recorder.setOutputFile(file)
            recorder.setOnErrorListener { _, _, _ -> ended() }
            recorder.registerAudioRecordingCallback(handler::post, object : AudioManager.AudioRecordingCallback() {
                override fun onRecordingConfigChanged(configs: List<AudioRecordingConfiguration>) {
                    if (configs.any { it.isClientSilenced }) ended()
                }
            })
            recorder.prepare()
            recorder.start()
        } catch (failure: Exception) {
            AppLog.warn(TAG, failure, "Dictation did not start")
            recorder.release()
            manager.abandonAudioFocusRequest(focus)
            file.delete()
            throw DictationRefused(DictationFailure.MICROPHONE_UNAVAILABLE)
        }
        return Capture(recorder, focus, file).also {
            active = it
            handler.post(it)
        }
    }

    /** Runs on the audio thread: each run reads the level. */
    private inner class Capture(
        private val recorder: MediaRecorder,
        private val focus: AudioFocusRequest,
        private val file: File,
    ) : DictationCapture, Runnable {
        @Volatile override var level = 0f
            private set

        override fun run() {
            // The peak since the last read.
            level = dictationLevel(runCatching { recorder.maxAmplitude }.getOrDefault(0))
            handler.postDelayed(this, SAMPLE_MS)
        }

        override suspend fun stop(): ByteArray? = withContext(dispatcher) {
            val finished = close()
            val audio = if (finished) runCatching { file.readBytes() }.getOrNull() else null
            file.delete()
            audio
        }

        override fun discard() {
            handler.post {
                close()
                file.delete()
            }
        }

        /** True when the file is complete: stopping throws when nothing reached it. */
        private fun close(): Boolean {
            handler.removeCallbacks(this)
            val finished = runCatching { recorder.stop() }.isSuccess
            recorder.release()
            manager.abandonAudioFocusRequest(focus)
            active = null
            return finished
        }
    }

    private companion object {
        const val TAG = "Dictation"
        const val SAMPLE_RATE = 16_000
        const val BIT_RATE = 32_000
        /** The waveform takes a bar every 110 ms; this gives each a few peaks to choose from. */
        const val SAMPLE_MS = 50L
        val CALL_MODES = setOf(AudioManager.MODE_IN_CALL, AudioManager.MODE_IN_COMMUNICATION, AudioManager.MODE_CALL_SCREENING)

        val handler by lazy { Handler(HandlerThread("dictation-audio").apply { start() }.looper) }
        val dispatcher by lazy { handler.asCoroutineDispatcher("dictation-audio") }
        /** The recording under way. Read and written on the audio thread. */
        var active: DictationCapture? = null
    }
}
