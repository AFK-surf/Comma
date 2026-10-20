package surf.comma.android.ui.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BackdropBlurLayoutTest {
    @Test fun `the ramp is full at the edge and gone at the band's inner end`() {
        assertEquals(1f, backdropAlphaAt(0f), 0f)
        assertEquals(0f, backdropAlphaAt(1f), 0f)
        assertEquals(0.5f, backdropAlphaAt(0.5f), 0.0001f)
    }

    @Test fun `the ramp only falls and is flat at both ends`() {
        var previous = backdropAlphaAt(0f)
        for (step in 1..100) {
            val value = backdropAlphaAt(step / 100f)
            assertTrue(value <= previous)
            previous = value
        }
        // Smoothstep: the first and last percent change far less than a linear ramp would.
        assertTrue(1f - backdropAlphaAt(0.01f) < 0.001f)
        assertTrue(backdropAlphaAt(0.99f) < 0.001f)
    }

    @Test fun `out of range fractions clamp`() {
        assertEquals(1f, backdropAlphaAt(-1f), 0f)
        assertEquals(0f, backdropAlphaAt(2f), 0f)
    }

    @Test fun `band layers grow in radius and reach less far into the band`() {
        val radii = (0 until BackdropBlurLayout.BAND_LAYERS).map(::bandLayerRadius)
        val reach = (0 until BackdropBlurLayout.BAND_LAYERS).map(::bandLayerReach)
        assertEquals(listOf(0.25f, 0.5f, 1f), radii)
        assertEquals(1f, reach.first(), 0f)
        assertTrue("the strongest layer still reaches past the solid part", reach.last() > 0f)
        assertEquals(reach.sortedDescending(), reach)
    }
}
