package surf.comma.android.media.file

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import surf.comma.android.R
import surf.comma.android.ui.Background
import java.io.File

/**
 * Save as: shows the system's document picker for a downloaded attachment and copies it to the place chosen. It has
 * no window of its own; it owns the picker's result, so the answer still arrives after the screen that asked is
 * gone or recreated. The copy outlives this activity and says when it is done.
 */
class SaveAttachmentActivity : ComponentActivity() {
    /** The picker is told the file's type, so it suggests a fitting place and keeps the extension. */
    private val pick = registerForActivityResult(object : ActivityResultContracts.CreateDocument("*/*") {
        override fun createIntent(context: Context, input: String): Intent =
            super.createIntent(context, input).setType(intent.getStringExtra(EXTRA_TYPE) ?: "*/*")
    }) { target ->
        val source = intent.getStringExtra(EXTRA_PATH)?.let(::File)
        if (target != null && source != null) copy(applicationContext, source, target)
        finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return
        val path = intent.getStringExtra(EXTRA_PATH)
        // Only the core's downloads are saved from; anything else ends here.
        if (path == null || !MediaFileProvider.serves(this, File(path))) {
            finish()
            return
        }
        try {
            pick.launch(intent.getStringExtra(EXTRA_NAME) ?: File(path).name)
        } catch (_: android.content.ActivityNotFoundException) {
            Toast.makeText(this, R.string.media_file_no_app, Toast.LENGTH_SHORT).show()
            finish()
        }
    }

    companion object {
        private const val EXTRA_PATH = "path"
        private const val EXTRA_NAME = "name"
        private const val EXTRA_TYPE = "type"
        private val copies = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

        fun intent(context: Context, file: File, name: String, type: String): Intent =
            Intent(context, SaveAttachmentActivity::class.java)
                .putExtra(EXTRA_PATH, file.absolutePath).putExtra(EXTRA_NAME, name).putExtra(EXTRA_TYPE, type)

        /** Copies [source] into the document [target] the picker made; says whether it was saved. */
        internal fun copy(context: Context, source: File, target: Uri) {
            copies.launch {
                val saved = withContext(Background.files) {
                    runCatching {
                        source.inputStream().use { input ->
                            context.contentResolver.openOutputStream(target, "wt")!!.use { input.copyTo(it) }
                        }
                    }.onFailure {
                        // A half-written copy is removed rather than left looking whole.
                        runCatching { DocumentsContract.deleteDocument(context.contentResolver, target) }
                    }.isSuccess
                }
                Toast.makeText(context, if (saved) R.string.media_file_saved else R.string.media_file_save_failed,
                    Toast.LENGTH_SHORT).show()
            }
        }
    }
}
