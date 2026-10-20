package surf.comma.android.scroll.physics

import org.junit.Assert.assertEquals
import org.junit.Test
import java.security.MessageDigest

private class Snapshot {
    private val digest = MessageDigest.getInstance("SHA-256")
    private var count = 0
    fun add(value: Float) = add(value.toRawBits())
    fun add(value: Boolean) = add(if (value) 1 else 0)
    private fun add(value: Int) {
        count++
        digest.update(byteArrayOf((value ushr 24).toByte(), (value ushr 16).toByte(), (value ushr 8).toByte(), value.toByte()))
    }
    fun result() = "$count:" + digest.digest().joinToString("") { "%02x".format(it) }
}
private fun rubberBandSnapshot(): String {
    val snapshot = Snapshot()
    for (range in floatArrayOf(-1f, 0f, 0.00001f, 1f, 48f, 360f, 1080f)) {
        for (distance in floatArrayOf(-10f, 0f, 0.00001f, 0.1f, 1f, 20f, 180f, 360f, 1080f, 10000f)) {
            snapshot.add(RubberBand.offset(distance, range))
            snapshot.add(RubberBand.distance(distance, range))
            snapshot.add(RubberBand.distance(RubberBand.offset(distance, range), range))
        }
    }
    return snapshot.result()
}
private fun scrollerSnapshot(): String {
    val snapshot = Snapshot()
    val scroller = Scroller()
    for (start in floatArrayOf(-512f, 0f, 17.5f, 1024f)) {
        for (velocity in floatArrayOf(-10f, -1f, -0.01f, -0.009f, 0f, 0.009f, 0.01f, 1f, 10f)) {
            scroller.fling(start, velocity)
            snapshot.add(scroller.finalOffset())
            for (time in 0..6000 step 8) {
                val value = scroller.value(time.toFloat())
                snapshot.add(value.value)
                snapshot.add(value.velocity)
                snapshot.add(value.isFinished)
            }
        }
    }
    return snapshot.result()
}
private fun springSnapshot(): String {
    val snapshot = Snapshot()
    val spring = SpringBack()
    for (initial in floatArrayOf(-360f, -20f, -0.1f, 0f, 0.1f, 20f, 360f)) {
        for (velocity in floatArrayOf(-10f, -1f, 0f, 1f, 10f, -initial / 100f)) {
            spring.absorb(velocity, initial)
            for (time in 0..4000 step 8) {
                val value = spring.value(time.toFloat())
                snapshot.add(value.value)
                snapshot.add(value.isFinished)
            }
        }
    }
    return snapshot.result()
}

/** Float-bit snapshots captured from 726d21b before the module migration. */
class ScrollPhysicsTest {
    @Test fun rubberBandMatchesBaselineIncludingInvalidAndClampedRanges() {
        assertEquals("210:6e3a2b5c96ea3789e3d27012a13d4a5ff093ceeaf4c12f89a53d3eeefc73b9ce", rubberBandSnapshot())
    }

    @Test fun flingsMatchBaselineInBothDirectionsAndAtTheStopThreshold() {
        assertEquals("81144:08dfba8dd7b07e1b04df37e4c3073b365a08d7fb7e476136e672f60a4edf1f44", scrollerSnapshot())
    }

    @Test fun springAbsorptionAndReleaseMatchBaselineThroughRest() {
        assertEquals("42084:32e01784d21f6670c9588a0ec5b8dcdf9897782729e7e4c2ab599335da456f23", springSnapshot())
    }
}
