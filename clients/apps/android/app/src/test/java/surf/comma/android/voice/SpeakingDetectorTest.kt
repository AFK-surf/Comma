package surf.comma.android.voice

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SpeakingDetectorTest {
    private val detector = SpeakingDetector(windowMillis = 300)

    @Test
    fun silentUntilTheHardwarePlaysSomething() {
        assertFalse(detector.sample(epoch = 0, played = 0, nowMillis = 0))
        assertFalse(detector.sample(epoch = 0, played = 0, nowMillis = 1_000))
    }

    @Test
    fun speakingWhilePlayedFramesAdvanceAndForThreeHundredMillisAfter() {
        assertTrue(detector.sample(0, 2_400, 100))
        assertTrue(detector.sample(0, 4_800, 200))
        assertTrue(detector.sample(0, 4_800, 500))
        assertFalse(detector.sample(0, 4_800, 501))
    }

    @Test
    fun resumesAsSoonAsPlaybackAdvancesAgain() {
        detector.sample(0, 2_400, 0)
        assertFalse(detector.sample(0, 2_400, 1_000))
        assertTrue(detector.sample(0, 2_500, 1_100))
    }

    @Test
    fun aFlushRestartsTheCountWithoutReadingTheResetAsSpeech() {
        detector.sample(0, 48_000, 0)
        // Interrupted: the player cleared, a new epoch starts at zero.
        assertTrue(detector.sample(1, 0, 100)) // still within the window of the last real advance
        assertFalse(detector.sample(1, 0, 400))
        assertTrue(detector.sample(1, 1_200, 500))
    }

    @Test
    fun aNewEpochThatAlreadyPlayedCountsAsAdvance() {
        detector.sample(0, 9_600, 0)
        assertFalse(detector.sample(0, 9_600, 1_000))
        assertTrue(detector.sample(1, 480, 1_100))
    }
}
