package surf.comma.android

import surf.comma.android.chat.model.CoreMediaRef
import surf.comma.android.chat.model.CoreMediaThumbnail
import surf.comma.android.chat.render.MediaOrientation
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The parts of the media pipeline that decide things, away from the decoder.
 *
 * Bitmap and Matrix are stubs in a JVM unit test, so what is checked here is
 * the orientation transform and the space reserved before pixels arrive.
 * Cache ownership and downloads are covered by the shared media pipeline tests.
 */
class MediaCacheAndOrientationTest {
    private val mediaId = "9f1c7c0a4b6e4f2d8a3b5c7d9e0f1a2b"

    // -- orientation ------------------------------------------------------

    /**
     * The client's reading of an orientation must agree with Core's.
     *
     * Core applies the value to the stored size to get the `width`/`height` it
     * publishes; this does the same arithmetic to the decoded original. When
     * they disagree, the picture faces one way and the space reserved for it
     * faces the other.
     */
    @Test
    fun displayedSizeMatchesWhatCoreWouldHavePublished() {
        // A landscape file that displays portrait: Core's own fixtures for the
        // EXIF JPEG, the PNG with a trailing eXIf chunk, and the XMP-only JPEG
        // all report orientation 6 over a 400x200 source.
        assertEquals(200 to 400, MediaOrientation.displayedSize(400, 200, 6))
        assertEquals(200 to 400, MediaOrientation.displayedSize(400, 200, 8))
        assertEquals(200 to 400, MediaOrientation.displayedSize(400, 200, 5))
        assertEquals(200 to 400, MediaOrientation.displayedSize(400, 200, 7))
        // The four that do not exchange the axes.
        for (upright in listOf(1, 2, 3, 4)) {
            assertEquals("orientation $upright", 400 to 200, MediaOrientation.displayedSize(400, 200, upright))
        }
    }

    @Test
    fun everyOrientationMeansExactlyOneRotationAndMirror() {
        assertTrue(MediaOrientation.transformFor(1).isIdentity)
        assertEquals(0 to true, MediaOrientation.transformFor(2).let { it.rotationDegrees to it.mirrored })
        assertEquals(180 to false, MediaOrientation.transformFor(3).let { it.rotationDegrees to it.mirrored })
        assertEquals(180 to true, MediaOrientation.transformFor(4).let { it.rotationDegrees to it.mirrored })
        assertEquals(90 to true, MediaOrientation.transformFor(5).let { it.rotationDegrees to it.mirrored })
        assertEquals(90 to false, MediaOrientation.transformFor(6).let { it.rotationDegrees to it.mirrored })
        assertEquals(270 to true, MediaOrientation.transformFor(7).let { it.rotationDegrees to it.mirrored })
        assertEquals(270 to false, MediaOrientation.transformFor(8).let { it.rotationDegrees to it.mirrored })
    }

    /**
     * An unreadable orientation is upright, not a guess.
     *
     * Core answers 1 when it cannot read one, and a build meeting an older Core
     * with no `orientation` field at all reads the same 1. Both mean "apply
     * nothing", which is exactly what those pictures were always served as.
     */
    @Test
    fun anOrientationThisBuildCannotActOnMeansNoTransform() {
        for (value in listOf(0, -1, 9, 99)) {
            assertTrue("orientation $value", MediaOrientation.transformFor(value).isIdentity)
        }
    }

    @Test
    fun anOlderCoreWithoutTheFieldReadsAsUpright() {
        val withoutOrientation = """
            {"version":1,"mediaId":"$mediaId","mimeType":"image/png","width":10,"height":20,
             "sizeBytes":99,"sha256":"${"a".repeat(64)}",
             "createdAt":"2026-09-15T12:00:00+00:00",
             "downloadPath":"/v1/media/$mediaId",
             "thumbnail":{"mimeType":"image/jpeg","width":5,"height":10,"sizeBytes":9,
                          "downloadPath":"/v1/media/$mediaId/thumbnail"}}
        """.trimIndent()

        val parsed = CoreMediaRef.parse(org.json.JSONObject(withoutOrientation))

        assertNotNull(parsed)
        assertEquals(CoreMediaRef.UPRIGHT, parsed!!.orientation)
    }

    /** The thumbnail is generated upright; applying the value to it is the double rotation. */
    @Test
    fun theOrientationBelongsToTheOriginalOnly() {
        val media = CoreMediaRef(
            mediaId = mediaId,
            mimeType = "image/jpeg",
            widthPx = 200,
            heightPx = 400,
            sizeBytes = 1000,
            sha256 = "a".repeat(64),
            orientation = 6,
            thumbnail = CoreMediaThumbnail("image/jpeg", 512, 1024, 900),
        )

        // The thumbnail's own size is already the displayed shape: portrait,
        // like the metadata, with no transform left to apply.
        assertTrue(media.thumbnail.heightPx > media.thumbnail.widthPx)
        assertEquals(
            media.widthPx.toDouble() / media.heightPx,
            media.thumbnail.widthPx.toDouble() / media.thumbnail.heightPx,
            0.01,
        )
    }

