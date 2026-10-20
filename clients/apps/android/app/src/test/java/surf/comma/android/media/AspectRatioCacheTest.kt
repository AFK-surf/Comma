package surf.comma.android.media

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class AspectRatioCacheTest {
    @Test fun ratiosPersistAndEvictLeastRecentlyUsedWithinBound() = runBlocking {
        val root = Files.createTempDirectory("ratio-test").toFile()
        try {
            val file = root.resolve("ratios.json")
            val cache = AspectRatioCache.open(file, 2)
            val a = mediaDigest("a"); val b = mediaDigest("b"); val c = mediaDigest("c")
            cache.put(a, ImageDimensions(100, 50))
            cache.put(b, ImageDimensions(50, 100))
            assertNotNull(cache.get(a))
            cache.put(c, ImageDimensions(90, 30))
            assertNull(cache.get(b))
            val reopened = AspectRatioCache.open(file, 2)
            assertEquals(ImageDimensions(100, 50), reopened.get(a))
            assertEquals(ImageDimensions(90, 30), reopened.get(c))
            reopened.clear()
            assertNull(AspectRatioCache.open(file, 2).get(a))
        } finally { root.deleteRecursively() }
    }

    @Test fun unknownFirstBindingKeepsHeightAndNextBindingUsesLearnedRatio() = runBlocking {
        val cache = AspectRatioCache.memory()
        val key = mediaDigest("blob")
        val first = ImagePlaceholder.reserve(320, cache.get(key))
        cache.put(key, ImageDimensions(1600, 900))
        assertEquals(320, first.height)
        assertEquals(180, ImagePlaceholder.reserve(320, cache.get(key)).height)
    }
}
