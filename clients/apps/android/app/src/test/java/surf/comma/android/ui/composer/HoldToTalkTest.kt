package surf.comma.android.ui.composer

import org.junit.Assert.assertEquals
import org.junit.Test
import surf.comma.android.ui.composer.HoldToTalk.Event

class HoldToTalkTest {
    private fun gesture() = HoldToTalk(touchSlop = 10f, cancelDistance = 200f, longPressMs = 400, maxDurationMs = 60_000)

    private fun recording(): HoldToTalk = gesture().apply {
        down(y = 1000f, now = 0)
        assertEquals(Event.Start, longPressElapsed(now = 400))
    }

    @Test
    fun `release after the hold sends`() {
        val hold = recording()
        assertEquals(Event.End(cancelled = false), hold.up())
    }

    @Test
    fun `slide up into the cancel zone and release cancels`() {
        val hold = recording()
        assertEquals(Event.None, hold.move(900f))
        assertEquals(Event.ZoneChanged(inCancelZone = true), hold.move(780f))
        assertEquals(Event.End(cancelled = true), hold.up())
    }

    @Test
    fun `sliding back out of the cancel zone sends again`() {
        val hold = recording()
        hold.move(700f)
        assertEquals(Event.ZoneChanged(inCancelZone = false), hold.move(950f))
        assertEquals(Event.End(cancelled = false), hold.up())
    }

    @Test
    fun `system cancel never sends`() {
        val hold = recording()
        assertEquals(Event.End(cancelled = true), hold.cancel())
    }

    @Test
    fun `sixty seconds ends the recording by itself`() {
        val hold = recording()
        assertEquals(Event.None, hold.tick(now = 400 + 59_999))
        assertEquals(10_001L, hold.remainingMs(now = 400 + 49_999))
        assertEquals(Event.End(cancelled = false, autoEnded = true), hold.tick(now = 400 + 60_000))
        // The finger lifts later: nothing more happens.
        assertEquals(Event.None, hold.up())
    }

    @Test
    fun `time limit inside the cancel zone cancels`() {
        val hold = recording()
        hold.move(500f)
        assertEquals(Event.End(cancelled = true, autoEnded = true), hold.tick(now = 60_400))
    }

    @Test
    fun `a quick release is a tap, not a recording`() {
        val hold = gesture()
        hold.down(1000f, now = 0)
        assertEquals(Event.None, hold.longPressElapsed(now = 399))
        assertEquals(Event.Abandoned(wasTap = true), hold.up())
    }

    @Test
    fun `moving before the hold starts abandons it`() {
        val hold = gesture()
        hold.down(1000f, now = 0)
        assertEquals(Event.Abandoned(wasTap = false), hold.move(960f))
        assertEquals(Event.None, hold.longPressElapsed(now = 500))
        assertEquals(Event.None, hold.up())
    }
}
