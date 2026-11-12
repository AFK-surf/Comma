package surf.comma.android.voice

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test
import surf.comma.android.R
import surf.comma.android.voice.ui.CallPresentation

@OptIn(ExperimentalCoroutinesApi::class)
class CallLifetimeTest {
    @Test fun concurrentStartsHaveExactlyOneOwnerIncludingWhileServiceIsStarting() {
        val guard = CallSingleFlight()
        val executor = Executors.newFixedThreadPool(8)
        try {
            val ready = CountDownLatch(8)
            val go = CountDownLatch(1)
            val results = (1..8).map {
                executor.submit<CallSingleFlight.Claim> {
                    ready.countDown()
                    go.await()
                    guard.acquire()
                }
            }
            ready.await()
            go.countDown()
            val claims = results.map { it.get() }
            assertEquals(1, claims.count { it.created })
            assertEquals(1, claims.map { it.id }.distinct().size)
            assertEquals(CallSingleFlight.Claim(claims.first().id, false), guard.acquire())
        } finally { executor.shutdownNow() }
    }

    @Test fun lateReleaseCannotUnlockAnotherCall() {
        val guard = CallSingleFlight()
        val first = guard.acquire()
        guard.release(first.id)
        val second = guard.acquire()
        assertTrue(second.created)
        assertNotEquals(first.id, second.id)
        guard.release(first.id)
        assertEquals(second.copy(created = false), guard.acquire())
    }

    @Test fun normalEndStopsAt1500msAndRepeatedUpdatesDoNotMoveDeadline() = runTest {
        val stopped = mutableListOf<Long>()
        val timer = CallStopTimer(this, stopped::add)
        timer.schedule(1, false)
        runCurrent()
        advanceTimeBy(1_000)
        timer.schedule(1, false)
        advanceTimeBy(499)
        runCurrent()
        assertTrue(stopped.isEmpty())
        advanceTimeBy(1)
        runCurrent()
        assertEquals(listOf(1L), stopped)
    }

    @Test fun failureRemainsFor4000ms() = runTest {
        val stopped = mutableListOf<Long>()
        val timer = CallStopTimer(this, stopped::add)
        timer.schedule(2, true)
        runCurrent()
        advanceTimeBy(3_999)
        runCurrent()
        assertTrue(stopped.isEmpty())
        advanceTimeBy(1)
        runCurrent()
        assertEquals(listOf(2L), stopped)
    }

    @Test fun newCallAndServiceDestructionCancelOldStop() = runTest {
        val stopped = mutableListOf<Long>()
        val timer = CallStopTimer(this, stopped::add)
        timer.schedule(1, true)
        runCurrent()
        advanceTimeBy(1_000)
        timer.cancel()
        advanceTimeBy(4_000)
        runCurrent()
        assertTrue(stopped.isEmpty())
        timer.schedule(2, false)
        runCurrent()
        advanceTimeBy(1_000)
        timer.schedule(3, true)
        runCurrent()
        advanceTimeBy(3_999)
        runCurrent()
        assertTrue(stopped.isEmpty())
        advanceTimeBy(1)
        runCurrent()
        assertEquals(listOf(3L), stopped)
    }

    @Test fun notificationTextCoversEveryStateAndResult() {
        fun text(phase: CallPhase, result: CallResult? = null, notice: String? = null) =
            callNotificationText(CallControllerState(call = CallState(phase = phase, result = result), notice = notice))
        assertEquals(CallNotificationText(R.string.call_calling, true), text(CallPhase.Preparing))
        assertEquals(CallNotificationText(R.string.call_calling, true), text(CallPhase.Calling))
        assertEquals(CallNotificationText(R.string.call_active, true), text(CallPhase.Connected))
        assertEquals(CallNotificationText(R.string.call_ending, true), text(CallPhase.Ending))
        // A live call keeps its phase's words; a notice shows only once the call is over.
        assertEquals(CallNotificationText(R.string.call_active, true), text(CallPhase.Connected, notice = "Could not change audio output."))
        // Finished calls say what the call UI says.
        for (phase in listOf(CallPhase.Idle, CallPhase.Ended, CallPhase.Failed)) for (result in CallResult.entries) {
            val state = CallControllerState(call = CallState(phase = phase, result = result))
            assertEquals(CallNotificationText(CallPresentation.resultText(state), false), callNotificationText(state))
        }
        assertEquals(CallNotificationText(R.string.call_interrupted, false, MICROPHONE_ACCESS_MESSAGE),
            text(CallPhase.Failed, CallResult.Interrupted, MICROPHONE_ACCESS_MESSAGE))
    }
}