    // -- reserved layout space -------------------------------------------

    @Test
    fun aRowReservesThePicturesOwnShapeAndCapsALongOne() {
        val portrait = CoreMediaRef(
            mediaId = mediaId,
            mimeType = "image/png",
            widthPx = 1200,
            heightPx = 1800,
            sizeBytes = 1,
            sha256 = "a".repeat(64),
            orientation = 1,
            thumbnail = CoreMediaThumbnail("image/jpeg", 683, 1024, 1),
        )
        val veryLong = portrait.copy(widthPx = 1000, heightPx = 20_000)

        // 3:2 tall at 600px wide is 900px tall, which is the shape the decoded
        // picture will be — so nothing moves when it lands.
        assertEquals(
            900,
            MessageLayoutPrecomputer.imageBoxHeight(portrait, widthPx = 600, fallbackPx = 240, maxPx = 1200),
        )
        // A full-page screenshot is clamped instead of handing one message the
        // whole screen.
        assertEquals(
            1200,
            MessageLayoutPrecomputer.imageBoxHeight(veryLong, widthPx = 600, fallbackPx = 240, maxPx = 1200),
        )
        // No reference (a gallery picture, a markdown image): the old fixed box.
        assertEquals(
            240,
            MessageLayoutPrecomputer.imageBoxHeight(null, widthPx = 600, fallbackPx = 240, maxPx = 1200),
        )
    }

    @Test
    fun localDimensionsReserveTheImageShapeBeforeAnyDecode() {
        val landscape = surf.comma.android.chat.model.ImageDimensions(960, 540)
        val portrait = surf.comma.android.chat.model.ImageDimensions(256, 1024)
        assertEquals(225, MessageLayoutPrecomputer.imageBoxHeight(
            null, widthPx = 400, fallbackPx = 240, maxPx = 1200, dimensions = landscape,
        ))
        assertEquals(1200, MessageLayoutPrecomputer.imageBoxHeight(
            null, widthPx = 400, fallbackPx = 240, maxPx = 1200, dimensions = portrait,
        ))
    }

    @Test
    fun aReferenceWithNonsenseDimensionsFallsBackRatherThanCollapsing() {
        val broken = CoreMediaRef(
            mediaId = mediaId,
            mimeType = "image/png",
            widthPx = 0,
            heightPx = 0,
            sizeBytes = 1,
            sha256 = "a".repeat(64),
            orientation = 1,
            thumbnail = CoreMediaThumbnail("image/jpeg", 1, 1, 1),
        )

        assertEquals(
            240,
            MessageLayoutPrecomputer.imageBoxHeight(broken, widthPx = 600, fallbackPx = 240, maxPx = 1200),
        )
    }

    @Test
    fun aStoredReferenceRoundTripsThroughTheDatabaseBody() {
        val media = CoreMediaRef(
            mediaId = mediaId,
            mimeType = "image/webp",
            widthPx = 640,
            heightPx = 480,
            sizeBytes = 4096,
            sha256 = "c".repeat(64),
            orientation = 8,
            thumbnail = CoreMediaThumbnail("image/png", 320, 240, 512),
        )

        val restored = CoreMediaRef.fromJson(media.toJson())

        assertEquals(media, restored)
        assertNull("a body that is not a reference must not become one", CoreMediaRef.fromJson("{}"))
        assertNull(CoreMediaRef.fromJson(null))
        assertNull(CoreMediaRef.fromJson("not json"))
    }

    @Test
    fun aStoredBodyIsStillValidatedWhenItIsReadBack() {
        // Bytes in the database are not more trustworthy than bytes on the wire
        // — an older build, or a hand-edited row, must not come back as a
        // reference this build would act on.
        val tampered = """{"mediaId":"nope","mimeType":"image/png","width":1,"height":1,
            "sizeBytes":1,"sha256":"${"a".repeat(64)}","orientation":1,
            "thumbnail":{"mimeType":"image/jpeg","width":1,"height":1,"sizeBytes":1}}"""

        assertNull(CoreMediaRef.fromJson(tampered))
    }

    @Test
    fun theStoredBodyNeverCarriesACredentialOrAPath() {
        val json = CoreMediaRef(
            mediaId = mediaId,
            mimeType = "image/png",
            widthPx = 1,
            heightPx = 1,
            sizeBytes = 1,
            sha256 = "a".repeat(64),
            orientation = 1,
            thumbnail = CoreMediaThumbnail("image/jpeg", 1, 1, 1),
        ).toJson()

        assertFalse(json.contains("Bearer"))
        assertFalse(json.contains("token"))
        assertFalse(json.contains("downloadPath"))
    }
}
