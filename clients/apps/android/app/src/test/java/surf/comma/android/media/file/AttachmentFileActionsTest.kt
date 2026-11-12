package surf.comma.android.media.file

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.activity.ComponentActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.core.CoreGraph
import surf.comma.android.media.MediaAttachment
import java.io.File

/** Uses the merged manifest, so the save activity must be registered for these to pass. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AttachmentFileActionsTest {
    private val attachment = MediaAttachment("report.pdf", "application/pdf", 4, null)

    @Test fun shareHandsTheDownloadToTheShareSheetReadOnly() = Robolectric.buildActivity(ComponentActivity::class.java).use {
        val context = it.setup().get()
        val file = download(context)
        AttachmentFileActions.share(context, file, attachment)
        val chooser = shadowOf(context).nextStartedActivity
        assertEquals(Intent.ACTION_CHOOSER, chooser.action)
        val send = chooser.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)!!
        assertEquals(Intent.ACTION_SEND, send.action)
        assertEquals("application/pdf", send.type)
        assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION, send.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val uri = send.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)!!
        assertEquals("%PDF", context.contentResolver.openInputStream(uri)!!.use { s -> s.reader().readText() })
    }

    @Test fun saveAsAsksWhereAndCopiesTheDownloadThere() = Robolectric.buildActivity(ComponentActivity::class.java).use {
        val context = it.setup().get()
        val file = download(context)
        AttachmentFileActions.saveAs(context, file, attachment)
        val started = shadowOf(context).nextStartedActivity
        assertEquals(SaveAttachmentActivity::class.java.name, started.component!!.className)

        Robolectric.buildActivity(SaveAttachmentActivity::class.java, started).use { save ->
            val activity = save.setup().get()
            val picker = shadowOf(activity).nextStartedActivityForResult
            assertEquals(Intent.ACTION_CREATE_DOCUMENT, picker.intent.action)
            assertEquals("application/pdf", picker.intent.type)
            assertEquals("report.pdf", picker.intent.getStringExtra(Intent.EXTRA_TITLE))

            val chosen = File(context.cacheDir, "chosen/report.pdf").apply { parentFile!!.mkdirs() }
            shadowOf(activity).receiveResult(picker.intent, Activity.RESULT_OK, Intent().setData(Uri.fromFile(chosen)))
            ShadowLooper.idleMainLooper()
            assertEquals("%PDF", chosen.readText())
            assertTrue(activity.isFinishing)
        }
    }

    @Test fun onlyTheCoreDownloadsCanBeSavedOrShared() = Robolectric.buildActivity(ComponentActivity::class.java).use {
        val context = it.setup().get()
        val outside = File(context.noBackupFilesDir, "credentials.bin").apply { writeText("x") }
        AttachmentFileActions.saveAs(context, outside, attachment)
        AttachmentFileActions.share(context, outside, attachment)
        assertNull(shadowOf(context).nextStartedActivity)
    }

    private fun download(context: android.content.Context) =
        File(CoreGraph.downloads(context), "account/key/report.pdf").apply { parentFile!!.mkdirs(); writeText("%PDF") }
}
