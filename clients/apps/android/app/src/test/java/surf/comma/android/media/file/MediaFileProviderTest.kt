package surf.comma.android.media.file

import android.content.pm.PackageManager
import androidx.core.content.FileProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import surf.comma.android.media.MediaAttachment
import java.io.File

/** Uses the merged manifest, so a missing FILE_PROVIDER_PATHS entry fails here, not on a device. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MediaFileProviderTest {
    private val context = RuntimeEnvironment.getApplication()

    @Test fun downloadsInTheMediaCacheGetAContentUriAndNothingElseDoes() {
        val info = context.packageManager.resolveContentProvider(MediaFileProvider.authority(context), PackageManager.GET_META_DATA)
        assertNotNull("provider registered", info)
        assertFalse(info!!.exported)
        assertTrue(info.grantUriPermissions)
        val file = File(context.cacheDir, "media-accounts/abc/files/key/data/report.pdf").apply { parentFile!!.mkdirs(); writeText("%PDF") }
        val uri = FileProvider.getUriForFile(context, MediaFileProvider.authority(context), file)
        assertEquals("content", uri.scheme)
        assertEquals(MediaFileProvider.authority(context), uri.authority)
        assertTrue(uri.path!!.endsWith("/report.pdf"))
        val outside = File(context.filesDir, "secret.txt").apply { writeText("x") }
        assertTrue(runCatching { FileProvider.getUriForFile(context, MediaFileProvider.authority(context), outside) }.isFailure)
        // The card turns that refusal into a message instead of a crash.
        assertFalse(FileCardView.open(context, outside, MediaAttachment("secret.txt", "text/plain", 1, null)))
    }
}
