package surf.comma.android.media.viewer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ZoomStateTest {
    // A 4:3 picture in a 1000×2000 portrait view: fitted 1000×750, centred.
    private val geometry = ZoomGeometry(1000f, 2000f, 4000f, 3000f)

    @Test fun fittedIsScaleOneAndCentred() {
        assertEquals(0.25f, geometry.fitScale, 1e-6f)
        assertEquals(1000f, geometry.displayedWidth(ZoomState()), 1e-3f)
        assertEquals(750f, geometry.displayedHeight(ZoomState()), 1e-3f)
        assertEquals(ZoomState(), geometry.clamp(ZoomState(1f, 300f, -400f)))
    }

    @Test fun zoomKeepsTheFocusedPointUnderTheFingers() {
        val zoomed = geometry.zoomTo(ZoomState(), 2f, 800f, 1000f)
        // The point 300 px right of centre is now 600 px right of the picture's centre.
        assertEquals(-300f, zoomed.offsetX, 1e-3f)
        assertEquals(0f, zoomed.offsetY, 1e-3f)
        val screenX = 500f + zoomed.offsetX + 300f * 2f
        assertEquals(800f, screenX, 1e-3f)
    }

    @Test fun pinchMayOvershootButSettlingClampsToLimits() {
        val under = geometry.zoomBy(ZoomState(), 0.5f, 500f, 1000f)
        assertEquals(ZoomGeometry.MIN_GESTURE_SCALE, under.scale, 1e-6f)
        assertEquals(1f, geometry.clamp(under).scale, 1e-6f)
        val over = geometry.zoomBy(ZoomState(3f), 10f, 500f, 1000f)
        assertTrue(over.scale > geometry.maxScale)
        assertEquals(geometry.maxScale, geometry.clamp(over).scale, 1e-6f)
        assertEquals(1f, geometry.zoomBy(ZoomState(), 0.5f, 500f, 1000f, slack = false).scale, 1e-6f)
    }

    @Test fun panningStopsAtTheEdgeAndHandsTheRestToThePager() {
        val zoomed = ZoomState(2f) // 2000×1500: 500 px of travel each side horizontally, none vertically.
        val (moved, leftover) = geometry.panBy(zoomed, 300f, 50f)
        assertEquals(300f, moved.offsetX, 1e-3f)
        assertEquals(0f, moved.offsetY, 1e-3f) // Shorter than the view: stays centred.
        assertEquals(0f, leftover, 1e-3f)
        val (atEdge, rest) = geometry.panBy(moved, 400f, 0f)
        assertEquals(500f, atEdge.offsetX, 1e-3f)
        assertEquals(200f, rest, 1e-3f)
        assertFalse(geometry.canPan(atEdge, 10f))
        assertTrue(geometry.canPan(atEdge, -10f))
        assertFalse(geometry.canPan(ZoomState(), 10f))
    }

    @Test fun doubleTapZoomsIntoThePointThenBackToFit() {
        val target = geometry.doubleTapTarget(ZoomState(), 900f, 1000f)
        assertEquals(geometry.fillScale.coerceAtLeast(ZoomGeometry.DOUBLE_TAP_ZOOM), target.scale, 1e-4f)
        assertEquals(target, geometry.clamp(target))
        assertTrue("moves toward the tapped side", target.offsetX < 0)
        assertEquals(ZoomState(), geometry.doubleTapTarget(target, 100f, 100f))
    }

    @Test fun longPicturesCanZoomUntilTheyFillTwice() {
        val strip = ZoomGeometry(1000f, 2000f, 1000f, 20000f)
        assertEquals(10f, strip.fillScale, 1e-4f)
        assertEquals(20f, strip.maxScale, 1e-4f)
    }

    @Test fun decodesStepUpWithZoomWithinAPixelBudget() {
        assertEquals(1, ZoomResolution.level(1f))
        assertEquals(2, ZoomResolution.level(2f))
        assertEquals(4, ZoomResolution.level(3.5f))
        assertEquals(ZoomResolution.Box(1080, 2400), ZoomResolution.box(1080, 2400, 1, 16_000_000))
        assertEquals(ZoomResolution.Box(2160, 4800), ZoomResolution.box(1080, 2400, 2, 16_000_000))
        val capped = ZoomResolution.box(1080, 2400, 4, 16_000_000)
        assertTrue(capped.width.toLong() * capped.height <= 16_000_000)
        assertEquals(1080f / 2400f, capped.width.toFloat() / capped.height, 0.01f)
        // A source smaller than the box on both sides is already complete.
        assertTrue(ZoomResolution.reachedSource(800, 600, ZoomResolution.Box(1080, 2400)))
        assertFalse(ZoomResolution.reachedSource(1080, 810, ZoomResolution.Box(1080, 2400)))
    }

    @Test fun animationPathInterpolatesWithoutClamping() {
        val from = ZoomState(1f)
        val to = ZoomState(2f, 100f, -50f)
        assertEquals(ZoomState(1.5f, 50f, -25f), from.lerp(to, 0.5f))
        assertEquals(2.1f, from.lerp(to, 1.1f).scale, 1e-5f) // Spring overshoot is kept.
    }
}
