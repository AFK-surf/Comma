package surf.comma.android.voice

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RingbackTest {
    @Test fun repeatsAfterAssetDurationPlusThreeSecondsAndCancelsDuringPlayback() = runTest {
        val starts = mutableListOf<Long>()
        var released = 0
        val loop = RingbackLoop(this, { object : RingbackTone {
            override suspend fun playOnce() { starts += currentTime; delay(1_000) }
            override fun close() { released++ }
        } }, { fail("Playback should succeed") })
        loop.start(); loop.start(); runCurrent()
        advanceTimeBy(3_999); runCurrent()
        assertEquals(listOf(0L), starts)
        advanceTimeBy(1); runCurrent()
        assertEquals(listOf(0L, 4_000L), starts)
        loop.stop(); runCurrent(); advanceTimeBy(20_000)
        assertEquals(1, released)
        assertEquals(2, starts.size)
    }

    @Test fun durationIsReadFromTheToneAndCancelDuringSilencePreventsReplay() = runTest {
        var plays = 0
        var released = 0
        val loop = RingbackLoop(this, { object : RingbackTone {
            override suspend fun playOnce() { plays++; delay(1_500) }
            override fun close() { released++ }
        } }, { fail("Playback should succeed") })
        loop.start(); runCurrent(); advanceTimeBy(4_499); runCurrent()
        assertEquals(1, plays)
        loop.stop(); runCurrent(); advanceTimeBy(10_000)
        assertEquals(1, plays); assertEquals(1, released)
    }

    @Test fun playbackFailureIsReportedOnceWithoutRetryingOrEscaping() = runTest {
        var failures = 0
        var released = 0
        val loop = RingbackLoop(this, { object : RingbackTone {
            override suspend fun playOnce() { error("unavailable") }
            override fun close() { released++ }
        } }, { failures++ })
        loop.start(); runCurrent(); loop.start(); advanceTimeBy(20_000)
        assertEquals(1, failures); assertEquals(1, released)
        loop.stop()
    }

    @Test fun connectedDoesNotCreateASilentGapBeforeTheHardwareStarts() {
        val gate = RingbackGate()
        val calling = CallState(1, CallPhase.Calling)
        assertTrue(gate.update(calling))
        assertTrue(gate.update(calling.copy(started = VoiceMessage.Started("c", "pcm16_24k", 3600))))
        val connected = calling.copy(phase = CallPhase.Connected, receivedAudio = true)
        assertTrue(gate.update(connected))
        gate.playbackStarted(1)
        assertFalse(gate.update(connected))
        assertFalse(gate.update(connected.copy(phase = CallPhase.Ending)))
        assertTrue(gate.update(CallState(2, CallPhase.Preparing)))
        assertFalse(gate.update(CallState(2, CallPhase.Failed)))
    }

    @Test fun playbackBeforeConnectedIsNotUndoneByALateStateObservation() {
        val gate = RingbackGate()
        gate.playbackStarted(2)
        assertFalse(gate.update(CallState(2, CallPhase.Calling)))
        assertFalse(gate.update(CallState(2, CallPhase.Connected)))
    }

    @Test fun oldPlaybackAndTerminalEventsCannotStopANewCallRinging() {
        val gate = RingbackGate()
        assertTrue(gate.update(CallState(2, CallPhase.Preparing)))
        assertFalse(gate.playbackStarted(1))
        assertTrue(gate.update(CallState(1, CallPhase.Ended)))
        assertTrue(gate.update(CallState(2, CallPhase.Calling)))
    }
}
