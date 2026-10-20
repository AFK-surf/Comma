package surf.comma.android.media

import android.content.ContentResolver
import android.content.ContentValues
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import java.io.IOException
import java.io.InputStream
import surf.comma.android.ui.Background

/**
 * Saves into the shared Pictures collection through MediaStore. An app may add its own items
 * there without any storage permission (Android 10 and later), which covers every supported
 * version. The entry stays pending, invisible to other apps, until every byte is written, and a
 * failure removes it again.
 */
class GallerySaver(
    private val resolver: ContentResolver,
    private val dispatcher: CoroutineDispatcher = Background.files,
    private val album: String = "comma",
) {
    suspend fun saveImage(displayName: String, mime: String, open: () -> InputStream): Uri = withContext(dispatcher) {
        require(mime.startsWith("image/")) { "Not an image" }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName(displayName, mime))
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/$album")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val item = resolver.insert(collection, values) ?: throw IOException("Cannot create a gallery entry")
        try {
            (resolver.openOutputStream(item) ?: throw IOException("Cannot write the gallery entry")).use { output ->
                open().use { it.copyTo(output) }
            }
            val published = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            if (resolver.update(item, published, null, null) != 1) throw IOException("Cannot publish the gallery entry")
            item
        } catch (failure: Throwable) {
            runCatching { resolver.delete(item, null, null) }
            throw failure
        }
    }

    internal companion object {
        private val extensions = mapOf("image/jpeg" to "jpg", "image/png" to "png", "image/gif" to "gif", "image/webp" to "webp")

        /** The original name when it has one, with an extension that matches the bytes. */
        fun displayName(name: String, mime: String): String {
            val extension = extensions[mime] ?: "jpg"
            val safe = FileKinds.safeFileName(name).takeIf { it != "attachment" } ?: "image"
            val base = safe.substringBeforeLast('.', safe).ifBlank { "image" }
            return "$base.$extension"
        }
    }
}
