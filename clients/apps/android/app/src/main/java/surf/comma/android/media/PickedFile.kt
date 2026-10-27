package surf.comma.android.media

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import surf.comma.android.ui.Background
import surf.comma.android.core.HostLocalFile
import surf.comma.android.core.HostLocalFiles
import java.io.File
import java.io.IOException
import java.security.SecureRandom
import java.util.Base64

/**
 * A file the user picked, as its provider describes it: [name] (with an extension, which the server and other apps
 * read its type by), its declared type, and its size when the provider knows it.
 */
data class PickedFile(val name: String, val mimeType: String?, val size: Long?) {
    val kind: FileKind get() = FileKinds.kind(name, mimeType)

    /** Images are made ready on the device ([ImagePreprocessor]); every other file is sent as it is. */
    val isImage: Boolean get() = kind == FileKind.IMAGE

    /** Over the upload limit, which only a file sent as it is can be: an image is made smaller to fit. */
    val tooLarge: Boolean get() = !isImage && (size ?: 0) > MediaLimits.MAX_FILE_UPLOAD_BYTES

    companion object {
        /** What [resolver] says of [uri]; what it leaves out comes from the URI itself. */
        fun describe(resolver: ContentResolver, uri: Uri): PickedFile {
            var name: String? = null
            var size: Long? = null
            try {
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
                    if (it.moveToFirst()) {
                        it.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { i -> i >= 0 && !it.isNull(i) }
                            ?.let { i -> name = it.getString(i) }
                        it.getColumnIndex(OpenableColumns.SIZE).takeIf { i -> i >= 0 && !it.isNull(i) }
                            ?.let { i -> size = it.getLong(i) }
                    }
                }
            } catch (_: RuntimeException) {
                // A provider that cannot answer: the URI's own name, and no size.
            }
            if (size == null && uri.scheme == ContentResolver.SCHEME_FILE) {
                size = uri.path?.let(::File)?.takeIf { it.isFile }?.length()
            }
            val mime = try { resolver.getType(uri) } catch (_: RuntimeException) { null }
                ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(extensionOf(name ?: uri.lastPathSegment))
            return PickedFile(withExtension(FileKinds.safeFileName(name ?: uri.lastPathSegment), mime), mime, size)
        }

        /** [name], given the extension of [mime] when it has none. */
        private fun withExtension(name: String, mime: String?): String {
            if (extensionOf(name).isNotEmpty()) return name
            val extension = mime?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) } ?: return name
            return "$name.$extension"
        }

        private fun extensionOf(name: String?): String = name.orEmpty().substringAfterLast('/').substringAfterLast('.', "")
    }
}

/**
 * Gives a picked file that is sent as it is to the core by a ref ([PickedLocalFiles]), which the app's host then
 * uploads from where it is (`localFileRef`), and says its size, measured when the provider gave none.
 */
fun interface PickedFileRefs {
    suspend fun register(uri: Uri, size: Long?): PickedFileRef
}

data class PickedFileRef(val ref: String, val size: Long)

class AndroidPickedFileRefs(
    private val resolver: ContentResolver,
    private val files: PickedLocalFiles = PickedLocalFiles,
    private val dispatcher: CoroutineDispatcher = Background.files,
) : PickedFileRefs {
    override suspend fun register(uri: Uri, size: Long?): PickedFileRef = withContext(dispatcher) {
        val measured = size ?: measure(uri)
        PickedFileRef(files.register(uri, measured), measured)
    }

    /** The file's length as its descriptor says, else as many bytes as it reads. */
    private suspend fun measure(uri: Uri): Long {
        try {
            resolver.openAssetFileDescriptor(uri, "r")?.use { if (it.length >= 0) return it.length }
        } catch (_: Exception) {
            // Read it through instead.
        }
        (resolver.openInputStream(uri) ?: throw IOException("Cannot read file")).use { input ->
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                currentCoroutineContext().ensureActive()
                val count = input.read(buffer)
                if (count < 0) return total
                total += count
            }
        }
    }
}

/**
 * The files picked in this process that the core has the app upload from where they are, by the ref it names them
 * with (`lfi1_…`, as Electron's picks). A ref names its file for the process's life, so a failed upload can be tried
 * again; only the latest few hundred are kept.
 */
object PickedLocalFiles {
    private class Entry(val uri: Uri, val size: Long)

    private val entries = object : LinkedHashMap<String, Entry>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Entry>?) = size > KEPT
    }
    private val random = SecureRandom()

    /** A new ref for [uri], whose length is [size]. */
    fun register(uri: Uri, size: Long): String {
        val bytes = ByteArray(32).also(random::nextBytes)
        val ref = "lfi1_" + Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        synchronized(entries) { entries[ref] = Entry(uri, size) }
        return ref
    }

    /** The core's host reading the files: each [HostLocalFile.open] opens the picked file anew. */
    fun host(resolver: ContentResolver): HostLocalFiles = HostLocalFiles { ref ->
        synchronized(entries) { entries[ref] }?.let { entry ->
            HostLocalFile(entry.size) { resolver.openInputStream(entry.uri) ?: throw IOException("Cannot read file") }
        }
    }

    private const val KEPT = 256
}
