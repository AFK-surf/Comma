package surf.comma.android.voice

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal interface RingbackTone : AutoCloseable {
    /** Plays once and waits for the asset's duration (or throws on playback failure). */
    suspend fun playOnce()
}

/** One coroutine owns one tone. Cancellation always releases it, including during the silent gap. */
internal class RingbackLoop(
    private val scope: CoroutineScope,
    private val createTone: suspend () -> RingbackTone,
    private val failed: () -> Unit,
) {
    private var job: Job? = null

    fun start() {
        if (job != null) return
        job = scope.launch {
            var tone: RingbackTone? = null
            try {
                tone = createTone()
                while (true) {
                    tone.playOnce()
                    delay(3_000)
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { failed() }
            finally { tone?.close() }
        }
    }

    fun stop() { job?.cancel(); job = null }
}

/** Connected requests the handoff; only actual PCM playback completes it. No elapsed-time guess. */
internal class RingbackGate {
    private var audioStarted = false
    private var generation = -1L
    private var ringing = false
    fun update(state: CallState): Boolean {
        if (state.generation < generation) return ringing
        if (state.generation != generation) { generation = state.generation; audioStarted = false }
        ringing = !audioStarted && state.phase in setOf(CallPhase.Preparing, CallPhase.Calling, CallPhase.Connected)
        return ringing
    }
    fun playbackStarted(generation: Long): Boolean {
        if (generation < this.generation) return false
        this.generation = generation
        audioStarted = true
        ringing = false
        return true
    }
}
