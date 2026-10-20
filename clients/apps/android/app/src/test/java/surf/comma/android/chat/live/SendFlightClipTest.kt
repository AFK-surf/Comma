package surf.comma.android.chat.live

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SendFlightClipTest {
    private val chat = RectF(0f, 20f, 320f, 400f)
    private val source = RectF(20f, 420f, 84f, 484f)
    private val clip = SendFlightClip().apply { sourceInWindow.set(source) }
    private val paint = Paint().apply { color = Color.RED }

    /** Synthetic solid image: no personal photos, network, decoding or screenshot assumptions. */
    private fun draw(frame: RectF, viewport: RectF = chat, landed: Boolean = false): Bitmap {
        val bitmap = Bitmap.createBitmap(320, 600, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        clip.apply(canvas, viewport, frame, 0f, 0f, landed)
        canvas.drawRect(frame, paint)
        return bitmap
    }

    @Test fun `takeoff retains every source pixel but never expands across the input`() {
        val takeoff = draw(source)
        assertEquals(Color.RED, takeoff.getPixel(21, 421))
        assertEquals(Color.RED, takeoff.getPixel(83, 483))
        val growing = draw(RectF(10f, 300f, 240f, 540f))
        assertEquals(Color.RED, growing.getPixel(100, 399))
        assertEquals(Color.RED, growing.getPixel(21, 421))
        for (y in 400 until 600) for (x in 0 until 320) {
            if (!source.contains(x.toFloat(), y.toFloat())) assertEquals("input pixel $x,$y", 0, growing.getPixel(x, y))
        }
    }

    @Test fun `after leaving source a moving keyboard cannot reopen the aperture`() {
        draw(RectF(10f, 200f, 240f, 390f))
        val retargeted = draw(RectF(10f, -100f, 240f, 540f), RectF(0f, 20f, 320f, 300f))
        assertEquals(0, retargeted.getPixel(100, 19))
        assertEquals(Color.RED, retargeted.getPixel(100, 299))
        assertEquals(0, retargeted.getPixel(100, 300))
        assertEquals(0, retargeted.getPixel(21, 421))
    }

    @Test fun `landing clips oversized image and source even when rectangles overlap`() {
        val bitmap = draw(RectF(10f, -400f, 240f, 540f), landed = true)
        assertEquals(Color.RED, bitmap.getPixel(100, 399))
        assertEquals(0, bitmap.getPixel(21, 421))
        assertEquals(0, bitmap.getPixel(100, 10))
    }

    @Test fun `partly scrolled thumbnail only retains its visible source slice`() {
        clip.sourceInWindow.set(40f, 420f, 84f, 484f)
        val bitmap = draw(source)
        assertEquals(0, bitmap.getPixel(39, 450))
        assertEquals(Color.RED, bitmap.getPixel(40, 450))
    }
}
