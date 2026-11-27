package surf.comma.android.chat.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaImageGroupStateTest {
    @Test fun `constants match Web ChatPanelImageGroup 1 to 1`() {
        assertEquals(3, MediaImageGroupGeometry.STACK_THRESHOLD)
        assertEquals(2, MediaImageGroupGeometry.VISIBLE_SIDE_DEPTH)
        assertEquals(165f, MediaImageGroupGeometry.CARD_WIDTH_DP, 0f)
        assertEquals(220f, MediaImageGroupGeometry.CARD_HEIGHT_DP, 0.01f)
        assertEquals(12f, MediaImageGroupGeometry.CARD_RADIUS_DP, 0f)
        assertEquals(8f, MediaImageGroupGeometry.CARD_GAP_DP, 0f)
        assertEquals(0.5f, MediaImageGroupGeometry.BORDER_WIDTH_DP, 0f)
        assertEquals(320f, MediaImageGroupGeometry.SINGLE_MAX_WIDTH_DP, 0f)
        assertEquals(320f, MediaImageGroupGeometry.SINGLE_MAX_HEIGHT_DP, 0f)
        assertEquals(3.5f, MediaImageGroupGeometry.STACK_ROTATION_STEP_DEG, 0f)
        assertEquals(3f, MediaImageGroupGeometry.STACK_SHIFT_STEP_DP, 0f)
        assertEquals(0.03f, MediaImageGroupGeometry.STACK_SCALE_STEP, 0f)
        assertEquals(26f, MediaImageGroupGeometry.FAN_ALLOWANCE_HORIZONTAL_DP, 0f)
        assertEquals(8f, MediaImageGroupGeometry.FAN_ALLOWANCE_VERTICAL_DP, 0f)
        assertEquals(320L, MediaImageGroupGeometry.FLIGHT_DURATION_MS)
        assertEquals(240L, MediaImageGroupGeometry.FLIP_DURATION_MS)
        assertEquals(12L, MediaImageGroupGeometry.EXPAND_STAGGER_MS)
        assertEquals(8L, MediaImageGroupGeometry.COLLAPSE_STAGGER_MS)
    }

    @Test fun `single image caps width at min(320, floor(0_75 column)) and preserves ratio`() {
        assertEquals(268f, MediaImageGroupGeometry.singleMaxWidthDp(358f), 0f)
        assertEquals(250f, MediaImageGroupGeometry.singleMaxWidthDp(334f), 0f)
        assertEquals(320f, MediaImageGroupGeometry.singleMaxWidthDp(500f), 0f)

        // Wide 16:9 image fits max width without cropping.
        val wide = MediaImageGroupGeometry.singleImageSizeDp(358f, 1600, 900)
        assertEquals(268f, wide.widthDp, 0.01f)
        assertEquals(150.75f, wide.heightDp, 0.01f)

        // Tall 9:16 image caps height at 320dp and preserves ratio.
        val tall = MediaImageGroupGeometry.singleImageSizeDp(358f, 900, 1600)
        assertEquals(180f, tall.widthDp, 0.01f)
        assertEquals(320f, tall.heightDp, 0.01f)

        // Missing dimensions fall back to 4:3.
        val fallback = MediaImageGroupGeometry.singleImageSizeDp(358f, null, null)
        assertEquals(268f, fallback.widthDp, 0.01f)
        assertEquals(201f, fallback.heightDp, 0.01f)
    }

    @Test fun `expanded card width keeps 2-3 images in one row on phones and 165dp on wide screens`() {
        assertEquals(165f, MediaImageGroupGeometry.expandedCardWidthDp(520f, 2), 0f)
        assertEquals(165f, MediaImageGroupGeometry.expandedCardWidthDp(520f, 6), 0f)
        assertEquals(165f, MediaImageGroupGeometry.expandedCardWidthDp(358f, 2), 0f)
        assertEquals(114f, MediaImageGroupGeometry.expandedCardWidthDp(358f, 3), 0f)
        assertEquals(114f, MediaImageGroupGeometry.expandedCardWidthDp(358f, 6), 0f)
        assertEquals(163f, MediaImageGroupGeometry.expandedCardWidthDp(334f, 2), 0f)
        assertEquals(106f, MediaImageGroupGeometry.expandedCardWidthDp(334f, 3), 0f)

        assertEquals(2, MediaImageGroupGeometry.expandedColumnCount(334f, 2))
        assertEquals(3, MediaImageGroupGeometry.expandedColumnCount(334f, 3))
        assertEquals(3, MediaImageGroupGeometry.expandedColumnCount(334f, 6))
        assertEquals(3, MediaImageGroupGeometry.expandedColumnCount(334f, 8))
    }

    @Test fun `cyclic two-pile browse reducer and slot assignment mirror Web exactly`() {
        val count = 6
        var state = MediaImageGroupBrowseState()
        assertEquals(
            listOf(
                ImageGroupStackSlot.FRONT,
                ImageGroupStackSlot.R1,
                ImageGroupStackSlot.R2,
                ImageGroupStackSlot.HIDDEN_RIGHT,
                ImageGroupStackSlot.HIDDEN_RIGHT,
                ImageGroupStackSlot.HIDDEN_RIGHT,
            ),
            (0 until count).map { state.slotFor(it, count) },
        )

        // Rotate +1 twice: cards 0 and 1 move to left history pile, card 2 is front.
        state = state.rotate(count, 1)
        assertEquals(MediaImageGroupBrowseState(frontIndex = 1, leftCount = 1), state)
        assertEquals(ImageGroupStackSlot.L1, state.slotFor(0, count))
        assertEquals(ImageGroupStackSlot.FRONT, state.slotFor(1, count))
        assertEquals(ImageGroupStackSlot.R1, state.slotFor(2, count))
        assertEquals(ImageGroupStackSlot.R2, state.slotFor(3, count))
        assertEquals(ImageGroupStackSlot.HIDDEN_RIGHT, state.slotFor(4, count))
        assertEquals(ImageGroupStackSlot.HIDDEN_RIGHT, state.slotFor(5, count))

        state = state.rotate(count, 1)
        assertEquals(MediaImageGroupBrowseState(frontIndex = 2, leftCount = 2), state)
        assertEquals(ImageGroupStackSlot.L2, state.slotFor(0, count))
        assertEquals(ImageGroupStackSlot.L1, state.slotFor(1, count))
        assertEquals(ImageGroupStackSlot.FRONT, state.slotFor(2, count))
        assertEquals(ImageGroupStackSlot.R1, state.slotFor(3, count))
        assertEquals(ImageGroupStackSlot.R2, state.slotFor(4, count))
        assertEquals(ImageGroupStackSlot.HIDDEN_RIGHT, state.slotFor(5, count))

        // Rotate -1 returns card 1 to front and pushes card 2 to R1.
        state = state.rotate(count, -1)
        assertEquals(MediaImageGroupBrowseState(frontIndex = 1, leftCount = 1), state)
        assertEquals(ImageGroupStackSlot.L1, state.slotFor(0, count))
        assertEquals(ImageGroupStackSlot.FRONT, state.slotFor(1, count))
        assertEquals(ImageGroupStackSlot.R1, state.slotFor(2, count))

        // Cyclic wrap past 0 keeps leftCount clamped at 0 while wrapping frontIndex to count - 1.
        state = state.rotate(count, -1).rotate(count, -1)
        assertEquals(MediaImageGroupBrowseState(frontIndex = 5, leftCount = 0), state)
        assertEquals(ImageGroupStackSlot.FRONT, state.slotFor(5, count))
        assertEquals(ImageGroupStackSlot.R1, state.slotFor(0, count))

        // alignPreview and navigatePreview sync both frontIndex and leftCount.
        val aligned = state.alignPreview(count, 4)
        assertEquals(MediaImageGroupBrowseState(frontIndex = 4, leftCount = 4), aligned)
        assertEquals(ImageGroupStackSlot.FRONT, aligned.slotFor(4, count))
        assertEquals(ImageGroupStackSlot.R1, aligned.slotFor(5, count))
        assertEquals(ImageGroupStackSlot.L1, aligned.slotFor(3, count))
        assertEquals(ImageGroupStackSlot.L2, aligned.slotFor(2, count))
        assertEquals(ImageGroupStackSlot.HIDDEN_LEFT, aligned.slotFor(1, count))
        assertEquals(ImageGroupStackSlot.HIDDEN_LEFT, aligned.slotFor(0, count))

        val navNext = aligned.navigatePreview(count, 1)
        assertEquals(MediaImageGroupBrowseState(frontIndex = 5, leftCount = 5), navNext)
        // navigatePreview clamps at ends (does not wrap).
        assertEquals(navNext, navNext.navigatePreview(count, 1))
    }

    @Test fun `slot transforms, dimming, alpha and zIndex match Web CSS`() {
        assertEquals(5, ImageGroupStackSlot.FRONT.zIndex)
        assertEquals(0f, ImageGroupStackSlot.FRONT.translationXDp, 0f)
        assertEquals(0f, ImageGroupStackSlot.FRONT.rotationDeg, 0f)
        assertEquals(1f, ImageGroupStackSlot.FRONT.scale, 0f)
        assertEquals(0f, ImageGroupStackSlot.FRONT.dimAlpha, 0f)
        assertEquals(1f, ImageGroupStackSlot.FRONT.alpha, 0f)
        assertTrue(ImageGroupStackSlot.FRONT.paintsImage)

        assertEquals(4, ImageGroupStackSlot.R1.zIndex)
        assertEquals(3f, ImageGroupStackSlot.R1.translationXDp, 0f)
        assertEquals(3.5f, ImageGroupStackSlot.R1.rotationDeg, 0f)
        assertEquals(0.97f, ImageGroupStackSlot.R1.scale, 0.001f)
        assertEquals(0.08f, ImageGroupStackSlot.R1.dimAlpha, 0.001f)

        assertEquals(3, ImageGroupStackSlot.R2.zIndex)
        assertEquals(6f, ImageGroupStackSlot.R2.translationXDp, 0f)
        assertEquals(7f, ImageGroupStackSlot.R2.rotationDeg, 0f)
        assertEquals(0.94f, ImageGroupStackSlot.R2.scale, 0.001f)
        assertEquals(0.16f, ImageGroupStackSlot.R2.dimAlpha, 0.001f)

        assertEquals(-3f, ImageGroupStackSlot.L1.translationXDp, 0f)
        assertEquals(-3.5f, ImageGroupStackSlot.L1.rotationDeg, 0f)
        assertEquals(-6f, ImageGroupStackSlot.L2.translationXDp, 0f)
        assertEquals(-7f, ImageGroupStackSlot.L2.rotationDeg, 0f)

        assertEquals(0, ImageGroupStackSlot.HIDDEN_RIGHT.zIndex)
        assertEquals(0f, ImageGroupStackSlot.HIDDEN_RIGHT.alpha, 0f)
        assertFalse(ImageGroupStackSlot.HIDDEN_RIGHT.paintsImage)
        assertFalse(ImageGroupStackSlot.HIDDEN_LEFT.paintsImage)
    }

    @Test fun `throw-arc flight hits apex at 0_4 and swaps z-order at 0_6`() {
        val density = 3f
        val cardWidthPx = 165f * density
        val linear: (Float) -> Float = { it }

        val apex = MediaImageGroupGeometry.flightPose(
            t = 0.4f,
            step = 1,
            cardWidthPx = cardWidthPx,
            fromX = 0f,
            fromRotation = 0f,
            fromScale = 1f,
            fromAlpha = 1f,
            toSlot = ImageGroupStackSlot.L1,
            density = density,
            drawer = linear,
            softInOut = linear,
        )
        assertEquals(-347f, apex.translationXPx, 1f)
        assertEquals(-9f, apex.rotationDeg, 0.01f)
        assertEquals(0.96f, apex.scale, 0.001f)
        assertEquals(1f, apex.alpha, 0.001f)
        assertEquals(6, apex.zIndex)

        val beforeSwap = MediaImageGroupGeometry.flightPose(
            t = 0.59f, step = 1, cardWidthPx = cardWidthPx, fromX = 0f, fromRotation = 0f,
            fromScale = 1f, fromAlpha = 1f, toSlot = ImageGroupStackSlot.L1, density = density,
            drawer = linear, softInOut = linear,
        )
        val afterSwap = MediaImageGroupGeometry.flightPose(
            t = 0.60f, step = 1, cardWidthPx = cardWidthPx, fromX = 0f, fromRotation = 0f,
            fromScale = 1f, fromAlpha = 1f, toSlot = ImageGroupStackSlot.L1, density = density,
            drawer = linear, softInOut = linear,
        )
        assertEquals(6, beforeSwap.zIndex)
        assertEquals(ImageGroupStackSlot.L1.zIndex, afterSwap.zIndex)

        val end = MediaImageGroupGeometry.flightPose(
            t = 1f, step = 1, cardWidthPx = cardWidthPx, fromX = 0f, fromRotation = 0f,
            fromScale = 1f, fromAlpha = 1f, toSlot = ImageGroupStackSlot.L1, density = density,
            drawer = linear, softInOut = linear,
        )
        assertEquals(ImageGroupStackSlot.L1.translationXDp * density, end.translationXPx, 0.01f)
        assertEquals(ImageGroupStackSlot.L1.rotationDeg, end.rotationDeg, 0.01f)
        assertEquals(ImageGroupStackSlot.L1.scale, end.scale, 0.001f)
        assertEquals(ImageGroupStackSlot.L1.dimAlpha, end.dimAlpha, 0.001f)
    }
}
