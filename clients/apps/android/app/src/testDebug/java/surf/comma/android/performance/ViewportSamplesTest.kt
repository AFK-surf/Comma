package surf.comma.android.performance

import org.junit.Assert.*
import org.junit.Test

class ViewportSamplesTest {
    @Test fun returningToOriginalPositionDoesNotHideTransientDrift() {
        val samples = AnchorSamples(42, 100)
        listOf(100, 115, 82, 100).forEach(samples::sample)
        assertEquals(18, samples.maxAbsDeltaPx)
        assertEquals(0, samples.deltaPx)
        assertEquals(4, samples.samples)
        assertFalse(samples.failed)
    }

    @Test fun offscreenAnchorFailsEvenIfItReturns() {
        val samples = AnchorSamples(42, -40)
        listOf(-40, null, -40).forEach(samples::sample)
        assertTrue(samples.failed)
        assertEquals(0, samples.deltaPx)
    }

    @Test fun missingInitialAnchorNeverBecomesSuccessful() {
        val samples = AnchorSamples(null, null)
        samples.sample(100)
        assertTrue(samples.failed)
        assertNull(samples.deltaPx)
    }

    @Test fun bottomReturnDoesNotHideEarlierGap() {
        val samples = BottomSamples()
        listOf(0, 12, -7, 0).forEach { samples.sample(it, following = true) }
        assertTrue(samples.startedPinned)
        assertFalse(samples.alwaysPinned)
        assertEquals(12, samples.maxBottomDeviationPx)
        assertEquals(0, samples.afterOffsetPx)
        assertFalse(samples.failed)
    }

    @Test fun bottomGeometryAloneDoesNotImplyFollowMode() {
        val samples = BottomSamples()
        samples.sample(0, following = false)
        samples.sample(0, following = true)
        assertFalse(samples.startedPinned)
        assertFalse(samples.alwaysPinned)
    }

    @Test fun invisibleLastMessageRemainsAFailureAfterReturning() {
        val samples = BottomSamples()
        listOf(0, null, 0).forEach { samples.sample(it, following = true) }
        assertTrue(samples.failed)
        assertFalse(samples.alwaysPinned)
    }
}
