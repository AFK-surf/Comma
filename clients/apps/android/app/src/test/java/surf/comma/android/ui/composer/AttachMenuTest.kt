package surf.comma.android.ui.composer

import org.junit.Assert.*
import org.junit.Test

class AttachMenuTest {
    @Test fun `photo picker is capped at the free slots and the system limit`() {
        assertEquals(PhotoPick.Multiple(10), PhotoPick.forRemaining(10, 100))
        assertEquals(PhotoPick.Multiple(3), PhotoPick.forRemaining(3, 100))
        assertEquals(PhotoPick.Multiple(5), PhotoPick.forRemaining(10, 5))
    }

    @Test fun `one free slot uses the single picker and none opens nothing`() {
        assertEquals(PhotoPick.Single, PhotoPick.forRemaining(1, 100))
        assertEquals(PhotoPick.None, PhotoPick.forRemaining(0, 100))
        assertEquals(PhotoPick.None, PhotoPick.forRemaining(-1, 100))
    }

    @Test fun `menu lists camera photos files and disables them all when full`() {
        val open = AttachMenuState(remaining = 4, max = 10)
        assertEquals(listOf(AttachEntry.CAMERA, AttachEntry.PHOTOS, AttachEntry.FILES), open.entries)
        assertFalse(open.full)
        assertTrue(open.entries.all(open::enabled))

        val full = AttachMenuState(remaining = 0, max = 10)
        assertTrue(full.full)
        assertTrue(full.entries.none(full::enabled))
    }

    @Test fun `menu state follows the composer model`() {
        var next = 0
        val model = ComposerModel(maxAttachments = 3) { "a${next++}" }
        assertEquals(AttachMenuState(3, 3), AttachMenuState.of(model))
        model.addAttachments(3)
        assertTrue(AttachMenuState.of(model).full)
    }
}
