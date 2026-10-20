package surf.comma.android.platform.asr

import android.media.AudioRecord
import android.media.MediaRecorder
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowAudioRecord
import java.util.concurrent.CountDownLatch
import kotlin.math.PI
import kotlin.math.sin

/**
 * Microphone capture as far as a JVM test can take it: which source the recorder opens and whether
 * what that source delivers moves the voice bars. The simulated levels are those measured on a
 * phone with speech at arm's length: the plain microphone peaks around -31 dBFS, the
 * speech-recognition source (no device gain) around -55 dBFS.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AudioCaptureTest {
    @After fun clearSource() = ShadowAudioRecord.clearSource()

    @Test fun `speech captured from the recorder's source moves the voice bars`() {
        val capture = captureFrom { record -> if (record.audioSource == MediaRecorder.AudioSource.MIC) SPEECH_AT_MIC else SPEECH_WITHOUT_GAIN }

        assertEquals(MediaRecorder.AudioSource.MIC, capture.source)
        assertTrue("voice bars stayed flat: ${capture.peakBar}", capture.peakBar > 0.1f)
    }

    @Test fun `speech without device gain never opens the gate, which is why the plain microphone is used`() {
        assertEquals(0f, peakBar(speech(SPEECH_WITHOUT_GAIN)))
        assertTrue(peakBar(speech(SPEECH_AT_MIC)) > 0.1f)
    }

    @Test fun `a silent source leaves the bars flat`() {
        val capture = captureFrom { 0.0 }

        assertEquals(0f, capture.peakBar)
    }

    private class Capture(val source: Int, val peakBar: Float)

    /** Runs [AudioRecorder] against a simulated source whose amplitude depends on the opened record. */
    private fun captureFrom(amplitudeFor: (AudioRecord) -> Double): Capture {
        var source = -1
        ShadowAudioRecord.setSourceProvider { record ->
            source = record.audioSource
            val pcm = speech(amplitudeFor(record))
            var position = 0
            object : ShadowAudioRecord.AudioRecordSource {
                override fun readInByteArray(audioData: ByteArray, offsetInBytes: Int, sizeInBytes: Int, isBlocking: Boolean): Int {
                    for (i in 0 until sizeInBytes) audioData[offsetInBytes + i] = pcm[(position + i) % pcm.size]
                    position = (position + sizeInBytes) % pcm.size
                    return sizeInBytes
                }
            }
        }
        val spectrum = VoiceSpectrum()
        var peak = 0f
        val frames = CountDownLatch(FRAMES)
        val recorder = AudioRecorder()
        assertTrue(recorder.start { bytes, count ->
            if (frames.count > 0) {
                peak = maxOf(peak, spectrum.analyze(bytes, count, 0.0).max())
                frames.countDown()
            }
        })
        frames.await()
        recorder.stop()
        return Capture(source, peak)
    }

    private fun peakBar(pcm: ByteArray): Float {
        val spectrum = VoiceSpectrum()
        var peak = 0f
        pcm.toList().chunked(AudioRecorder.FRAME_BYTES).forEach { frame ->
            peak = maxOf(peak, spectrum.analyze(frame.toByteArray(), frame.size, 0.0).max())
        }
        return peak
    }

    private companion object {
        const val FRAMES = 5
        /** Per-partial amplitude for a -31 dBFS RMS three-partial vowel. */
        const val SPEECH_AT_MIC = 0.023
        /** The same vowel 24 dB quieter: -55 dBFS RMS. */
        const val SPEECH_WITHOUT_GAIN = 0.00145

        /** One second of a vowel-like sound: partials at 250, 700 and 1500 Hz, PCM16 LE. */
        fun speech(amplitude: Double): ByteArray {
            val samples = AudioRecorder.SAMPLE_RATE
            val out = ByteArray(samples * 2)
            for (i in 0 until samples) {
                val t = i.toDouble() / AudioRecorder.SAMPLE_RATE
                val v = amplitude * (sin(2 * PI * 250 * t) + sin(2 * PI * 700 * t) + sin(2 * PI * 1500 * t))
                val s = (v * Short.MAX_VALUE).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                out[i * 2] = s.toByte()
                out[i * 2 + 1] = (s shr 8).toByte()
            }
            return out
        }
    }
}
