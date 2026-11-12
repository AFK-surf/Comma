package surf.comma.android.media

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

class VideoCoversTest {
    @get:Rule val folder = TemporaryFolder()
    private val cache get() = File(folder.root, "video-covers")
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

    private fun video(): File = File(folder.root, "downloads/account/$key/clip.mp4").apply { parentFile!!.mkdirs(); writeText("mp4") }

    @Test fun firstFrameIsExtractedOnceAndItsSizeRememberedAcrossProcesses() = runBlocking {
        val sizes = File(folder.root, "sizes.json")
        val reader = CountingReader(ImageDimensions(720, 1280))
        val covers = VideoCovers(AspectRatioCache.open(sizes), cache, reader)
        assertNull(covers.dimensions(key))
        val video = video()
        val cover = covers.cover(key, video)!!
        assertEquals(ImageDimensions(720, 1280), cover.dimensions)
        assertEquals(File(folder.root, "video-covers/$key.jpg"), cover.file)
        assertEquals("jpeg", cover.file.readText())
        assertEquals(1280, reader.maxEdge)
        assertEquals(ImageDimensions(720, 1280), covers.dimensions(key))
        assertEquals(cover, covers.cover(key, video))
        assertEquals(1, reader.calls)

        // The next process knows the size before anything is downloaded again.
        val reopened = VideoCovers(AspectRatioCache.open(sizes), cache, reader)
        assertEquals(ImageDimensions(720, 1280), reopened.dimensions(key))
        assertEquals(cover, reopened.cover(key, video))
        assertEquals(1, reader.calls)
        assertTrue(ImagePlaceholder.reserve(360, reopened.dimensions(key), 16.0 / 9).height == 640)
    }

    @Test fun aLostCoverIsExtractedAgainAndAnUnreadableVideoHasNone() = runBlocking {
        val reader = CountingReader(ImageDimensions(1920, 1080))
        val covers = VideoCovers(AspectRatioCache.memory(), cache, reader)
        val video = video()
        covers.cover(key, video)!!.file.delete()
        assertEquals(ImageDimensions(1920, 1080), covers.cover(key, video)!!.dimensions)
        assertEquals(2, reader.calls)

        val broken = VideoCovers(AspectRatioCache.memory(), cache, CountingReader(null))
        val other = "d".repeat(64)
        assertNull(broken.cover(other, File(folder.root, "files/$other/data/x.mp4").apply { parentFile!!.mkdirs(); writeText("x") }))
        assertNull(broken.dimensions(other))
        assertTrue(File(folder.root, "files/$other").listFiles()!!.none { it.name.startsWith("cover") })
    }

    @Test fun differentVideosKeepTheirOwnFramesAcrossCacheHits() = runBlocking {
        val first = video().apply { writeText("first frame") }
        val secondKey = "d".repeat(64)
        val second = File(first.parentFile!!.parentFile, "$secondKey/other.mp4").apply {
            parentFile!!.mkdirs()
            writeText("second frame")
        }
        val shared = File(first.parentFile!!.parentFile, "cover.jpg").apply { writeText("old shared frame") }
        val sizes = AspectRatioCache.memory().apply {
            put(key, ImageDimensions(4, 3))
            put(secondKey, ImageDimensions(4, 3))
        }
        val covers = VideoCovers(sizes, cache, VideoFrameReader { video, _, output ->
            output.writeText(video.readText())
            ImageDimensions(4, 3)
        })
        val firstCover = covers.cover(key, first)!!
        val secondCover = covers.cover(secondKey, second)!!
        assertTrue(firstCover.file != secondCover.file)
        assertEquals("first frame", covers.cover(key, first)!!.file.readText())
        assertEquals("second frame", covers.cover(secondKey, second)!!.file.readText())
        assertTrue(!shared.exists())
        assertEquals(listOf(first), first.parentFile!!.listFiles()!!.toList())
        assertEquals(listOf(second), second.parentFile!!.listFiles()!!.toList())
    }

    @Test fun cachedCoverDoesNotWaitForAnotherVideosExtraction() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CountDownLatch(1)
        val cachedVideo = video()
        val other = File(cachedVideo.parentFile!!.parentFile, "other/other.mp4").apply {
            parentFile!!.mkdirs()
            writeText("other frame")
        }
        val covers = VideoCovers(AspectRatioCache.memory(), cache, VideoFrameReader { video, _, output ->
            if (video == other) {
                entered.complete(Unit)
                release.await()
            }
            output.writeText(video.readText())
            ImageDimensions(4, 3)
        }, dispatcher = Dispatchers.Unconfined)
        val expected = covers.cover(key, cachedVideo)
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { worker ->
            val extracting = async(worker) { covers.cover("other", other) }
            try {
                entered.await()
                val hit = async(start = CoroutineStart.UNDISPATCHED) { covers.cover(key, cachedVideo) }
                assertTrue("a cache hit completes while the other decoder is still blocked", hit.isCompleted)
                assertEquals(expected, hit.await())
            } finally {
                release.countDown()
                extracting.await()
            }
        }
    }

    @Test fun clearingForgetsSizes() = runBlocking {
        val covers = VideoCovers(AspectRatioCache.memory(), cache, CountingReader(ImageDimensions(4, 3)))
        val file = covers.cover(key, video())!!.file
        covers.clear()
        assertTrue(!file.exists())
        assertNull(covers.dimensions(key))
    }
}
