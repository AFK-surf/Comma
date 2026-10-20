package surf.comma.android.platform.asr

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import surf.comma.android.platform.logging.AppLog

/**
 * Wires microphone capture ([AudioRecorder]) to streaming recognition ([DoubaoAsrClient]).
 *
 * - [start]: fetch credentials, connect and record; frames stream to the server, partial text
 *   arrives through [Callbacks.onTranscript] and bar heights through [Callbacks.onSpectrum].
 * - [stop]: stop recording, send the last frame, and wait for [Callbacks.onFinal]. If the server
 *   does not answer within [finalTimeoutMs], the latest partial becomes the final text.
 * - [cancel]: stop and drop everything.
 *
 * Every callback runs on the main thread, and exactly one of [Callbacks.onFinal] or
 * [Callbacks.onError] ends a session. Nothing calls back after [cancel].
 * One instance serves one session.
 */
class SpeechRecognizer(
    private val credentialProvider: AsrCredentialProvider,
    private val finalTimeoutMs: Long = DEFAULT_FINAL_TIMEOUT_MS,
) {
    interface Callbacks {
        fun onTranscript(text: String)
        fun onFinal(text: String)
        fun onError(error: AsrError)
        /** Bar heights 0..1, one array per captured frame (about every 100 ms). */
        fun onSpectrum(bars: FloatArray) {}
    }

    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val recorder = AudioRecorder()
    private var client: DoubaoAsrClient? = null
    private var callbacks: Callbacks? = null
    @Volatile private var latest = ""
    /** Set once the session has ended in any way; guards every callback. */
    @Volatile private var ended = false
    private var stopRequested = false

    fun start(callbacks: Callbacks) {
        check(this.callbacks == null) { "SpeechRecognizer is single-use" }
        this.callbacks = callbacks
        scope.launch {
            val credentials = try {
                credentialProvider.credentials()
            } catch (error: Exception) {
                AppLog.warn(TAG, error, "Credential fetch failed")
                null
            }
            if (ended) return@launch
            if (credentials == null) return@launch fail(AsrError.NOT_CONFIGURED)
            connect(credentials)
        }
    }

    private fun connect(credentials: AsrCredentials) {
        val spectrum = VoiceSpectrum()
        val asr = DoubaoAsrClient(credentials)
        client = asr
        asr.start(object : DoubaoAsrClient.Listener {
            override fun onPartial(text: String) {
                latest = text
                main.post { if (!ended) callbacks?.onTranscript(text) }
            }

            override fun onFinal(text: String) {
                main.post { finish(text.ifEmpty { latest }) }
            }

            override fun onError(error: AsrError) {
                main.post { fail(error) }
            }
        })
        val started = recorder.start { bytes, count ->
            asr.sendAudio(bytes, count)
            val bars = spectrum.analyze(bytes, count, SystemClock.uptimeMillis() / 1000.0)
            main.post { if (!ended && !stopRequested) callbacks?.onSpectrum(bars) }
        }
        if (!started) return fail(AsrError.MICROPHONE)
        if (stopRequested) requestFinal()
    }

    /** Stop recording and ask for the final result. Must be called on the main thread. */
    fun stop() {
        if (ended || stopRequested) return
        stopRequested = true
        requestFinal()
        main.postDelayed({ finish(latest) }, finalTimeoutMs)
    }

    private fun requestFinal() {
        val active = client ?: return // still fetching credentials: connect() finishes the request
        recorder.stop()
        active.finish()
    }

    /** Drop everything; no further callbacks. */
    fun cancel() {
        if (ended) return
        ended = true
        teardown()
    }

    private fun finish(text: String) {
        if (ended) return
        ended = true
        val target = callbacks
        teardown()
        target?.onFinal(text)
    }

    private fun fail(error: AsrError) {
        if (ended) return
        ended = true
        val target = callbacks
        teardown()
        target?.onError(error)
    }

    private fun teardown() {
        main.removeCallbacksAndMessages(null)
        scope.cancel()
        recorder.stop()
        client?.cancel()
        client = null
        callbacks = null
    }

    private companion object {
        const val TAG = "SpeechRecognizer"
        const val DEFAULT_FINAL_TIMEOUT_MS = 2_500L
    }
}
