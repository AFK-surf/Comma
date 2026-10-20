package surf.comma.android.media

import org.junit.Assert.*
import org.junit.Test

class ImagePolicyTest {
    @Test fun edgePixelAndByteLimitsNeverUpscale() {
        assertEquals(ImageDimensions(4096, 2048), ImageSizing.fit(ImageDimensions(12000, 6000)))
        assertEquals(ImageDimensions(4000, 4000), ImageSizing.fit(ImageDimensions(8000, 8000)))
        assertEquals(ImageDimensions(90, 80), ImageSizing.fit(ImageDimensions(90, 80)))
        val reduced = ImageSizing.forByteBudget(ImageDimensions(4000, 4000), 8_000_000, 2_000_000)
        assertEquals(ImageDimensions(1900, 1900), reduced)
        assertEquals(ImageDimensions(1, 4096), ImageSizing.fit(ImageDimensions(1, Int.MAX_VALUE)))
        assertTrue(ImageSizing.fit(ImageDimensions(Int.MAX_VALUE, Int.MAX_VALUE)).pixels <= MediaLimits.MAX_PIXELS)
        assertEquals(ImageDimensions(1, 1), ImageSizing.forByteBudget(ImageDimensions(1, 1), 1000, 1))
    }

    @Test fun formatSelectionPreservesOnlySupportedTransparencyAndGif() {
        listOf("image/png", "image/webp").forEach {
            assertEquals(UploadImageFormat.PNG, UploadImageFormat.choose(it, true))
            assertEquals(UploadImageFormat.JPEG, UploadImageFormat.choose(it, false))
        }
        listOf("image/jpeg", "image/heic", "image/heif").forEach {
            assertEquals(UploadImageFormat.JPEG, UploadImageFormat.choose(it, true))
        }
        assertEquals(UploadImageFormat.GIF, UploadImageFormat.choose("image/gif", true))
        assertThrows(IllegalArgumentException::class.java) { UploadImageFormat.choose("image/svg+xml", true) }
    }

    @Test fun inlineFormatsAreClosedAndConflictingMetadataBecomesAFile() {
        listOf("png", "jpg", "jpeg", "gif", "webp").forEach {
            assertEquals(InlineMediaKind.IMAGE, InlineMediaPolicy.classify("a.$it", null))
            assertEquals(InlineMediaKind.IMAGE, InlineMediaPolicy.classify("a.$it", "application/octet-stream"))
        }
        assertEquals(InlineMediaKind.IMAGE, InlineMediaPolicy.classify("A.JPG", " IMAGE/JPG "))
        assertEquals(InlineMediaKind.IMAGE, InlineMediaPolicy.classify("image", "image/png"))
        listOf("svg", "html", "pdf", "heic", "exe").forEach {
            assertEquals(InlineMediaKind.FILE, InlineMediaPolicy.classify("a.$it", "image/png"))
        }
        assertEquals(InlineMediaKind.FILE, InlineMediaPolicy.classify("a.jpg", "image/png"))
        assertEquals(InlineMediaKind.FILE, InlineMediaPolicy.classify("a.png", "text/html"))
        assertEquals(InlineMediaKind.VIDEO, InlineMediaPolicy.classify("a.m4v", "video/x-m4v"))
    }
}
