package surf.comma.android.voice

import org.junit.Assert.*
import org.junit.Test

class CallRecorderTest {
    @Test fun shortReadsProduceWholeFramesAndRejectedFramesAreNeverResent() {
        var consumed = 0
        val offered = mutableListOf<ByteArray>()
        readCallFrames({ consumed < 3 * 960 }, { bytes, offset, remaining ->
            val count = minOf(remaining, 137, 3 * 960 - consumed)
            repeat(count) { bytes[offset + it] = ((consumed + it) / 960 + 1).toByte() }
            consumed += count
            count
        }, { frame -> offered += frame.copyOf(); false })
        // active becomes false after the final read; the last frame must not escape teardown.
        assertEquals(2, offered.size)
        assertArrayEquals(ByteArray(960) { 1 }, offered[0])
        assertArrayEquals(ByteArray(960) { 2 }, offered[1])
    }

    @Test fun stoppingDuringReadDoesNotSendAPartialOrLateFrame() {
        var active = true
        var offers = 0
        readCallFrames({ active }, { _, _, count -> active = false; count }, { offers++; true })
        assertEquals(0, offers)
    }

    @Test fun recordingFailurePropagatesInsteadOfSendingStaleAudio() {
        assertThrows(IllegalStateException::class.java) {
            readCallFrames({ true }, { _, _, _ -> -6 }, { fail("No frame expected"); true })
        }
    }
}
