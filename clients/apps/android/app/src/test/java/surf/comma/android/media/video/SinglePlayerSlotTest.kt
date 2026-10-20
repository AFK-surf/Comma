package surf.comma.android.media.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SinglePlayerSlotTest {
    private class Player(val name: String) { var released = false }

    @Test fun aSecondOwnerReleasesTheFirstPlayerBeforeCreatingItsOwn() {
        val released = mutableListOf<String>()
        val slot = SinglePlayerSlot<Player> { it.released = true; released += it.name }
        var firstRevoked = false
        val first = slot.acquire("page A", { Player("a") }, onRevoked = { firstRevoked = true })
        assertSame(first, slot.acquire("page A", { Player("unused") }))
        val second = slot.acquire("page B", {
            assertTrue("released before the next one exists", first.released)
            Player("b")
        })
        assertTrue(firstRevoked)
        assertEquals(listOf("a"), released)
        // The first page leaving later must not release the second page's player.
        slot.release("page A")
        assertFalse(second.released)
        assertTrue(slot.active)
        slot.release("page B")
        assertTrue(second.released)
        assertFalse(slot.active)
        assertEquals(listOf("a", "b"), released)
    }
}
