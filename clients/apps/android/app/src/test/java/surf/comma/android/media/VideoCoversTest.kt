package surf.comma.android.media

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class VideoCoversTest {
    @get:Rule val folder = TemporaryFolder()
    private val key = "c".repeat(64)

    private class CountingReader(private val size: ImageDimensions?) : VideoFrameReader {
        var calls = 0
        var maxEdge = 0
        override fun write(video: File, maxEdge: Int, output: File): ImageDimensions? {
            calls++
            this.maxEdge = maxEdge
            if (size != null) output.writeText("jpeg")
            return size
        }
    }

    private fun video(): File = File(folder.root, "files/$key/data/clip.mp4").apply { parentFile!!.mkdirs(); writeText("mp4") }

    @Test fun firstFrameIsExtractedOnceAndItsSizeRememberedAcrossProcesses() = runBlocking {
        val sizes = File(folder.root, "sizes.json")
        val reader = CountingReader(ImageDimensions(720, 1280))
        val covers = VideoCovers(AspectRatioCache.open(sizes), reader)
        assertNull(covers.dimensions(key))
        val video = video()
        val cover = covers.cover(key, video)!!
        assertEquals(ImageDimensions(720, 1280), cover.dimensions)
        assertEquals(File(folder.root, "files/$key/cover.jpg"), cover.file)
        assertEquals("jpeg", cover.file.readText())
        assertEquals(1280, reader.maxEdge)
        assertEquals(ImageDimensions(720, 1280), covers.dimensions(key))
        assertEquals(cover, covers.cover(key, video))
        assertEquals(1, reader.calls)

        // The next process knows the size before anything is downloaded again.
        val reopened = VideoCovers(AspectRatioCache.open(sizes), reader)
        assertEquals(ImageDimensions(720, 1280), reopened.dimensions(key))
        assertEquals(cover, reopened.cover(key, video))
        assertEquals(1, reader.calls)
        assertTrue(ImagePlaceholder.reserve(360, reopened.dimensions(key), 16.0 / 9).height == 640)
    }

    @Test fun aLostCoverIsExtractedAgainAndAnUnreadableVideoHasNone() = runBlocking {
        val reader = CountingReader(ImageDimensions(1920, 1080))
        val covers = VideoCovers(AspectRatioCache.memory(), reader)
        val video = video()
        covers.cover(key, video)!!.file.delete()
        assertEquals(ImageDimensions(1920, 1080), covers.cover(key, video)!!.dimensions)
        assertEquals(2, reader.calls)

        val broken = VideoCovers(AspectRatioCache.memory(), CountingReader(null))
        val other = "d".repeat(64)
        assertNull(broken.cover(other, File(folder.root, "files/$other/data/x.mp4").apply { parentFile!!.mkdirs(); writeText("x") }))
        assertNull(broken.dimensions(other))
        assertTrue(File(folder.root, "files/$other").listFiles()!!.none { it.name.startsWith("cover") })
    }

    @Test fun clearingForgetsSizes() = runBlocking {
        val covers = VideoCovers(AspectRatioCache.memory(), CountingReader(ImageDimensions(4, 3)))
        covers.cover(key, video())
        covers.clear()
        assertNull(covers.dimensions(key))
    }
}
