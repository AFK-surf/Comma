package surf.comma.android.voice

import androidx.annotation.StringRes
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.voice.ui.CallPresentation

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

/** The phase's string [res]; a service [notice] replaces it once the call is no longer ongoing. */
internal data class CallNotificationText(@StringRes val res: Int, val ongoing: Boolean, val notice: String? = null)

internal const val MICROPHONE_ACCESS_MESSAGE = "Allow microphone access in Android Settings, then try again."

/** No Context: the notifier resolves the call UI's strings, so every surface uses the same terminal result wording. */
internal fun callNotificationText(state: CallControllerState): CallNotificationText {
    val ongoing = state.call.phase in setOf(CallPhase.Preparing, CallPhase.Calling, CallPhase.Connected, CallPhase.Ending)
    val res = when (state.call.phase) {
        CallPhase.Preparing, CallPhase.Calling -> R.string.call_calling
        CallPhase.Connected -> R.string.call_active
        CallPhase.Ending -> R.string.call_ending
        CallPhase.Failed, CallPhase.Idle, CallPhase.Ended -> CallPresentation.resultText(state)
    }
    return CallNotificationText(res, ongoing, state.notice?.takeUnless { ongoing })
}
