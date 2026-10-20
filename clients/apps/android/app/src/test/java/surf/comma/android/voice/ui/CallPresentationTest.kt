package surf.comma.android.voice.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.R
import surf.comma.android.voice.CallAudioOutput
import surf.comma.android.voice.CallControllerState
import surf.comma.android.voice.CallPhase
import surf.comma.android.voice.CallResult
import surf.comma.android.voice.CallState
import surf.comma.android.voice.MICROPHONE_ACCESS_MESSAGE

class CallPresentationTest {
    private fun live(phase: CallPhase, connectedAt: Long? = null) =
        CallControllerState(id = 7, busy = true, call = CallState(phase = phase), connectedAtElapsedRealtime = connectedAt)

    private fun over(phase: CallPhase, result: CallResult, notice: String? = null) =
        CallControllerState(id = 7, busy = false, call = CallState(phase = phase, result = result), notice = notice)

    @Test fun `calling until connected, then a timer from the connection`() {
        assertEquals(CallStatus.Text(R.string.call_calling), CallPresentation.status(live(CallPhase.Preparing), false))
        assertEquals(CallStatus.Text(R.string.call_calling), CallPresentation.status(live(CallPhase.Calling), false))
        assertEquals(CallStatus.Timer(1_000), CallPresentation.status(live(CallPhase.Connected, 1_000), false))
    }

    @Test fun `the user's End reads as ended at once, an Ending the user did not ask for reads as ending`() {
        assertEquals(CallStatus.Text(R.string.call_ended), CallPresentation.status(live(CallPhase.Connected, 1_000), true))
        assertEquals(CallStatus.Text(R.string.call_ended), CallPresentation.status(live(CallPhase.Ending), true))
        assertEquals(CallStatus.Text(R.string.call_ending), CallPresentation.status(live(CallPhase.Ending), false))
    }

    @Test fun `each result has its own words`() {
        fun text(state: CallControllerState) = CallPresentation.status(state, false)
        assertEquals(CallStatus.Text(R.string.call_ended), text(over(CallPhase.Ended, CallResult.Ended)))
        assertEquals(CallStatus.Text(R.string.call_not_connected), text(over(CallPhase.Failed, CallResult.Busy)))
        assertEquals(CallStatus.Text(R.string.call_not_connected), text(over(CallPhase.Failed, CallResult.Unavailable)))
        assertEquals(CallStatus.Text(R.string.call_disabled), text(over(CallPhase.Failed, CallResult.Disabled)))
        assertEquals(CallStatus.Text(R.string.call_interrupted), text(over(CallPhase.Failed, CallResult.Interrupted)))
        assertEquals(CallStatus.Text(R.string.call_failed), text(over(CallPhase.Failed, CallResult.CredentialsExpired)))
    }

    @Test fun `a notice wins over the result, with the app's own words where it has them`() {
        assertEquals(CallStatus.Text(R.string.call_microphone_settings),
            CallPresentation.status(over(CallPhase.Failed, CallResult.Interrupted, MICROPHONE_ACCESS_MESSAGE), false))
        assertEquals(CallStatus.Notice("Something new."),
            CallPresentation.status(over(CallPhase.Failed, CallResult.Interrupted, "Something new."), false))
    }

    @Test fun `finished calls stay up as long as the notification`() {
        assertEquals(1_500L, CallPresentation.dwellMillis(over(CallPhase.Ended, CallResult.Ended)))
        assertEquals(4_000L, CallPresentation.dwellMillis(over(CallPhase.Failed, CallResult.Busy)))
        assertTrue(CallPresentation.isShown(live(CallPhase.Preparing)))
        assertTrue(CallPresentation.isShown(over(CallPhase.Ended, CallResult.Ended)))
        assertFalse(CallPresentation.isShown(CallControllerState()))
    }

    @Test fun `durations do not pad the minutes`() {
        assertEquals("0:00", CallPresentation.duration(0))
        assertEquals("0:27", CallPresentation.duration(27))
        assertEquals("2:13", CallPresentation.duration(133))
        assertEquals("12:05", CallPresentation.duration(725))
        assertEquals("1:02:09", CallPresentation.duration(3_729))
    }

    @Test fun `the output button is on while the speaker plays`() {
        val speaker = live(CallPhase.Connected).copy(outputs = listOf(CallAudioOutput.Speaker, CallAudioOutput.Phone),
            selected = CallAudioOutput.Speaker)
        assertTrue(CallPresentation.outputActive(speaker))
        assertFalse(CallPresentation.outputActive(speaker.copy(selected = CallAudioOutput.Phone)))
        assertEquals(CallAudioOutput.Speaker, CallPresentation.output(live(CallPhase.Preparing)))
        assertEquals(CallAudioOutput.Bluetooth, CallPresentation.output(speaker.copy(selected = CallAudioOutput.Bluetooth)))
    }
}
