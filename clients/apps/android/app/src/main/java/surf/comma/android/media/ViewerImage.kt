package surf.comma.android.media

import android.net.Uri
import android.os.Bundle

/** A picture the full-screen viewer can show and save. */
sealed interface ViewerImage {
    val fileName: String?
    val mime: String
    val dimensions: ImageDimensions?

    /** A message picture, loaded through the signed-in session. */
    data class Remote(val image: MediaImage) : ViewerImage {
        override val fileName get() = image.fileName
        override val mime get() = image.mime
        override val dimensions get() = image.dimensions
    }

    /** A picture already on the device, such as the user's own photo before it is sent. */
    data class Local(
        val uri: Uri,
        override val mime: String,
        override val fileName: String? = null,
        override val dimensions: ImageDimensions? = null,
    ) : ViewerImage
}

/**
 * Intent extras carry only the validated reference fields, never a URL or a credential. A value
 * that no longer validates reads back as null, and the viewer closes.
 */
object ViewerImageBundles {
    fun write(image: ViewerImage): Bundle = Bundle().apply {
        putString("file_name", image.fileName)
        image.dimensions?.let { putInt("width", it.width); putInt("height", it.height) }
        when (image) {
            is ViewerImage.Local -> {
                putString("kind", "local")
                putString("uri", image.uri.toString())
                putString("mime", image.mime)
            }
            is ViewerImage.Remote -> {
                putString("kind", "remote")
                putString("mime", image.image.mimeType)
                when (val source = image.image.source) {
                    is MediaSource.AgentResource -> {
                        putString("source", "agent")
                        putString("agent_id", source.agentId)
                        putRef(source.ref)
                    }
                    is MediaSource.MessageAttachment -> {
                        putString("source", "attachment")
                        putString("conversation_id", source.conversationId)
                        putString("message_id", source.messageId)
                        putInt("index", source.index)
                        putRef(source.ref)
                    }
                    is MediaSource.UploadedFile -> {
                        putString("source", "upload")
                        putString("path", source.path)
                    }
                }
            }
        }
    }

    fun read(bundle: Bundle): ViewerImage? = runCatching {
        val name = bundle.getString("file_name")
        val dimensions = if (bundle.containsKey("width")) ImageDimensions(bundle.getInt("width"), bundle.getInt("height")) else null
        when (bundle.getString("kind")) {
            "local" -> ViewerImage.Local(Uri.parse(bundle.getString("uri")!!), bundle.getString("mime")!!, name, dimensions)
            "remote" -> {
                val source = when (bundle.getString("source")) {
                    "agent" -> MediaSource.AgentResource(bundle.getString("agent_id")!!, bundle.ref())
                    "attachment" -> MediaSource.MessageAttachment(bundle.getString("conversation_id")!!,
                        bundle.getString("message_id")!!, bundle.getInt("index", -1), bundle.ref())
                    "upload" -> MediaSource.UploadedFile(bundle.getString("path")!!)
                    else -> return@runCatching null
                }
                ViewerImage.Remote(MediaImage(source, name, bundle.getString("mime"), dimensions))
            }
            else -> null
        }
    }.getOrNull()

    private fun Bundle.putRef(ref: MediaBlobRef) {
        putString("ref_uuid", ref.uuid)
        putString("ref_hash", ref.hash)
        putLong("ref_size", ref.size)
    }

    private fun Bundle.ref() = MediaBlobRef(getString("ref_uuid")!!, getString("ref_hash")!!, getLong("ref_size", -1))
}
