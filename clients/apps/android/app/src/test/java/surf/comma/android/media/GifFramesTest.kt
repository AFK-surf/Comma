package surf.comma.android.media

import org.junit.Assert.assertEquals
import org.junit.Test

class GifFramesTest {
    @Test fun eachFrameComesWholeWithItsDelay() {
        val gif = GifFrames(GifFixtures.threeColours)
        assertEquals(40 to 40, gif.width to gif.height)
        val seen = mutableListOf<Pair<Set<Int>, Int>>()
        gif.forEach(limit = 10) { pixels, delay -> seen += pixels.toSet() to delay }
        assertEquals(
            listOf(setOf(0xFFFF0000.toInt()) to 100, setOf(0xFF0000FF.toInt()) to 200, setOf(0xFF00FF00.toInt()) to 300),
            seen,
        )
    }

    @Test fun readsNoMoreThanTheLimit() {
        var frames = 0
        GifFrames(GifFixtures.threeColours).forEach(limit = 2) { _, _ -> frames++ }
        assertEquals(2, frames)
    }
}
