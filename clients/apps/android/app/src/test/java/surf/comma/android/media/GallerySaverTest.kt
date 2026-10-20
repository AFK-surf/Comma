package surf.comma.android.media

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File
import java.io.IOException

/** MediaStore stands in as a provider that records what the saver asked of it. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class GallerySaverTest {
    class FakeMediaStore : ContentProvider() {
        val rows = linkedMapOf<Uri, ContentValues>()
        val files = mutableMapOf<Uri, File>()
        val deleted = mutableListOf<Uri>()
        var insertedInto: Uri? = null
        var pendingAtInsert: Int? = null
        override fun onCreate() = true
        override fun insert(uri: Uri, values: ContentValues?): Uri {
            insertedInto = uri
            pendingAtInsert = values?.getAsInteger(MediaStore.MediaColumns.IS_PENDING)
            val item = Uri.withAppendedPath(uri, (rows.size + 1).toString())
            rows[item] = ContentValues(values)
            files[item] = File.createTempFile("gallery", ".bin")
            return item
        }
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor =
            ParcelFileDescriptor.open(files.getValue(uri), ParcelFileDescriptor.parseMode(mode))
        override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?): Int {
            rows.getValue(uri).putAll(values)
            return 1
        }
        override fun delete(uri: Uri, selection: String?, args: Array<out String>?): Int {
            deleted += uri
            rows.remove(uri)
            return 1
        }
        override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
        override fun getType(uri: Uri): String? = null
    }

    private lateinit var store: FakeMediaStore
    private val saver get() = GallerySaver(RuntimeEnvironment.getApplication().contentResolver, Dispatchers.Unconfined)

    @Before fun setUp() {
        store = Robolectric.setupContentProvider(FakeMediaStore::class.java, MediaStore.AUTHORITY)
    }

    @Test fun writesPendingIntoPicturesThenPublishesTheOriginalBytes() = runBlocking {
        val bytes = ByteArray(5000) { it.toByte() }
        val uri = saver.saveImage("holiday photo.JPG", "image/jpeg") { bytes.inputStream() }
        assertEquals(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), store.insertedInto)
        val row = store.rows.getValue(uri)
        assertEquals("holiday photo.jpg", row.getAsString(MediaStore.MediaColumns.DISPLAY_NAME))
        assertEquals("image/jpeg", row.getAsString(MediaStore.MediaColumns.MIME_TYPE))
        assertEquals("${Environment.DIRECTORY_PICTURES}/comma", row.getAsString(MediaStore.MediaColumns.RELATIVE_PATH))
        assertEquals("hidden from other apps while written", 1, store.pendingAtInsert)
        assertEquals(0, row.getAsInteger(MediaStore.MediaColumns.IS_PENDING))
        assertArrayEquals(bytes, store.files.getValue(uri).readBytes())
        assertTrue(store.deleted.isEmpty())
    }

    @Test fun aFailedWriteRemovesThePendingEntry() = runBlocking {
        val failure = runCatching { saver.saveImage("a.png", "image/png") { throw IOException("gone") } }.exceptionOrNull()
        assertTrue(failure is IOException)
        assertEquals(1, store.deleted.size)
        assertTrue(store.rows.isEmpty())
    }

    @Test fun onlyImagesAndNamesMatchTheBytes() = runBlocking {
        assertTrue(runCatching { saver.saveImage("a.txt", "text/plain") { ByteArray(1).inputStream() } }.isFailure)
        assertEquals("diagram.png", GallerySaver.displayName("diagram.jpg", "image/png"))
        assertEquals("image.webp", GallerySaver.displayName("", "image/webp"))
        assertEquals("image.gif", GallerySaver.displayName("../", "image/gif"))
        assertEquals("scan.jpg", GallerySaver.displayName("scan", "image/jpeg"))
    }
}
