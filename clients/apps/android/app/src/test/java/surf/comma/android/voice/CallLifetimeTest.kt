package surf.comma.android.voice

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

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
        fun text(phase: CallPhase, result: CallResult? = null) = callNotificationText(CallState(phase = phase, result = result))
        assertEquals(CallNotificationText("Calling…", true), text(CallPhase.Preparing))
        assertEquals(CallNotificationText("Calling…", true), text(CallPhase.Calling))
        assertEquals(CallNotificationText("Voice call active", true), text(CallPhase.Connected))
        assertEquals(CallNotificationText("Ending…", true), text(CallPhase.Ending))
        assertEquals(CallNotificationText("Call ended", false), text(CallPhase.Ended, CallResult.Ended))
        assertEquals(CallNotificationText("Call ended", false), text(CallPhase.Idle))
        assertEquals(CallNotificationText("Call interrupted", false), text(CallPhase.Failed, CallResult.Interrupted))
        assertEquals(CallNotificationText("Call not connected", false), text(CallPhase.Failed, CallResult.Busy))
        assertEquals(CallNotificationText("Call not connected", false), text(CallPhase.Failed, CallResult.Unavailable))
        assertEquals(CallNotificationText("Call failed", false), text(CallPhase.Failed, CallResult.CredentialsExpired))
        assertEquals(CallNotificationText("Voice calls are disabled for this workspace.", false), text(CallPhase.Failed, CallResult.Disabled))
        assertEquals(CallNotificationText(MICROPHONE_ACCESS_MESSAGE, false),
            callNotificationText(CallState(phase = CallPhase.Failed), MICROPHONE_ACCESS_MESSAGE))
    }
}
