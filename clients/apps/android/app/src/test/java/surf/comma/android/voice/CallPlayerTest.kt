package surf.comma.android.voice

import java.util.ArrayDeque
import org.junit.Assert.*
import org.junit.Test

/** The writer and the owner callbacks run only when a test says: [Harness.settle] runs both. */
class CallPlayerTest {
    private class Track : CallPcmTrack {
        var head = 0
        var maxWrite = 240
        var written = 0
        var pauses = 0
        var released = false
        override val headPosition get() = head
        override fun play() = Unit
        override fun write(pcm: ByteArray, offset: Int, count: Int): Int {
            val accepted = minOf(count, maxWrite)
            if (accepted > 0) written += accepted
            return accepted
        }
        override fun pauseAndFlush() { pauses++; head = 0; written = 0 }
        override fun close() { released = true }
    }

    private class Harness(factory: (Harness) -> CallPcmTrack) {
        val events = mutableListOf<String>()
        /** Owner callbacks the player handed over and that have not run yet. */
        val callbacks = ArrayDeque<Runnable>()
        val player = CallPlayer({ factory(this) }, { events += "started" }, { events += "failed" }, {},
            callbacks = { callbacks.addLast(it) }, ownThread = false)

        /** The writer goes as far as the hardware lets it, then the owner callbacks run. */
        fun settle() {
            player.pump()
            while (callbacks.isNotEmpty()) callbacks.removeFirst().run()
        }

        /** The events since the last call. */
        fun taken(): List<String> = events.toList().also { events.clear() }
    }

    private fun harness(track: Track) = Harness { track }

    @Test fun partialWritesKeepFeedingAndMarksFollowHardwareRatherThanSubmission() {
        val track = Track()
        val call = harness(track)
        call.player.audio(ByteArray(4800))
        call.player.mark("same") { call.events += "one" }
        call.player.audio(ByteArray(4800))
        call.player.mark("same") { call.events += "two" }
        call.settle()
        assertEquals(9600, track.written)
        assertEquals(emptyList<String>(), call.taken())
        track.head = 2399
        call.settle()
        assertEquals(listOf("started"), call.taken())
        track.head = 2400
        call.settle()
        assertEquals(listOf("one"), call.taken())
        track.head = 4800
        call.settle()
        assertEquals(listOf("two"), call.taken())
        call.player.close()
        call.settle()
        assertTrue(track.released)
    }

    @Test fun clearFlushesImmediatelyAndDropsOldMarksBeforeANewTimeline() {
        val track = Track()
        val call = harness(track)
        call.player.audio(ByteArray(4800)); call.player.mark("reused") { call.events += "old" }
        call.settle()
        assertEquals(4800, track.written)
        call.player.clear()
        assertEquals(1, track.pauses)
        call.player.audio(ByteArray(960)); call.player.mark("reused") { call.events += "new" }
        call.settle()
        assertEquals(960, track.written)
        track.head = 480
        call.settle()
        assertEquals(listOf("started", "new"), call.taken())
    }

    @Test fun aCallbackThatHasNotReturnedDoesNotHoldUpTheWriterOrClear() {
        val track = Track()
        val call = harness(track)
        call.player.mark("empty") { call.events += "empty" }
        call.player.pump()
        // The callback is handed over and has not run; the writer goes on without it.
        assertEquals(1, call.callbacks.size)
        call.player.audio(ByteArray(4800))
        call.player.pump()
        assertEquals(4800, track.written)
        call.player.clear()
        assertEquals(1, track.pauses)
    }

    @Test fun clearDoesNotWaitForHardwareCreationAndCannotResurrectOldAudio() {
        val track = Track()
        // The owner clears while the device is being made.
        val call = Harness { it.player.clear(); track }
        call.player.audio(ByteArray(4800)); call.player.mark("old") { call.events += "old" }
        call.settle()
        assertEquals(0, track.written)
        call.player.audio(ByteArray(960)); call.player.mark("new") { call.events += "new" }
        call.settle()
        assertEquals(960, track.written)
        track.head = 480
        call.settle()
        assertEquals(listOf("started", "new"), call.taken())
    }

    @Test fun aFullDeviceBufferDoesNotAdvanceMarksAndQueueIsBounded() {
        val track = Track().apply { maxWrite = 0 }
        val call = harness(track)
        repeat(50) { call.player.audio(ByteArray(9600)) }
        call.player.mark("unplayed") { call.events += "unplayed" }
        assertThrows(IllegalStateException::class.java) { call.player.audio(ByteArray(960)) }
        call.settle()
        assertEquals(emptyList<String>(), call.taken())
        call.player.clear()
    }

    @Test fun audioDelayedByADownlinkStallIsPlayedInOrderAndMarksStillWaitForHardware() {
        val track = Track().apply { maxWrite = 960 }
        val call = harness(track)
        call.player.audio(ByteArray(4800)); call.player.mark("pace:1") { call.events += "pace:1" }
        call.settle()
        assertEquals(4800, track.written)
        track.head = 2400
        call.settle()
        assertEquals(listOf("started", "pace:1"), call.taken())
        // Starved, then 3.6 s arrives at once: 36 pieces of 100 ms with a mark after each 6.
        repeat(6) { batch ->
            repeat(6) { call.player.audio(ByteArray(4800)) }
            call.player.mark("pace:${batch + 2}") { call.events += "pace:${batch + 2}" }
        }
        call.settle()
        assertEquals(emptyList<String>(), call.taken())
        repeat(6) { batch ->
            val end = 2400 + (batch + 1) * 6 * 2400
            assertTrue(track.written >= end * 2)
            track.head = end - 1
            call.settle()
            assertEquals(emptyList<String>(), call.taken())
            track.head = end
            call.settle()
            assertEquals(listOf("pace:${batch + 2}"), call.taken())
        }
    }

    @Test fun deviceFailureIsReportedOnceAndResourcesAreReleased() {
        val track = Track().apply { maxWrite = -6 }
        val call = harness(track)
        call.player.audio(ByteArray(960))
        call.settle()
        call.settle()
        assertEquals(listOf("failed"), call.taken())
        assertTrue(track.released)
        assertThrows(IllegalStateException::class.java) { call.player.audio(ByteArray(960)) }
    }

    @Test fun sixtyFiveSecondsOfFramesAndMarksDoNotAccumulateDriftOrPause() {
        val track = Track().apply { maxWrite = 960 }
        val call = harness(track)
        repeat(650) { index ->
            call.player.audio(ByteArray(4800))
            call.player.mark("reused") { call.events += "$index" }
            call.settle()
            assertEquals((index + 1) * 4800, track.written)
            track.head = (index + 1) * 2400
            call.settle()
            assertEquals("$index", call.taken().last())
        }
        assertEquals(24_000 * 65 * 2, track.written)
        assertEquals(0, track.pauses)
    }
}
