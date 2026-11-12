package surf.comma.android.settings

import android.graphics.BitmapFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import surf.comma.android.media.AnimatedWebP
import surf.comma.android.media.GifFixtures

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class MovingAvatarTest {
    @Test fun aMovingGifGoesUpAsAMovingWebPOfItsFrames() {
        val webp = MovingAvatar.webp(GifFixtures.threeColours, SettingsRepository.AVATAR_MAX_BYTES)

        assertTrue(AnimatedWebP.isAnimated(webp))
        val frames = anmf(webp)
        // The 40 px GIF is drawn at the smallest side; each frame keeps its delay.
        assertEquals(listOf(100, 200, 300), frames.map { le(it, 12, 3) })
        assertEquals(95, le(frames[0], 6, 3))
        // Each frame is the still WebP Android wrote, in the GIF's colour.
        val colours = frames.map { frame ->
            val vp8 = frame.copyOfRange(16, frame.size)
            val still = "RIFF".toByteArray() + u32(4 + vp8.size) + "WEBP".toByteArray() + vp8
            BitmapFactory.decodeByteArray(still, 0, still.size).getPixel(48, 48)
        }
        val near = { actual: Int, expected: Int ->
            (0..24 step 8).all { shift -> kotlin.math.abs((actual shr shift and 0xFF) - (expected shr shift and 0xFF)) < 24 }
        }
        assertTrue(colours.toString(), near(colours[0], 0xFFFF0000.toInt()))
        assertTrue(colours.toString(), near(colours[1], 0xFF0000FF.toInt()))
        assertTrue(colours.toString(), near(colours[2], 0xFF00FF00.toInt()))
    }

    @Test fun fewerFramesStandForTheOnesLeftOut() {
        val frames = listOf(100, 200, 300).map { AnimatedWebP.Frame(ByteArray(0), it) }
        assertEquals(listOf(300, 300), MovingAvatar.everyNth(frames, 2).map { it.durationMs })
    }

    private fun anmf(webp: ByteArray): List<ByteArray> {
        val out = mutableListOf<ByteArray>()
        var at = 12
        while (at < webp.size) {
            val size = le(webp, at + 4, 4)
            if (String(webp, at, 4) == "ANMF") out += webp.copyOfRange(at + 8, at + 8 + size)
            at += 8 + size + size % 2
        }
        return out
    }

    private fun u32(value: Int) = byteArrayOf(value.toByte(), (value shr 8).toByte(), (value shr 16).toByte(), (value ushr 24).toByte())

    private fun le(bytes: ByteArray, at: Int, count: Int) =
        (0 until count).sumOf { (bytes[at + it].toInt() and 0xFF) shl (8 * it) }
}
