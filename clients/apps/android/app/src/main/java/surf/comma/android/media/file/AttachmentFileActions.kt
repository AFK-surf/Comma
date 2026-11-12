package surf.comma.android.media.file

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.widget.Toast
import surf.comma.android.R
import surf.comma.android.media.FileKinds
import surf.comma.android.media.MediaAttachment
import java.io.File

/**
 * What a person can do with a downloaded attachment besides opening it: save a copy where they choose ([saveAs]) or
 * hand it to another app ([share]). Both take only the client core's downloads, which [MediaFileProvider] serves.
 */
object AttachmentFileActions {
    /** Asks where to save a copy of [file] through the system's document picker, then writes it there. */
    fun saveAs(context: Context, file: File, attachment: MediaAttachment) {
        if (!MediaFileProvider.serves(context, file)) {
            Toast.makeText(context, R.string.media_file_unavailable, Toast.LENGTH_SHORT).show()
            return
        }
        context.startActivity(SaveAttachmentActivity.intent(context, file, attachment.displayName,
            FileKinds.openType(attachment.fileName, attachment.mimeType)))
    }

    /** Opens the system's share sheet with [file], read-only. */
    fun share(context: Context, file: File, attachment: MediaAttachment) {
        val uri = MediaFileProvider.uri(context, file) ?: run {
            Toast.makeText(context, R.string.media_file_unavailable, Toast.LENGTH_SHORT).show()
            return
        }
        val send = Intent(Intent.ACTION_SEND).setType(FileKinds.openType(attachment.fileName, attachment.mimeType))
            .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            context.startActivity(Intent.createChooser(send, attachment.displayName))
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(context, R.string.media_file_no_app, Toast.LENGTH_SHORT).show()
        }
    }
}
