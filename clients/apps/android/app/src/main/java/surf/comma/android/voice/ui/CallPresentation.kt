package surf.comma.android.voice.ui

import androidx.annotation.StringRes
import surf.comma.android.R
import surf.comma.android.voice.CallAudioOutput
import surf.comma.android.voice.CallControllerState
import surf.comma.android.voice.CallPhase
import surf.comma.android.voice.CallResult
import surf.comma.android.voice.CallStopTimer
import surf.comma.android.voice.MICROPHONE_ACCESS_MESSAGE

/** What the call's status line says: a fixed phrase, a running timer, or the service's own notice. */
internal sealed interface CallStatus {
    data class Text(@StringRes val res: Int) : CallStatus
    data class Timer(val connectedAtElapsedRealtime: Long) : CallStatus
    /** A notice the service raised that has no string of its own here; shown as given. */
    data class Notice(val text: String) : CallStatus
}

internal object CallPresentation {
    /** Whether the call is over; its last words stay up for [dwellMillis], then the call UI goes. */
    fun isTerminal(state: CallControllerState): Boolean =
        !state.busy && state.call.phase in setOf(CallPhase.Ended, CallPhase.Failed)

    /** Whether there is anything to show: a call in progress, or one that just ended. */
    fun isShown(state: CallControllerState): Boolean = state.busy || isTerminal(state)

    /** As long as the service keeps its own notification, so the two leave together. */
    fun dwellMillis(state: CallControllerState): Long =
        if (state.call.phase == CallPhase.Failed) CallStopTimer.FAILED_MILLIS else CallStopTimer.ENDED_MILLIS

    /**
     * The status line. A notice wins while there is one, for an ended call, or for a live one that
     * cannot recover (a microphone revoked). [endingRequested] shows "Call ended" from the moment the
     * user taps End, before the service has reported it: to the user the call is over.
     */
    fun status(state: CallControllerState, endingRequested: Boolean): CallStatus {
        val phase = state.call.phase
        if (isTerminal(state)) {
            state.notice?.let { return notice(it) }
            return CallStatus.Text(resultText(state))
        }
        if (endingRequested) return CallStatus.Text(R.string.call_ended)
        if (phase == CallPhase.Ending) return CallStatus.Text(R.string.call_ending)
        val connectedAt = state.connectedAtElapsedRealtime
        if (phase == CallPhase.Connected && connectedAt != null) return CallStatus.Timer(connectedAt)
        return CallStatus.Text(R.string.call_calling)
    }

    @StringRes
    fun resultText(state: CallControllerState): Int = when (state.call.phase) {
        CallPhase.Failed -> when (state.call.result) {
            CallResult.Busy, CallResult.Unavailable -> R.string.call_not_connected
            CallResult.Disabled -> R.string.call_disabled
            CallResult.Interrupted -> R.string.call_interrupted
            else -> R.string.call_failed
        }
        else -> R.string.call_ended
    }

    /** The service's notices are English constants; the known ones get the app's own strings. */
    fun notice(text: String): CallStatus = when (text) {
        MICROPHONE_ACCESS_MESSAGE -> CallStatus.Text(R.string.call_microphone_settings)
        "Call interrupted" -> CallStatus.Text(R.string.call_interrupted)
        "Could not change audio output." -> CallStatus.Text(R.string.call_output_failed)
        else -> CallStatus.Notice(text)
    }

    /** `0:27`, `12:05`, `1:02:09`: minutes are not zero-padded. */
    fun duration(seconds: Long): String {
        val total = seconds.coerceAtLeast(0)
        val hours = total / 3600
        val minutes = total % 3600 / 60
        val secs = total % 60
        return if (hours > 0) "%d:%02d:%02d".format(hours, minutes, secs) else "%d:%02d".format(minutes, secs)
    }

    /** The output the call plays through, or the one it is about to: the service picks Speaker first. */
    fun output(state: CallControllerState): CallAudioOutput =
        state.selected ?: state.outputs.firstOrNull() ?: CallAudioOutput.Speaker

    @StringRes
    fun outputLabel(output: CallAudioOutput): Int = when (output) {
        CallAudioOutput.Headphones -> R.string.call_output_headphones
        CallAudioOutput.Bluetooth -> R.string.call_output_bluetooth
        CallAudioOutput.Speaker -> R.string.call_output_speaker
        CallAudioOutput.Phone -> R.string.call_output_phone
    }

    fun outputIcon(output: CallAudioOutput): Int = when (output) {
        CallAudioOutput.Headphones -> R.drawable.ic_call_headphones
        CallAudioOutput.Bluetooth -> R.drawable.ic_call_bluetooth
        CallAudioOutput.Speaker -> R.drawable.ic_call_speaker
        CallAudioOutput.Phone -> R.drawable.ic_call_phone
    }

    /** The output button reads as switched on when the call is out loud on the speaker. */
    fun outputActive(state: CallControllerState): Boolean = state.selected == CallAudioOutput.Speaker
}
