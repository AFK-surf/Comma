package surf.comma.android.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TabBarLensTest {
    @Test fun `a drag past either end stays on the end tab`() {
        assertEquals(0, tabAt(-40f, 100, 5))
        assertEquals(2, tabAt(250f, 100, 5))
        assertEquals(4, tabAt(900f, 100, 5))
    }

    @Test fun `the lens grows from the indicator's size to its lifted size`() {
        assertEquals(50f, lensSize(50f, 80f, 0f), 0f)
        assertEquals(80f, lensSize(50f, 80f, 1f), 0f)
    }

    @Test fun `a finger that stops near a tab rests the lens on it`() {
        assertEquals(250f, lensRest(240f, 100, 5), 0f)
        assertEquals(250f, lensRest(260f, 100, 5), 0f)
    }

    @Test fun `a finger that stops between tabs leaves the lens there`() {
        assertEquals(200f, lensRest(200f, 100, 5), 0f)
    }

    @Test fun `a release on its tab lands at once unless a tap has barely shown the lens`() {
        assertEquals(0L, lensLandDelay(900L))
        assertEquals(TabBarLens.MIN_UP_MS - 20L, lensLandDelay(20L))
    }

    @Test fun `the lifted lens keeps its shape over wide tabs and narrows over narrow ones`() {
        assertEquals(100f * TabBarLens.LIFTED_ASPECT, lensLiftedWidth(100f, 200f), 0f)
        assertEquals(60f * TabBarLens.LIFTED_TAB_SHARE, lensLiftedWidth(100f, 60f), 0f)
    }

    @Test fun `moving stretches the lens flat and rebounding makes it narrow and tall`() {
        assertTrue(lensWidthShare(0.1f) > 1f && lensHeightShare(0.1f) < 1f)
        assertTrue(lensWidthShare(-0.1f) < 1f && lensHeightShare(-0.1f) > 1f)
        assertEquals(1f, lensWidthShare(0f) * lensHeightShare(0f), 0f)
    }
}
