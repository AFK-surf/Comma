package surf.comma.android.ui.theme

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Test

class DesignMotionTest {
    @Test fun springTokensCreateIndependentForcesWithTheSpecifiedPhysics() {
        val cases = listOf(
            Triple(DesignMotion.springSpatial, 275f, 0.90f),
            Triple(DesignMotion.springSize, 273f, 0.96f),
            Triple(DesignMotion.springWidth, 341f, 0.86f),
            Triple(DesignMotion.springFlight, 204f, 0.99f),
            Triple(DesignMotion.springEnter, 200f, 0.80f),
            Triple(DesignMotion.springScale, 600f, 0.70f),
            Triple(DesignMotion.springRotation, 400f, 0.80f),
            Triple(DesignMotion.springShake, 910f, 0.30f),
        )
        cases.forEach { (token, stiffness, damping) ->
            val first = token.createForce(42f)
            val second = token.createForce(-12f)
            assertNotSame(first, second)
            assertEquals(stiffness, first.stiffness, 0.001f)
            assertEquals(damping, first.dampingRatio, 0.001f)
            assertEquals(42f, first.finalPosition, 0f)
            first.setStiffness(1f).setDampingRatio(1f).setFinalPosition(0f)
            assertEquals(stiffness, second.stiffness, 0.001f)
            assertEquals(damping, second.dampingRatio, 0.001f)
            assertEquals(-12f, second.finalPosition, 0f)
        }
    }
}
