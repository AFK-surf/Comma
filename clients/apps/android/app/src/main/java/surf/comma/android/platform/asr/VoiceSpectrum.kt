package surf.comma.android.platform.asr

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Turns one PCM16 frame into bar heights (0..1) for the voice waveform.
 *
 * FFT the most recent [FFT_SIZE] samples, keep the 0–3 kHz speech band, average the perceptually
 * normalised magnitude (`sqrt(1 + dB/100)`) of [BANDS] control bands, then spline those into
 * [barCount] bars with a centre-weighted envelope and per-bar jitter so a steady tone still looks
 * alive. A noise gate with hysteresis flattens room noise to a line.
 *
 * Not thread-safe: one instance per capture thread.
 */
class VoiceSpectrum(val barCount: Int = DEFAULT_BARS) {
    private val re = FloatArray(FFT_SIZE)
    private val im = FloatArray(FFT_SIZE)
    private val window = FloatArray(FFT_SIZE) {
        (0.5 - 0.5 * cos(2.0 * PI * it / (FFT_SIZE - 1))).toFloat()
    }
    private val control = FloatArray(BANDS)
    private var gateOpen = false

    /** @param timeSec animation clock for the jitter, so bars keep moving between frames. */
    fun analyze(pcm: ByteArray, length: Int, timeSec: Double): FloatArray {
        val out = FloatArray(barCount)
        val samples = (length.coerceAtMost(pcm.size)) / 2
        if (samples <= 0) return out

        // Level gate on the whole frame: 7 dB of hysteresis stops flicker at the threshold.
        var energy = 0.0
        for (i in 0 until samples) {
            val s = sample(pcm, i) / 32768.0
            energy += s * s
        }
        val rms = sqrt(energy / samples)
        val levelDb = if (rms > 1e-7) 20.0 * log10(rms) else -120.0
        gateOpen = if (gateOpen) levelDb > GATE_CLOSE_DB else levelDb > GATE_OPEN_DB
        if (!gateOpen) return out

        val start = max(0, samples - FFT_SIZE)
        for (i in 0 until FFT_SIZE) {
            val index = start + i
            re[i] = if (index < samples) sample(pcm, index) / 32768f * window[i] else 0f
            im[i] = 0f
        }
        fft(re, im)
        val hiBin = (3000.0 * FFT_SIZE / AudioRecorder.SAMPLE_RATE).toInt()
        val span = hiBin.toFloat() / BANDS
        for (b in 0 until BANDS) {
            val lo = (b * span).toInt()
            val hi = max(lo + 1, ((b + 1) * span).toInt())
            var sum = 0f
            for (k in lo until hi) {
                // Hann coherent gain is 0.5; a full-scale sine peaks near N/4, which maps to 0 dBFS.
                val mag = sqrt(re[k] * re[k] + im[k] * im[k]) / (FFT_SIZE / 4f)
                val db = if (mag > 1e-7f) 20f * log10(mag) else -120f
                sum += normalizedDb(db)
            }
            control[b] = (sum / (hi - lo) * 1.1f).coerceAtMost(1f)
        }
        smoothWave(control, out, timeSec)
        return out
    }

    private fun sample(pcm: ByteArray, index: Int): Int =
        ((pcm[index * 2 + 1].toInt() shl 8) or (pcm[index * 2].toInt() and 0xFF)).toShort().toInt()

    /** sqrt(1 + dB/100): -100 dB → 0, -10 dB → ~0.95. */
    private fun normalizedDb(db: Float): Float {
        val c = db.coerceIn(-100f, -10f)
        return sqrt(max(0f, 1f + c / 100f))
    }

    companion object {
        const val DEFAULT_BARS = 32
        private const val FFT_SIZE = 1024
        private const val BANDS = 9
        private const val GATE_OPEN_DB = -45.0
        private const val GATE_CLOSE_DB = -52.0

        /**
         * Catmull-Rom spline from [control] points to `out.size` bars, times a sin^0.5 envelope
         * that narrows both ends, times a hashed per-bar wobble (0.44..1.0) so the contour never
         * reads as a smooth curve.
         */
        fun smoothWave(control: FloatArray, out: FloatArray, timeSec: Double) {
            fun fract(x: Double) = x - floor(x)
            val n = control.size
            if (out.size < 2 || n < 2) return
            for (i in out.indices) {
                val pos = i.toFloat() / (out.size - 1) * (n - 1)
                val i1 = pos.toInt().coerceAtMost(n - 2)
                val t = pos - i1
                val p0 = control[maxOf(0, i1 - 1)]
                val p1 = control[i1]
                val p2 = control[i1 + 1]
                val p3 = control[minOf(n - 1, i1 + 2)]
                val v = 0.5f * (
                    2f * p1 + (-p0 + p2) * t +
                        (2f * p0 - 5f * p1 + 4f * p2 - p3) * t * t +
                        (-p0 + 3f * p1 - 3f * p2 + p3) * t * t * t
                    )
                val p = i.toDouble() / (out.size - 1)
                val taper = sin(Math.PI * p).pow(0.5)
                val h1 = fract(sin(i * 12.9898) * 43758.5453)
                val h2 = fract(sin(i * 78.233) * 12543.987)
                val wob = sin(timeSec * (6.0 + 6.0 * h1) + h2 * 2.0 * Math.PI)
                val jitter = 0.72 + 0.28 * wob
                out[i] = (v * (taper * jitter).toFloat()).coerceIn(0f, 1f)
            }
        }

        /** In-place iterative radix-2 FFT. */
        private fun fft(re: FloatArray, im: FloatArray) {
            val n = re.size
            var j = 0
            for (i in 0 until n - 1) {
                if (i < j) {
                    var t = re[i]; re[i] = re[j]; re[j] = t
                    t = im[i]; im[i] = im[j]; im[j] = t
                }
                var m = n shr 1
                while (m in 1..j) {
                    j -= m
                    m = m shr 1
                }
                j += m
            }
            var len = 2
            while (len <= n) {
                val ang = -2.0 * PI / len
                val half = len shr 1
                for (base in 0 until n step len) {
                    for (k in 0 until half) {
                        val wr = cos(ang * k).toFloat()
                        val wi = sin(ang * k).toFloat()
                        val a = base + k
                        val b = a + half
                        val tr = re[b] * wr - im[b] * wi
                        val ti = re[b] * wi + im[b] * wr
                        re[b] = re[a] - tr
                        im[b] = im[a] - ti
                        re[a] += tr
                        im[a] += ti
                    }
                }
                len = len shl 1
            }
        }
    }
}
