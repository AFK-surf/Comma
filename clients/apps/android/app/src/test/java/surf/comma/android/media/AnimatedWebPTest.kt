package surf.comma.android.media

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class AnimatedWebPTest {
    @Test fun joinsStillFramesIntoOneLoopingAnimation() {
        val opaque = still(chunk("VP8 ", byteArrayOf(1, 2, 3)))
        val clear = still(chunk("VP8X", ByteArray(10)), chunk("ALPH", byteArrayOf(9)), chunk("VP8 ", byteArrayOf(4, 5)))
        val webp = AnimatedWebP.of(listOf(AnimatedWebP.Frame(opaque, 80), AnimatedWebP.Frame(clear, 120)), 96)

        assertEquals("RIFF", String(webp, 0, 4))
        assertEquals(webp.size - 8, le(webp, 4, 4))
        assertEquals("WEBP", String(webp, 8, 4))
        val chunks = chunks(webp, 12)
        assertEquals(listOf("VP8X", "ANIM", "ANMF", "ANMF"), chunks.map { it.first })
        val vp8x = chunks[0].second
        // Animated, with alpha because one frame has it; a 96 px canvas.
        assertEquals(0x12, vp8x[0].toInt())
        assertEquals(95, le(vp8x, 4, 3))
        assertEquals(95, le(vp8x, 7, 3))
        // Loops for ever.
        assertEquals(0, le(chunks[1].second, 4, 2))
        val first = chunks[2].second
        assertEquals(80, le(first, 12, 3))
        assertEquals(0x02, first[15].toInt())
        assertEquals(listOf("VP8 "), chunks(first, 16).map { it.first })
        assertArrayEquals(byteArrayOf(1, 2, 3), chunks(first, 16)[0].second)
        val second = chunks[3].second
        assertEquals(120, le(second, 12, 3))
        assertEquals(listOf("ALPH", "VP8 "), chunks(second, 16).map { it.first })
        assertTrue(AnimatedWebP.isAnimated(webp))
        assertFalse(AnimatedWebP.isAnimated(opaque))
        assertFalse(AnimatedWebP.isAnimated(clear))
    }

    private fun still(vararg chunks: ByteArray): ByteArray {
        val body = chunks.fold(ByteArray(0)) { all, chunk -> all + chunk }
        return "RIFF".toByteArray() + u32(4 + body.size) + "WEBP".toByteArray() + body
    }

    private fun chunk(fourcc: String, payload: ByteArray) =
        fourcc.toByteArray() + u32(payload.size) + payload + (if (payload.size % 2 == 1) byteArrayOf(0) else ByteArray(0))

    private fun u32(value: Int) = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array()

    private fun le(bytes: ByteArray, at: Int, count: Int) =
        (0 until count).sumOf { (bytes[at + it].toInt() and 0xFF) shl (8 * it) }

    private fun chunks(bytes: ByteArray, from: Int): List<Pair<String, ByteArray>> {
        val out = mutableListOf<Pair<String, ByteArray>>()
        var at = from
        while (at < bytes.size) {
            val size = le(bytes, at + 4, 4)
            out += String(bytes, at, 4) to bytes.copyOfRange(at + 8, at + 8 + size)
            at += 8 + size + size % 2
        }
        return out
    }
}
