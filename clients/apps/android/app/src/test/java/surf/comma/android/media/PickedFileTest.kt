package surf.comma.android.media

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.provider.OpenableColumns
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class PickedFileTest {
    private val uri = Uri.parse("content://media/picker/0/provider/media/185")
    private fun describe(name: String?, fail: Boolean = false): PickedFile {
        ShadowContentResolver.registerProviderInternal("media", object : ContentProvider() {
            override fun onCreate() = true
            override fun getType(uri: Uri) = "video/mp4"
            override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, order: String?): Cursor {
                if (fail) throw IllegalArgumentException("Unsupported projection")
                return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)).apply { addRow(arrayOf<Any?>(name, 123L)) }
            }
            override fun insert(uri: Uri, values: ContentValues?): Uri? = null
            override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = 0
            override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = 0
        })
        return PickedFile.describe(RuntimeEnvironment.getApplication().contentResolver, uri)
    }

    @Test fun `the original provider name and size are preserved`() {
        assertEquals(PickedFile("clip5s.mp4", "video/mp4", 123), describe("clip5s.mp4"))
    }

    @Test fun `picker synthesized media ids become readable video names`() {
        val file = describe("185.mp4")
        assertEquals("video.mp4", file.name)
        assertEquals(123L, file.size)
    }

    @Test fun `missing metadata and failed queries do not expose opaque uri ids`() {
        for (file in listOf(describe(null), describe(null, fail = true))) {
            assertEquals("video.mp4", file.name)
            assertEquals("video/mp4", file.mimeType)
        }
    }

    @Test fun `a name already in the draft is numbered`() {
        assertEquals("video.mp4", PickedFile.distinctName("video.mp4", setOf("photo.jpg")))
        assertEquals("video-2.mp4", PickedFile.distinctName("video.mp4", setOf("video.mp4")))
        assertEquals("video-3.mp4", PickedFile.distinctName("video.mp4", setOf("video.mp4", "video-2.mp4")))
        assertEquals("notes-2", PickedFile.distinctName("notes", setOf("notes")))
    }
}
