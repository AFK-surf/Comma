package surf.comma.android.media.file

import android.content.Intent
import android.content.pm.PackageManager
import androidx.activity.ComponentActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import surf.comma.android.core.CoreGraph
import surf.comma.android.media.MediaAttachment
import java.io.File
import java.io.FileNotFoundException

/** Uses the merged manifest, so a provider the manifest does not register fails here, not on a device. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MediaFileProviderTest {
    @Test fun theCoreDownloadsOpenReadOnlyInAnotherAppAndNothingElseDoes() = Robolectric.buildActivity(ComponentActivity::class.java).use {
        val context = it.setup().get()
        val info = context.packageManager.resolveContentProvider(MediaFileProvider.authority(context), PackageManager.GET_META_DATA)
        assertNotNull("provider registered", info)
        assertFalse(info!!.exported)
        assertTrue(info.grantUriPermissions)

        val file = File(CoreGraph.downloads(context), "account/key/report.pdf").apply { parentFile!!.mkdirs(); writeText("%PDF") }
        assertTrue("a core download opens", FileCardView.open(context, file, MediaAttachment("report.pdf", "application/pdf", 4, null)))
        val opened = shadowOf(context).nextStartedActivity
        val uri = opened.data!!
        assertEquals("content", uri.scheme)
        assertEquals(MediaFileProvider.authority(context), uri.authority)
        assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION, opened.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
        assertEquals("%PDF", context.contentResolver.openInputStream(uri)!!.use { stream -> stream.reader().readText() })

        val outside = File(context.filesDir, "secret.txt").apply { writeText("x") }
        // The card turns the refusal into a message instead of a crash.
        assertFalse(FileCardView.open(context, outside, MediaAttachment("secret.txt", "text/plain", 1, null)))
        File(context.noBackupFilesDir, "credentials.bin").writeText("x")
        val climbing = uri.buildUpon().path(null).appendPath(uri.pathSegments.first()).appendPath("../credentials.bin").build()
        assertTrue(runCatching { context.contentResolver.openInputStream(climbing) }.exceptionOrNull() is FileNotFoundException)
    }
}
