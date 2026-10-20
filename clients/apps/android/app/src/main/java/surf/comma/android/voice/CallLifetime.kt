package surf.comma.android.voice

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Reserves ownership before Android delivers the service start, including concurrent taps. */
internal class CallSingleFlight(initialSequence: Long = 0L) {
    data class Claim(val id: Long, val created: Boolean)
    private var sequence = initialSequence
    private var held: Long? = null

    @Synchronized fun acquire(): Claim {
        held?.let { return Claim(it, false) }
        return Claim(++sequence, true).also { held = it.id }
    }

    @Synchronized fun release(id: Long) {
        if (held == id) held = null
    }
}

/** One terminal deadline per call. Repeated notifications cannot extend its visibility. */
internal class CallStopTimer(private val scope: CoroutineScope, private val stop: (Long) -> Unit) {
    private var scheduled: Long? = null
    private var job: Job? = null

    fun schedule(id: Long, failed: Boolean) {
        if (scheduled == id) return
        cancel()
        scheduled = id
        job = scope.launch {
            delay(if (failed) FAILED_MILLIS else ENDED_MILLIS)
            if (scheduled == id) stop(id)
        }
    }

    fun cancel() {
        job?.cancel()
        job = null
        scheduled = null
    }

    companion object {
        const val ENDED_MILLIS = 1_500L
        const val FAILED_MILLIS = 4_000L
    }
}

internal data class CallNotificationText(val text: String, val ongoing: Boolean)

internal const val MICROPHONE_ACCESS_MESSAGE = "Allow microphone access in Android Settings, then try again."

/** No Android dependency: every surface uses the same terminal result wording. */
internal fun callNotificationText(state: CallState, notice: String? = null): CallNotificationText {
    val ongoing = state.phase in setOf(CallPhase.Preparing, CallPhase.Calling, CallPhase.Connected, CallPhase.Ending)
    val text = notice?.takeUnless { ongoing } ?: when (state.phase) {
        CallPhase.Preparing, CallPhase.Calling -> "Calling…"
        CallPhase.Connected -> "Voice call active"
        CallPhase.Ending -> "Ending…"
        CallPhase.Failed -> when (state.result) {
            CallResult.Interrupted -> "Call interrupted"
            CallResult.Busy, CallResult.Unavailable -> "Call not connected"
            CallResult.Disabled -> "Voice calls are disabled for this workspace."
            else -> "Call failed"
        }
        CallPhase.Idle, CallPhase.Ended -> "Call ended"
    }
    return CallNotificationText(text, ongoing)
}
