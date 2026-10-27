package surf.comma.android.media.file

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import surf.comma.android.BuildConfig
import surf.comma.android.core.CoreGraph
import surf.comma.android.media.FileKinds
import java.io.File
import java.io.FileNotFoundException

/**
 * Hands downloaded attachments, read-only, to the app a file is opened with, one granted URI per file. It serves only
 * the client core's downloads, which FileProvider's paths cannot name (they are in the no-backup directory), and in a
 * debug build the media demo's samples. The video player plays only what it serves ([serves]).
 */
class MediaFileProvider : ContentProvider() {
    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Files are handed out read-only.")
        return ParcelFileDescriptor.open(file(uri) ?: throw FileNotFoundException(uri.path), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?,
        sortOrder: String?): Cursor? {
        val file = file(uri) ?: return null
        val columns = projection?.filter { it in OPENABLE }?.toTypedArray() ?: OPENABLE
        return MatrixCursor(columns, 1).apply { addRow(columns.map { if (it == OpenableColumns.SIZE) file.length() else file.name }) }
    }

    override fun getType(uri: Uri): String? = file(uri)?.let { FileKinds.openType(it.name, null) }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()

    /** The file a URI names, once it is checked to be in the directory the URI starts with. */
    private fun file(uri: Uri): File? {
        val context = context ?: return null
        val segments = uri.pathSegments
        val root = roots(context)[segments.firstOrNull()] ?: return null
        val file = File(root, segments.drop(1).joinToString(File.separator)).canonicalFile
        return file.takeIf { it.isFile && locate(context, it)?.first == segments.first() }
    }

    companion object {
        private val OPENABLE = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)

        fun authority(context: Context) = "${context.packageName}.media.files"

        /** True when [file] is in a directory this serves. */
        fun serves(context: Context, file: File): Boolean = locate(context, file) != null

        /** [file]'s URI for another app; null when this does not serve it. */
        fun uri(context: Context, file: File): Uri? {
            val (name, path) = locate(context, file) ?: return null
            return Uri.Builder().scheme("content").authority(authority(context)).appendPath(name)
                .apply { path.split(File.separator).forEach(::appendPath) }.build()
        }

        /** The directories it serves, by the name their URIs start with. */
        private fun roots(context: Context): Map<String, File> = buildMap {
            put("downloads", CoreGraph.downloads(context))
            if (BuildConfig.DEBUG) put("demo", File(context.cacheDir, "media-demo"))
        }

        /** The name of the directory [file] is in and its path there; null outside them all. */
        private fun locate(context: Context, file: File): Pair<String, String>? {
            val path = file.canonicalPath
            return roots(context).firstNotNullOfOrNull { (name, root) ->
                val base = root.canonicalPath + File.separator
                if (path.startsWith(base)) name to path.removePrefix(base) else null
            }
        }
    }
}
