package surf.comma.android.media

import android.graphics.*
import android.graphics.drawable.BitmapDrawable
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SendImagePresentationTest {
    private val context = RuntimeEnvironment.getApplication()
    private fun pixels(color: Int, width: Int = 80, height: Int = 160) =
        Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply { eraseColor(color) }
    private fun drawable(bitmap: Bitmap) = BitmapDrawable(context.resources, bitmap)
    private fun render(image: SendImagePresentation, now: Long, width: Int = 80, height: Int = 160): Bitmap =
        pixels(Color.TRANSPARENT, width, height).also { image.drawInto(Canvas(it), RectF(0f, 0f, width.toFloat(), height.toFloat()), 12f, now) }

    @Test fun changingApertureAlwaysScalesUniformlyAndKeepsCenter() {
        for ((w, h) in listOf(960 to 540, 640 to 640, 160 to 960, 160 to 3200)) {
            for (step in 0..100) {
                val box = RectF(31f, 79f, 31f + 64 + step * 2.13f, 79f + 64 + step * 4.19f)
                val actual = RectF()
                ImageCrop.cover(w, h, box, actual)
                assertEquals(actual.width() / w, actual.height() / h, .001f)
                assertEquals(box.centerX(), actual.centerX(), .001f)
                assertEquals(box.centerY(), actual.centerY(), .001f)
                assertTrue(actual.width() + .001 >= box.width())
                assertTrue(actual.height() + .001 >= box.height())
            }
        }
    }

    @Test fun previewSurvivesLateDecodeAndGeometryHandoffWithoutChangingPixels() {
        val source = pixels(Color.RED)
        val image = SendImagePresentation(Color.GRAY, 12f)
        image.hold(source)
        val lastFlight = render(image, 100)
        image.land()
        assertTrue(lastFlight.sameAs(render(image, 100_000)))
        assertSame(source, image.preview)
        image.ready(drawable(pixels(Color.BLUE)))
        assertTrue(lastFlight.sameAs(render(image, 100_016)))
        render(image, 100_090).also { assertEquals(255, Color.alpha(it.getPixel(40, 80))) }
        assertEquals(Color.BLUE, render(image, 100_200).getPixel(40, 80))
        assertNull(image.preview)
    }

    @Test fun readyWhileFlyingRetainsOneCompositionUntilLanding() {
        val image = SendImagePresentation(Color.GRAY, 12f)
        image.hold(pixels(Color.RED))
        image.ready(drawable(pixels(Color.BLUE)))
        assertEquals(Color.RED, render(image, 50_000).getPixel(40, 80))
        image.land()
        assertEquals(Color.RED, render(image, 50_010).getPixel(40, 80))
        assertEquals(Color.BLUE, render(image, 50_200).getPixel(40, 80))
    }

    @Test fun transparentPixelsKeepAlphaDuringHandoffAndAtRoundedEdge() {
        val image = SendImagePresentation(Color.GRAY, 12f)
        val source = pixels(0x8000ff00.toInt())
        image.hold(source)
        image.ready(drawable(pixels(0x8000ff00.toInt(), 160, 320)))
        image.land()
        for (ms in listOf(0L, 40, 75, 110, 150, 200)) {
            val frame = render(image, ms)
            assertEquals(128.0, Color.alpha(frame.getPixel(40, 80)).toDouble(), 1.0)
            assertEquals(0, Color.alpha(frame.getPixel(0, 0)))
        }
    }

    @Test fun missingPreviewUsesOnlyDrawablePixelsAndClearDropsEveryReference() {
        val image = SendImagePresentation(Color.GRAY, 12f)
        image.hold(null)
        assertEquals(Color.GRAY, render(image, 10_000).getPixel(40, 80))
        val ready = drawable(pixels(Color.BLUE))
        image.ready(ready)
        assertEquals(Color.BLUE, render(image, 10_010).getPixel(40, 80))
        image.clear()
        assertNull(image.preview)
        assertNull(image.target)
        assertNull(ready.callback)
        assertFalse(image.held)
        // A flight still stepping during a session invalidation must not resurrect its snapshot.
        image.hold(pixels(Color.RED))
        image.ready(ready)
        assertNull(image.preview)
        assertNull(image.target)
        assertEquals(Color.GRAY, render(image, 20_000).getPixel(40, 80))
    }

    @Test fun rowApertureIncludingRoundedHeightMatchesFinalFlightExactly() {
        val view = SendImageView(context)
        val source = pixels(Color.RED, 540, 960)
        view.presentation.hold(source)
        // Width-to-ratio rounding would yield 1259; the prepared row has fixed height 1260.
        view.measure(android.view.View.MeasureSpec.makeMeasureSpec(708, android.view.View.MeasureSpec.EXACTLY),
            android.view.View.MeasureSpec.makeMeasureSpec(1260, android.view.View.MeasureSpec.EXACTLY))
        view.layout(0, 0, 708, 1260)
        val flight = pixels(Color.TRANSPARENT, 708, 1260)
        view.presentation.drawInto(Canvas(flight), RectF(0f, 0f, 708f, 1260f), context.resources.getDimension(surf.comma.android.R.dimen.radius_4xl))
        val row = pixels(Color.TRANSPARENT, 708, 1260)
        view.draw(Canvas(row))
        assertTrue(flight.sameAs(row))
    }

    @Test fun rowAndFlightUseIdenticalPixelsAtEveryAspectRatio() {
        val image = SendImagePresentation(Color.GRAY, 12f)
        val grid = pixels(Color.WHITE)
        val paint = Paint().apply { color = Color.BLACK; style = Paint.Style.STROKE }
        Canvas(grid).drawCircle(40f, 80f, 25f, paint)
        image.hold(grid)
        for ((w, h) in listOf(64 to 64, 100 to 120, 80 to 160)) {
            val flight = render(image, 100, w, h)
            val row = pixels(Color.TRANSPARENT, w, h)
            image.setBounds(0, 0, w, h)
            image.draw(Canvas(row))
            assertTrue(flight.sameAs(row))
        }
    }
}
