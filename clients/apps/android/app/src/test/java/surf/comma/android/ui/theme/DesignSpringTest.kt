package surf.comma.android.ui.theme

import android.annotation.SuppressLint
import androidx.dynamicanimation.animation.FloatPropertyCompat
import androidx.dynamicanimation.animation.FrameCallbackScheduler
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DesignSpringTest {
    @Test fun disabledAnimationsWriteTheTargetSynchronouslyWithoutSchedulingFrames() {
        val harness = Harness(15f)
        harness.enabled = false
        harness.controller.animateTo(120f, initialVelocity = 800f)
        assertEquals(120f, harness.value.current, 0f)
        assertEquals(120f, harness.controller.animation.spring!!.finalPosition, 0f)
        assertFalse(harness.controller.isRunning)
        assertEquals(0, harness.scheduledFrames)
    }

    @Test fun disablingAnimationsCancelsPendingRetargetAndJumpsToTheLatestEndpoint() {
        val harness = Harness()
        harness.controller.animateTo(120f)
        harness.frame()
        harness.frame(40)
        harness.controller.animateTo(-50f)
        harness.enabled = false
        harness.controller.animateTo(75f)
        assertEquals(75f, harness.value.current, 0f)
        assertEquals(75f, harness.controller.animation.spring!!.finalPosition, 0f)
        assertFalse(harness.controller.isRunning)

        // Re-enabling begins at the snapped value, with neither old velocity nor a stale target.
        harness.enabled = true
        harness.controller.animateTo(140f)
        harness.frame()
        assertEquals(75f, harness.value.current, 0f)
        assertEquals(0f, harness.velocity, 0f)
        harness.settle()
        assertEquals(140f, harness.value.current, 0f)
    }

    @Test fun retargetingARunningSpringPreservesItsPositionAndVelocity() {
        val harness = Harness(20f)
        harness.controller.animateTo(100f)
        harness.frame()
        harness.frame(40)
        val position = harness.value.current
        val velocity = harness.velocity
        assertTrue(velocity > 0f)
        val scheduledFrames = harness.scheduledFrames

        harness.controller.animateTo(-100f)
        harness.frame(0)
        assertEquals(position, harness.value.current, 0.001f)
        assertEquals(velocity, harness.velocity, 0.001f)
        assertEquals(scheduledFrames, harness.scheduledFrames)
        assertEquals(-100f, harness.controller.animation.spring!!.finalPosition, 0f)
        harness.settle()
        assertEquals(-100f, harness.value.current, 0f)
    }

    @Test fun shiftingARunningSpringMovesItsValueAndKeepsVelocityAndTarget() {
        val reference = Harness(0f)
        val shifted = Harness(0f)
        for (harness in listOf(reference, shifted)) {
            harness.controller.animateTo(100f)
            harness.frame()
            harness.frame(40)
        }
        val position = shifted.value.current
        val velocity = shifted.velocity
        shifted.controller.shiftBy(30f)
        assertEquals(position + 30f, shifted.value.current, 0f)
        shifted.frame(0)
        assertEquals(position + 30f, shifted.value.current, 0.001f)
        assertEquals(velocity, shifted.velocity, 0.001f)
        assertEquals(100f, shifted.controller.animation.spring!!.finalPosition, 0f)
        // One more frame: the shifted spring is where an unshifted one at +30 would be heading.
        reference.frame(0)
        reference.frame(16)
        shifted.frame(16)
        assertTrue(shifted.value.current > reference.value.current)
        shifted.settle()
        assertEquals(100f, shifted.value.current, 0f)
    }

    @Test fun shiftingAnIdleSpringOnlyMovesTheValue() {
        val harness = Harness(10f)
        harness.controller.shiftBy(-4f)
        assertEquals(6f, harness.value.current, 0f)
        assertFalse(harness.controller.isRunning)
        assertEquals(0, harness.scheduledFrames)
    }

    @Test fun gestureHandoffUsesVelocityInBothDirections() {
        for (velocity in listOf(-500f, 500f)) {
            val harness = Harness(30f)
            harness.controller.animateTo(100f, initialVelocity = velocity)
            harness.frame()
            assertEquals(30f, harness.value.current, 0f)
            assertEquals(velocity, harness.velocity, 0f)
            harness.controller.cancel()
        }
    }

    @Test fun anExplicitGestureVelocityCanReplaceTheVelocityOfARunningSpring() {
        val harness = Harness()
        harness.controller.animateTo(100f)
        harness.frame()
        harness.frame(40)
        val position = harness.value.current
        harness.controller.animateTo(-100f, initialVelocity = -700f)
        harness.frame(0)
        assertEquals(position, harness.value.current, 0.001f)
        assertEquals(-700f, harness.velocity, 0.001f)
        harness.settle()
        assertEquals(-100f, harness.value.current, 0f)
    }

    @Test fun cancellingAllowsTheNextAnimationToReadTheCurrentGesturePosition() {
        val harness = Harness()
        harness.controller.animateTo(100f)
        harness.frame()
        harness.frame(40)
        harness.controller.cancel()
        harness.value.current = 55f
        harness.controller.animateTo(120f)
        harness.frame()
        assertEquals(55f, harness.value.current, 0f)
        assertEquals(0f, harness.velocity, 0f)
        harness.settle()
        assertEquals(120f, harness.value.current, 0f)
    }

    @Test fun normalizedProgressCanOvershootItsEndpoint() {
        val harness = Harness(token = DesignMotion.springShake, minimumVisibleChange = 0.001f)
        harness.controller.animateTo(1f)
        var maximum = 0f
        while (harness.controller.isRunning) {
            harness.frame()
            maximum = maxOf(maximum, harness.value.current)
        }
        assertTrue("Spring progress was clamped: $maximum", maximum > 1.05f)
        assertEquals(1f, harness.value.current, 0f)
    }

    private class Value(var current: Float)

    private class Harness(
        initial: Float = 0f,
        token: DesignMotion.SpringToken = DesignMotion.springSpatial,
        minimumVisibleChange: Float? = null,
    ) {
        val value = Value(initial)
        var enabled = true
        var scheduledFrames = 0
        var velocity = 0f
        private var time = 1L
        val controller = DesignSpring(value, object : FloatPropertyCompat<Value>("current") {
            override fun getValue(target: Value): Float = target.current
            override fun setValue(target: Value, value: Float) { target.current = value }
        }, token, minimumVisibleChange) { enabled }

        init {
            controller.animation.scheduler = object : FrameCallbackScheduler {
                override fun isCurrentThread() = true
                override fun postFrameCallback(frameCallback: Runnable) { scheduledFrames++ }
            }
            controller.animation.addUpdateListener { _, _, currentVelocity -> velocity = currentVelocity }
        }

        // Advance the real AndroidX integrator without the Android frame clock in local JVM tests.
        @SuppressLint("RestrictedApi")
        fun frame(deltaMillis: Long = 16) {
            time += deltaMillis
            assertTrue("Spring did not settle within ten seconds", time < 10_000)
            controller.animation.doAnimationFrame(time)
        }

        fun settle() {
            while (controller.isRunning) frame()
        }
    }
}
