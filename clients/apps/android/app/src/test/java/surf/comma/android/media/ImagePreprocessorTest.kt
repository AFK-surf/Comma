package surf.comma.android.media

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.media.ExifInterface
import android.net.Uri
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.nio.file.Files
import java.util.Random

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], shadows = [JvmImageDecoder::class])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ImagePreprocessorTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()

    @Test fun reencodingRotatesPixelsAndRemovesAllExifIncludingGps() = runBlocking {
        withDirectory { root ->
            val input = image(root, "source.jpg", 120, 60, Bitmap.CompressFormat.JPEG)
            ExifInterface(input).apply {
                setAttribute(ExifInterface.TAG_ORIENTATION, "6")
                setAttribute(ExifInterface.TAG_MAKE, "synthetic-camera")
                setAttribute(ExifInterface.TAG_USER_COMMENT, "synthetic-private-comment")
                setAttribute(ExifInterface.TAG_GPS_LATITUDE, "12/1,18/1,0/1")
                setAttribute(ExifInterface.TAG_GPS_LATITUDE_REF, "N")
                setAttribute(ExifInterface.TAG_GPS_LONGITUDE, "45/1,36/1,0/1")
                setAttribute(ExifInterface.TAG_GPS_LONGITUDE_REF, "E")
                saveAttributes()
            }
            processor(root).prepare(Uri.fromFile(input)).use { output ->
                assertEquals(ImageDimensions(60, 120), output.dimensions)
                val exif = ExifInterface(output.file)
                assertNull(exif.getAttribute(ExifInterface.TAG_GPS_LATITUDE))
                assertNull(exif.getAttribute(ExifInterface.TAG_MAKE))
                assertNull(exif.getAttribute(ExifInterface.TAG_USER_COMMENT))
                assertEquals(ExifInterface.ORIENTATION_UNDEFINED, exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, 0))
                assertFalse(output.file.readBytes().toString(Charsets.ISO_8859_1).contains("Exif\u0000\u0000"))
                val bitmap = BitmapFactory.decodeFile(output.file.path)
                assertTrue(Color.red(bitmap.getPixel(30, 10)) > 240)
                bitmap.recycle()
            }
        }
    }

    @Test fun allEightExifOrientationsAreAppliedToPixels() = runBlocking {
        withDirectory { root ->
            val colors = intArrayOf(Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW)
            val topLeftByOrientation = intArrayOf(0, 1, 3, 2, 0, 2, 3, 1)
            for (orientation in 1..8) {
                val input = root.resolve("orientation-$orientation.jpg")
                val bitmap = Bitmap.createBitmap(120, 80, Bitmap.Config.ARGB_8888)
                for (y in 0 until 80) for (x in 0 until 120) {
                    bitmap.setPixel(x, y, colors[(if (y >= 40) 2 else 0) + (if (x >= 60) 1 else 0)])
                }
                input.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 100, it) }
                bitmap.recycle()
                ExifInterface(input).apply {
                    setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString())
                    saveAttributes()
                }
                processor(root).prepare(Uri.fromFile(input)).use { prepared ->
                    assertEquals(if (orientation >= 5) ImageDimensions(80, 120) else ImageDimensions(120, 80), prepared.dimensions)
                    val decoded = BitmapFactory.decodeFile(prepared.file.path)
                    val pixel = decoded.getPixel(10, 10)
                    val expected = colors[topLeftByOrientation[orientation - 1]]
                    assertTrue("orientation $orientation red", kotlin.math.abs(Color.red(pixel) - Color.red(expected)) < 15)
                    assertTrue("orientation $orientation green", kotlin.math.abs(Color.green(pixel) - Color.green(expected)) < 15)
                    assertTrue("orientation $orientation blue", kotlin.math.abs(Color.blue(pixel) - Color.blue(expected)) < 15)
                    decoded.recycle()
                }
            }
        }
    }

    @Test fun opaquePngBecomesJpegWhileTransparentPngStaysPng() = runBlocking {
        withDirectory { root ->
            for (transparent in listOf(false, true)) {
                val input = image(root, "$transparent.png", 80, 50, Bitmap.CompressFormat.PNG, transparent)
                processor(root).prepare(Uri.fromFile(input)).use {
                    assertEquals(if (transparent) UploadImageFormat.PNG else UploadImageFormat.JPEG, it.format)
                    assertEquals(ImageDimensions(80, 50), it.dimensions)
                }
            }
        }
    }

    @Test fun sampledDecodeMeetsEdgePixelAndActualEncodedSizeLimits() = runBlocking {
        withDirectory { root ->
            val input = image(root, "large.png", 5000, 1000, Bitmap.CompressFormat.PNG, noisy = true)
            processor(root, 80_000).prepare(Uri.fromFile(input)).use {
                assertTrue(it.dimensions.width <= 4096)
                assertTrue(it.dimensions.pixels <= 16_000_000)
                assertTrue(it.size in 1..80_000)
            }
        }
    }

    @Test fun gifIsPreservedExactlyAndOversizedGifIsRejected() = runBlocking {
        withDirectory { root ->
            val input = root.resolve("synthetic.gif")
            // A generated one-pixel GIF89a with one image and no external fixture.
            val bytes = byteArrayOf(71,73,70,56,57,97,1,0,1,0,-128,0,0,0,0,0,-1,-1,-1,44,0,0,0,0,1,0,1,0,0,2,2,68,1,0,59)
            input.writeBytes(bytes)
            processor(root).prepare(Uri.fromFile(input)).use { assertArrayEquals(bytes, it.file.readBytes()) }
            java.io.RandomAccessFile(input, "rw").use { it.setLength(MediaLimits.MAX_UPLOAD_BYTES + 1) }
            assertTrue(runCatching { processor(root).prepare(Uri.fromFile(input)) }.isFailure)
            assertTrue(root.resolve("output").listFiles().orEmpty().isEmpty())
        }
    }

    private fun processor(root: File, target: Long = MediaLimits.TARGET_BYTES) =
        AndroidImagePreprocessor(context.contentResolver, root.resolve("output"), targetBytes = target)

    private suspend fun withDirectory(block: suspend (File) -> Unit) {
        val root = Files.createTempDirectory("preprocess-test").toFile()
        try { block(root) } finally { root.deleteRecursively() }
    }

    private fun image(root: File, name: String, width: Int, height: Int, format: Bitmap.CompressFormat,
        transparent: Boolean = false, noisy: Boolean = false): File {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.RED)
        if (transparent) bitmap.setPixel(0, 0, Color.TRANSPARENT)
        if (noisy) {
            val random = Random(123)
            val row = IntArray(width)
            for (y in 0 until height) {
                for (x in row.indices) row[x] = random.nextInt() or (0xff shl 24)
                bitmap.setPixels(row, 0, width, 0, y, width, 1)
            }
        }
        return root.resolve(name).also { file -> file.outputStream().use { bitmap.compress(format, 100, it) }; bitmap.recycle() }
    }
}
