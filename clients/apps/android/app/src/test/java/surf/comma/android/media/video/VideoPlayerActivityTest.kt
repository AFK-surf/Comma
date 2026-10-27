package surf.comma.android.media.video

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import surf.comma.android.core.CoreGraph
import java.io.File

/** The page plays what the client core downloaded and closes at once on any other file. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class VideoPlayerActivityTest {
    private val context = RuntimeEnvironment.getApplication()

    @Test fun playsTheCoreDownloadsAndNothingElse() {
        val download = File(CoreGraph.downloads(context), "account/key/clip.mp4").apply { parentFile!!.mkdirs(); writeBytes(ByteArray(16)) }
        assertFalse("a core download plays", closes(download))
        val outside = File(context.filesDir, "clip.mp4").apply { writeBytes(ByteArray(16)) }
        assertTrue(closes(outside))
        File(context.noBackupFilesDir, "credentials.bin").writeBytes(ByteArray(16))
        assertTrue("a path that climbs out of the downloads", closes(File(CoreGraph.downloads(context), "../credentials.bin")))
    }

    private fun closes(file: File): Boolean =
        Robolectric.buildActivity(VideoPlayerActivity::class.java, VideoPlayerActivity.intent(context, file, sessionBound = false))
            .use { it.create().get().isFinishing }
}
