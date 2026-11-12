package surf.comma.android.media

import android.net.Uri
import android.os.Bundle

/** A picture (or a message's video) the full-screen viewer can show; pictures it can also save. */
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

    /**
     * A message's video, downloaded whole through the signed-in session when its page is current and played there.
     * It has no picture of its own to decode.
     */
    data class Video(
        val source: MediaSource,
        override val fileName: String?,
        override val mime: String,
        override val dimensions: ImageDimensions? = null,
    ) : ViewerImage {
        val attachment: MediaAttachment get() = MediaAttachment(fileName, mime, null, source)
    }
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
                putSource(image.image.source)
            }
            is ViewerImage.Video -> {
                putString("kind", "video")
                putString("mime", image.mime)
                putSource(image.source)
            }
        }
    }

    private fun Bundle.putSource(source: MediaSource) {
        when (source) {
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
                source.ref?.let { putRef(it) }
            }
            is MediaSource.UploadedFile -> {
                putString("source", "upload")
                putString("path", source.path)
            }
        }
    }

    private fun Bundle.source(): MediaSource? = when (getString("source")) {
        "agent" -> MediaSource.AgentResource(getString("agent_id")!!, ref())
        "attachment" -> MediaSource.MessageAttachment(getString("conversation_id")!!,
            getString("message_id")!!, getInt("index", -1),
            takeIf { it.containsKey("ref_uuid") }?.ref())
        "upload" -> MediaSource.UploadedFile(getString("path")!!)
        else -> null
    }

    fun read(bundle: Bundle): ViewerImage? = runCatching {
        val name = bundle.getString("file_name")
        val dimensions = if (bundle.containsKey("width")) ImageDimensions(bundle.getInt("width"), bundle.getInt("height")) else null
        when (bundle.getString("kind")) {
            "local" -> ViewerImage.Local(Uri.parse(bundle.getString("uri")!!), bundle.getString("mime")!!, name, dimensions)
            "remote" -> {
                val source = bundle.source() ?: return@runCatching null
                ViewerImage.Remote(MediaImage(source, name, bundle.getString("mime"), dimensions))
            }
            "video" -> {
                val source = bundle.source() ?: return@runCatching null
                val mime = bundle.getString("mime")!!
                if (InlineMediaPolicy.classify(name, mime) != InlineMediaKind.VIDEO) return@runCatching null
                ViewerImage.Video(source, name, mime, dimensions)
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
