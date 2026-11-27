package surf.comma.android.home

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The cleared Routines' burst: where its pieces fly, and that none stays on the sheet. */
class RoutineConfettiTest {
    private val width = 360.0
    private val originY = 400.0

    @Test fun `each popper throws its pieces from its own edge, up and across the sheet`() {
        val burst = RoutineConfettiPiece.burst
        assertEquals("both poppers throw", 2, burst.map { it.side }.distinct().size)
        for (piece in burst) {
            val start = piece.pose(0.0, width, originY, density = 1.0)!!
            assertEquals("a piece leaves from its popper's edge", if (piece.side < 0) 0f else width.toFloat(), start.x, 0.01f)
            assertEquals(originY.toFloat(), start.y, 0.01f)
            val thrown = piece.pose(0.4, width, originY, density = 1.0)!!
            assertTrue("the throw rises", thrown.y < start.y)
            assertTrue("the throw goes across the sheet", if (piece.side < 0) thrown.x > start.x else thrown.x < start.x)
        }
    }

    @Test fun `a piece is whole through most of its flight, has faded by its end, and is gone after it`() {
        for (piece in RoutineConfettiPiece.burst) {
            assertNull("not drawn before it leaves its popper", piece.pose(-0.01, width, originY, density = 1.0))
            assertEquals(1f, piece.pose(piece.flight / 2, width, originY, density = 1.0)!!.opacity, 0f)
            assertEquals(0f, piece.pose(piece.flight, width, originY, density = 1.0)!!.opacity, 0.001f)
            assertNull("not drawn once its flight has ended", piece.pose(piece.flight + 0.01, width, originY, density = 1.0))
            assertTrue(piece.delay + piece.flight <= RoutineConfettiPiece.duration)
        }
        assertNotNull(RoutineConfettiPiece.burst.firstOrNull { it.kind == RoutineConfettiPiece.Kind.RIBBON })
    }
}
