package surf.comma.android

import surf.comma.android.ui.widget.featherAlphaAt
import surf.comma.android.ui.widget.featherOverlayHeight
import surf.comma.android.ui.widget.featherStrengthFor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EdgeFeatherGeometryTest {

    /**
     * The claim the whole thing rests on: full opacity lands exactly on the top edge of the
     * composer card, so content is gone by the time the card would have clipped it.
     */
    @Test
    fun theRampEndsWhereTheComposerBegins() {
        val hostHeight = 2000
        val dockHeight = 260
        val feather = 132

        val overlayTop = hostHeight - featherOverlayHeight(dockHeight, feather)
        assertEquals(hostHeight - dockHeight, overlayTop + feather)
    }

    @Test
    fun theRampSitsOnTopOfTheGutterRatherThanInsideIt() {
        assertEquals(308, featherOverlayHeight(260, 48))
        assertEquals(48, featherOverlayHeight(0, 48))
        assertEquals(48, featherOverlayHeight(-10, 48))
    }

    @Test
    fun theRampIsFlatAtBothEndsSoNeitherShowsASeam() {
        assertEquals(0f, featherAlphaAt(0f), 0f)
        assertEquals(1f, featherAlphaAt(1f), 0f)
        assertEquals(0.5f, featherAlphaAt(0.5f), 1e-6f)
        // Smoothstep, not linear: the first and last tenth move less than a linear ramp would.
        assertTrue(featherAlphaAt(0.1f) < 0.1f)
        assertTrue(featherAlphaAt(0.9f) > 0.9f)
    }

    @Test
    fun theRampIsMonotonicAndClamped() {
        var previous = -1f
        for (step in 0..100) {
            val value = featherAlphaAt(step / 100f)
            assertTrue("alpha went backwards at $step", value >= previous)
            previous = value
        }
        assertEquals(0f, featherAlphaAt(-1f), 0f)
        assertEquals(1f, featherAlphaAt(2f), 0f)
    }

    /** At the end of the list there is nothing below to hide, so the feather has to be gone. */
    @Test
    fun theFeatherIsOffAtTheEndOfTheTimeline() {
        assertEquals(0f, featherStrengthFor(0, 132), 0f)
        assertEquals(0f, featherStrengthFor(-5, 132), 0f)
    }

    @Test
    fun theFeatherFadesItselfOutOverTheLastRampOfScroll() {
        assertEquals(0.5f, featherStrengthFor(66, 132), 1e-6f)
        assertEquals(1f, featherStrengthFor(132, 132), 0f)
        assertEquals(1f, featherStrengthFor(4000, 132), 0f)
    }

    @Test
    fun aZeroLengthFeatherIsNeverDrawn() {
        assertEquals(0f, featherStrengthFor(500, 0), 0f)
    }
}
