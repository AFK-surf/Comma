package surf.comma.android.media

import android.net.Uri
import android.os.Bundle
import android.os.Parcel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ViewerImageBundlesTest {
    private fun roundTrip(image: ViewerImage): ViewerImage? {
        val parcel = Parcel.obtain()
        try {
            parcel.writeBundle(ViewerImageBundles.write(image))
            parcel.setDataPosition(0)
            return ViewerImageBundles.read(parcel.readBundle(javaClass.classLoader)!!)
        } finally {
            parcel.recycle()
        }
    }

    @Test fun everySourceSurvivesTheIntent() {
        val ref = MediaBlobRef("a".repeat(32), "b".repeat(64), 1234)
        val images = listOf(
            ViewerImage.Remote(MediaImage(MediaSource.AgentResource("agent", ref), "a.png", "image/png", ImageDimensions(4, 3))),
            ViewerImage.Remote(MediaImage(MediaSource.MessageAttachment("c", "m", 5, ref), "b.gif", null)),
            ViewerImage.Remote(MediaImage(MediaSource.UploadedFile(UPLOAD_PATH), null, "image/jpeg")),
            ViewerImage.Local(Uri.parse("content://picker/7"), "image/webp", "c.webp", ImageDimensions(10, 20)),
        )
        images.forEach { assertEquals(it, roundTrip(it)) }
    }

    @Test fun carriesNoUrlOrCredentialAndRejectsTamperedValues() {
        val ref = MediaBlobRef("a".repeat(32), "b".repeat(64), 1234)
        val bundle = ViewerImageBundles.write(ViewerImage.Remote(MediaImage(MediaSource.AgentResource("agent", ref), "a.png", "image/png")))
        assertFalse(bundle.keySet().any { it.contains("url") || it.contains("token") || it.contains("auth") })
        bundle.putString("ref_hash", "not-a-hash")
        assertNull(ViewerImageBundles.read(bundle))
        assertNull(ViewerImageBundles.read(Bundle().apply { putString("kind", "remote"); putString("source", "upload"); putString("path", "/etc/passwd") }))
        assertNull(ViewerImageBundles.read(Bundle()))
    }
}
