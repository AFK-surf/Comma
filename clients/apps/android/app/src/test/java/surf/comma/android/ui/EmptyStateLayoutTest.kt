package surf.comma.android.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The empty page places its headline and its suggestion row independently, so the thing
 * worth testing is that they never meet -- on a tall phone at rest, and on every short
 * viewport where they used to.
 */
class EmptyStateLayoutTest {

    private fun place(
        hostHeight: Int,
        dockHeight: Int,
        rowHeight: Int,
        headlineHeight: Int,
        glyphBlockHeight: Int = GLYPH,
        gap: Int = GAP,
    ) = EmptyStateLayout.place(
        hostHeight, dockHeight, rowHeight, headlineHeight, glyphBlockHeight, gap, ANCHOR,
    )

    /** Top of the row, in host coordinates: it is bottom-aligned, then lifted. */
    private fun rowTop(hostHeight: Int, rowHeight: Int, placement: EmptyStateLayout.Placement) =
        hostHeight - rowHeight + placement.rowTranslationY

    @Test
    fun `row rides the composer`() {
        val placement = place(hostHeight = 2400, dockHeight = 300, rowHeight = 110, headlineHeight = 380)
        assertEquals(-(300 + GAP).toFloat(), placement.rowTranslationY, 0f)
    }

    @Test
    fun `tall viewport keeps everything and honours the anchor`() {
        val placement = place(hostHeight = 2400, dockHeight = 300, rowHeight = 110, headlineHeight = 380)
        assertTrue(placement.showHeadline)
        assertTrue(placement.showGlyph)
        assertEquals(2400 * ANCHOR - 380 / 2f, placement.headlineTranslationY, 0.5f)
    }

    /**
     * The case the first cut got wrong: clamping the headline's lower bound to zero turned
     * "there is no room" into "put it at the top", and the two groups overlapped by 20px.
     */
    @Test
    fun `short viewport drops the dot field rather than overlapping the row`() {
        val host = 300
        val row = 44
        val placement = place(hostHeight = host, dockHeight = 100, rowHeight = row, headlineHeight = 160)
        assertTrue(placement.showHeadline)
        assertFalse("the field is the first thing to go", placement.showGlyph)
        val headlineBottom = placement.headlineTranslationY + (160 - GLYPH)
        assertTrue(
            "headline bottom $headlineBottom must clear row top ${rowTop(host, row, placement)}",
            headlineBottom + GAP <= rowTop(host, row, placement),
        )
    }

    @Test
    fun `viewport too short for even the text drops the headline but keeps the row`() {
        val placement = place(hostHeight = 200, dockHeight = 100, rowHeight = 44, headlineHeight = 160)
        assertFalse(placement.showHeadline)
        assertFalse(placement.showGlyph)
        assertEquals(-(100 + GAP).toFloat(), placement.rowTranslationY, 0f)
    }

    @Test
    fun `no room at all above the composer still places the row inside the host`() {
        val host = 120
        val row = 44
        val placement = place(hostHeight = host, dockHeight = 100, rowHeight = row, headlineHeight = 160)
        assertFalse(placement.showHeadline)
        // It cannot both clear a 100px composer and stay inside a 120px host, so it stays
        // inside the host: a readable row over the composer beats a clipped one under it.
        assertTrue(rowTop(host, row, placement) >= 0f)
    }

    /**
     * A growing IME is the same arithmetic with a taller dock. Sweeping it catches any
     * height where the anchor would win over the clamp.
     */
    @Test
    fun `groups never overlap across a keyboard animation`() {
        val host = 2400
        val row = 110
        val headline = 380
        for (dock in 300..1900 step 10) {
            val placement = place(hostHeight = host, dockHeight = dock, rowHeight = row, headlineHeight = headline)
            if (!placement.showHeadline) continue
            val height = if (placement.showGlyph) headline else headline - GLYPH
            val bottom = placement.headlineTranslationY + height
            assertTrue(
                "dock=$dock: headline bottom $bottom overlaps row top ${rowTop(host, row, placement)}",
                bottom + GAP <= rowTop(host, row, placement),
            )
            assertTrue("dock=$dock: headline pushed off the top", placement.headlineTranslationY >= 0f)
        }
    }

