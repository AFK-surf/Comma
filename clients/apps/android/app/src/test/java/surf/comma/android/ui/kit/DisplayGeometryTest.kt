package surf.comma.android.ui.kit

import org.junit.Assert.assertEquals
import org.junit.Test

/** Panels follow the display's own corners, and header controls keep clear of a cutout that crosses their row. */
class DisplayGeometryTest {
    @Test
    fun aPanelIsNeverRounderThanTheDisplayCornerItSitsBy() {
        assertEquals(12f, DisplayCorners.cap(22f, 12f), 0f)
        assertEquals(22f, DisplayCorners.cap(22f, 90f), 0f)
        // A corner the system does not describe sets no limit.
        assertEquals(22f, DisplayCorners.cap(22f, DisplayCorners.UNKNOWN.bottomLeft), 0f)
    }

    @Test
    fun headerControlsMoveInPastACutoutThatCrossesTheirRow() {
        val header = Band(0, 0, 1000, 100)
        // A camera in the trailing edge, held sideways: the create action moves in past it.
        assertEquals(0 to 72, cutoutClearance(header, listOf(Band(920, 20, 980, 80)), margin = 16, spacing = 8))
        // One in the leading edge pushes the close button.
        assertEquals(72 to 0, cutoutClearance(header, listOf(Band(0, 10, 80, 60)), margin = 16, spacing = 8))
        // A cutout below the row, or one the margin already clears, changes nothing.
        assertEquals(0 to 0, cutoutClearance(header, listOf(Band(400, 200, 600, 260)), margin = 16, spacing = 8))
        assertEquals(0 to 0, cutoutClearance(header, listOf(Band(995, 0, 1000, 40)), margin = 16, spacing = 8))
    }
}
