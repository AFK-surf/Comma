package surf.comma.android.voice

/** Connected is a transport state. Expanded/minimized presentation belongs to the UI. */
enum class CallPhase { Idle, Preparing, Calling, Connected, Ending, Ended, Failed }

data class CallState(
    val generation: Long = 0,
    val phase: CallPhase = CallPhase.Idle,
    val started: VoiceMessage.Started? = null,
    val receivedAudio: Boolean = false,
    val result: CallResult? = null,
)

sealed interface CallSignal {
    val generation: Long
    data class Begin(override val generation: Long) : CallSignal
    data class RetryCredentials(override val generation: Long) : CallSignal
    data class Ready(override val generation: Long) : CallSignal
    data class Started(override val generation: Long, val info: VoiceMessage.Started) : CallSignal
    data class Audio(override val generation: Long) : CallSignal
    data class HangUp(override val generation: Long) : CallSignal
    data class Finished(override val generation: Long, val result: CallResult) : CallSignal
    data class DismissFailure(override val generation: Long) : CallSignal
    data class PermissionDenied(override val generation: Long) : CallSignal
}

object CallStateReducer {
    fun reduce(state: CallState, signal: CallSignal): CallState {
        if (signal is CallSignal.Begin) {
            return if (signal.generation > state.generation && state.phase in restartable)
                CallState(signal.generation, CallPhase.Preparing) else state
        }
        if (signal is CallSignal.RetryCredentials) {
            return if (signal.generation > state.generation && state.phase in live)
                CallState(signal.generation, CallPhase.Preparing) else state
        }
        if (signal.generation != state.generation) return state
        return when (signal) {
            is CallSignal.Ready -> if (state.phase == CallPhase.Preparing) state.copy(phase = CallPhase.Calling) else state
            is CallSignal.Started -> if (state.phase == CallPhase.Calling)
                connected(state.copy(started = signal.info)) else state
            is CallSignal.Audio -> if (state.phase == CallPhase.Calling)
                connected(state.copy(receivedAudio = true)) else state
            is CallSignal.HangUp -> if (state.phase in live) state.copy(phase = CallPhase.Ending) else state
            is CallSignal.Finished -> if (state.phase in live || state.phase == CallPhase.Ending)
                state.copy(phase = if (signal.result == CallResult.Ended) CallPhase.Ended else CallPhase.Failed,
                    result = signal.result) else state
            is CallSignal.DismissFailure -> if (state.phase == CallPhase.Failed) state.copy(phase = CallPhase.Ended) else state
            is CallSignal.PermissionDenied -> if (state.phase == CallPhase.Preparing) CallState(state.generation) else state
            is CallSignal.Begin, is CallSignal.RetryCredentials -> state
        }
    }

    private fun connected(state: CallState): CallState =
        if (state.started != null && state.receivedAudio) state.copy(phase = CallPhase.Connected) else state

    private val live = setOf(CallPhase.Preparing, CallPhase.Calling, CallPhase.Connected)
    private val restartable = setOf(CallPhase.Idle, CallPhase.Ended, CallPhase.Failed)
}