    /** A large font scale is a taller headline in the same viewport. */
    @Test
    fun `groups never overlap as the headline grows`() {
        val host = 2400
        val row = 160
        for (headline in 200..2400 step 20) {
            val placement = place(hostHeight = host, dockHeight = 300, rowHeight = row, headlineHeight = headline)
            if (!placement.showHeadline) continue
            val height = if (placement.showGlyph) headline else headline - GLYPH
            val bottom = placement.headlineTranslationY + height
            assertTrue(
                "headline=$headline: bottom $bottom overlaps row top ${rowTop(host, row, placement)}",
                bottom + GAP <= rowTop(host, row, placement),
            )
        }
    }

    /**
     * The caller feeds back the height the headline *would* have with its field, so a frame
     * that hid the field and a frame that never had one must decide the same thing.
     * Otherwise the two states alternate forever.
     */
    @Test
    fun `decision does not depend on what the previous frame decided`() {
        val fromVisible = place(300, 100, 44, headlineHeight = 160)
        val fromHidden = place(300, 100, 44, headlineHeight = (160 - GLYPH) + GLYPH)
        assertEquals(fromVisible, fromHidden)
    }

    /**
     * A headline that behaves like the layout does: hiding the field removes the field
     * *and* the gap below it, because the gap is the field's own margin. Settling it is
     * what the view hierarchy does over successive layout passes.
     */
    private class Headline(private val fullHeight: Int) {
        var glyphVisible = true

        private val measured get() = if (glyphVisible) fullHeight else fullHeight - GLYPH

        /** Runs placement until the visibility it asks for stops changing. */
        fun settle(hostHeight: Int, dockHeight: Int, rowHeight: Int): EmptyStateLayout.Placement {
            var placement = step(hostHeight, dockHeight, rowHeight)
            repeat(8) {
                val next = step(hostHeight, dockHeight, rowHeight)
                if (next == placement) return placement
                placement = next
            }
            throw AssertionError("placement never settled at host=$hostHeight dock=$dockHeight")
        }

        private fun step(hostHeight: Int, dockHeight: Int, rowHeight: Int): EmptyStateLayout.Placement {
            val natural = EmptyStateLayout.naturalHeadlineHeight(measured, glyphVisible, GLYPH)
            val placement = EmptyStateLayout.place(
                hostHeight, dockHeight, rowHeight, natural, GLYPH, GAP, ANCHOR,
            )
            glyphVisible = placement.showGlyph
            return placement
        }
    }

    /**
     * The bug this replaces: the gap hung off the title, so hiding the field removed 70 but
     * the caller added 84 back. A viewport that had shown the field would not show it again
     * after passing through a short one -- it needed 14px more than it started with.
     */
    @Test
    fun `a viewport that shows the field shows it again after a short one`() {
        for (host in 120..2400) {
            val direct = Headline(FULL).settle(host, DOCK, ROW)
            val viaShort = Headline(FULL).apply { settle(150, DOCK, ROW) }.settle(host, DOCK, ROW)
            assertEquals("host=$host: placement depends on history", direct, viaShort)
        }
    }

    @Test
    fun `settled placement never overlaps and never clips the row`() {
        for (host in 120..2400) {
            for (dock in intArrayOf(0, 100, DOCK, 900, 1800)) {
                val headline = Headline(FULL)
                val placement = headline.settle(host, dock, ROW)
                val top = host - ROW + placement.rowTranslationY
                assertTrue("host=$host dock=$dock: row top $top is above the host", top >= 0f)
                if (!placement.showHeadline) continue
                val height = if (placement.showGlyph) FULL else FULL - GLYPH
                assertTrue(
                    "host=$host dock=$dock: headline overlaps the row",
                    placement.headlineTranslationY + height + GAP <= top,
                )
            }
        }
    }

    /** The row gives up tracking the composer rather than being cut off by the host. */
    @Test
    fun `row stops at the top of the host instead of being clipped`() {
        val placement = place(hostHeight = 100, dockHeight = 400, rowHeight = 44, headlineHeight = 160)
        assertEquals(-(100 - 44).toFloat(), placement.rowTranslationY, 0f)
        assertFalse(placement.showHeadline)
    }

    private companion object {
        const val GAP = 16
        const val GLYPH = 84
        const val ANCHOR = 0.42f
        const val FULL = 380
        const val DOCK = 300
        const val ROW = 110
    }
}
