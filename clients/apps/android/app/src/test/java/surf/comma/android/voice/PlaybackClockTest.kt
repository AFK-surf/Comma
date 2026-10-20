package surf.comma.android.voice

import org.junit.Assert.*
import org.junit.Test

class PlaybackClockTest {
    @Test fun submittedAndWrittenAudioAreNotPlayedUntilHardwareReachesThem() {
        val clock = PlaybackClock()
        clock.enqueue(4800)
        val mark = clock.queuedFrames
        clock.written(960)
        clock.update(480)
        assertFalse(clock.reached(mark))
        clock.written(3840)
        repeat(100) { clock.update(480) }
        assertFalse(clock.reached(mark))
        clock.update(2399)
        assertFalse(clock.reached(mark))
        clock.update(2400)
        assertTrue(clock.reached(mark))
    }

    @Test fun headIsUnsignedAndWrapsWithoutLosingFrames() {
        val clock = PlaybackClock()
        repeat(5) { clock.enqueue(Int.MAX_VALUE - 1); clock.written(Int.MAX_VALUE - 1) }
        clock.update(Int.MAX_VALUE)
        assertEquals(0x7fff_ffffL, clock.playedFrames)
        clock.update(Int.MIN_VALUE)
        assertEquals(0x8000_0000L, clock.playedFrames)
        clock.update(-1)
        clock.update(100)
        assertEquals(0x1_0000_0064L, clock.playedFrames)
    }

    @Test fun flushResetsTheHeadAndMarksToANewTimeline() {
        val clock = PlaybackClock()
        clock.enqueue(4800); clock.written(4800); clock.update(2300)
        clock.reset()
        clock.enqueue(960); clock.written(960); clock.update(0)
        assertEquals(0L, clock.playedFrames)
        assertFalse(clock.reached(480))
        clock.update(480)
        assertTrue(clock.reached(480))
    }
}
