package surf.comma.android.voice

import org.junit.Assert.*
import org.junit.Test

class CallStateReducerTest {
    private val info = VoiceMessage.Started("c", "pcm16_24k", 3600)
    private fun calling() = CallStateReducer.reduce(CallStateReducer.reduce(CallState(), CallSignal.Begin(1)), CallSignal.Ready(1))

    @Test fun connectedRequiresBothStartedAndAudioInEitherOrder() {
        val onlyStarted = CallStateReducer.reduce(calling(), CallSignal.Started(1, info))
        assertEquals(CallPhase.Calling, onlyStarted.phase)
        assertEquals(CallPhase.Connected, CallStateReducer.reduce(onlyStarted, CallSignal.Audio(1)).phase)
        val onlyAudio = CallStateReducer.reduce(calling(), CallSignal.Audio(1))
        assertEquals(CallPhase.Calling, onlyAudio.phase)
        assertEquals(CallPhase.Connected, CallStateReducer.reduce(onlyAudio, CallSignal.Started(1, info)).phase)
    }

    @Test fun normalLifecycleAndTerminalCallbacks() {
        var state = CallStateReducer.reduce(CallState(), CallSignal.Begin(1))
        assertEquals(CallPhase.Preparing, state.phase)
        state = CallStateReducer.reduce(state, CallSignal.Ready(1))
        assertEquals(CallPhase.Calling, state.phase)
        assertEquals(state, CallStateReducer.reduce(state, CallSignal.Begin(2)))
        state = CallStateReducer.reduce(state, CallSignal.HangUp(1))
        assertEquals(CallPhase.Ending, state.phase)
        assertEquals(state, CallStateReducer.reduce(state, CallSignal.Started(1, info)))
        state = CallStateReducer.reduce(state, CallSignal.Finished(1, CallResult.Ended))
        assertEquals(CallPhase.Ended, state.phase)
        assertEquals(state, CallStateReducer.reduce(state, CallSignal.Finished(1, CallResult.Interrupted)))
        assertEquals(CallPhase.Preparing, CallStateReducer.reduce(state, CallSignal.Begin(2)).phase)
    }

    @Test fun failuresRetainResultUntilDismissedAndNewGenerationIgnoresEveryOldSignal() {
        val failed = CallStateReducer.reduce(calling(), CallSignal.Finished(1, CallResult.Busy))
        assertEquals(CallPhase.Failed, failed.phase)
        val ended = CallStateReducer.reduce(failed, CallSignal.DismissFailure(1))
        assertEquals(CallPhase.Ended, ended.phase)
        assertEquals(CallResult.Busy, ended.result)
        val next = CallStateReducer.reduce(ended, CallSignal.Begin(2))
        listOf(CallSignal.Ready(1), CallSignal.Audio(1), CallSignal.Started(1, info), CallSignal.HangUp(1),
            CallSignal.Finished(1, CallResult.Interrupted), CallSignal.DismissFailure(1),
            CallSignal.PermissionDenied(1), CallSignal.RetryCredentials(1), CallSignal.Begin(1)).forEach {
            assertEquals(next, CallStateReducer.reduce(next, it))
        }
    }

    @Test fun credentialRetryResetsConnectionEvidenceAndPermissionDenialReturnsIdle() {
        val retry = CallStateReducer.reduce(CallStateReducer.reduce(calling(), CallSignal.Started(1, info)), CallSignal.RetryCredentials(2))
        assertEquals(CallState(2, CallPhase.Preparing), retry)
        assertEquals(CallState(2), CallStateReducer.reduce(retry, CallSignal.PermissionDenied(2)))
        assertEquals(calling(), CallStateReducer.reduce(calling(), CallSignal.PermissionDenied(1)))
    }
}
