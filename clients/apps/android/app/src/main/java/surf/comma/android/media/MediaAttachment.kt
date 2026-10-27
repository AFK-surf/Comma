package surf.comma.android.media

import android.webkit.MimeTypeMap

/**
 * An image or file block as the message layer found it. [source] is null when the block carries
 * nothing this client can download (for example a path-only agent file, or a size over the
 * limit that no blob ref can describe); such a block can only be shown as a file card.
 */
data class MediaAttachment(
    val fileName: String?,
    val mimeType: String?,
    /** The block's declared size, or the blob ref's. Display only; downloads check the ref. */
    val size: Long?,
    val source: MediaSource?,
) {
    val displayName: String get() = fileName?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: "attachment"
    val extension: String get() = displayName.substringAfterLast('.', "").lowercase()
}

enum class AttachmentDisplay { IMAGE, VIDEO, FILE }

object MediaRouting {
    /** Inline the supported image/video formats when a download source is available. */
    fun display(attachment: MediaAttachment): AttachmentDisplay = when {
        attachment.source == null -> AttachmentDisplay.FILE
        else -> when (InlineMediaPolicy.classify(attachment.fileName, attachment.mimeType)) {
            InlineMediaKind.IMAGE -> AttachmentDisplay.IMAGE
            InlineMediaKind.VIDEO -> AttachmentDisplay.VIDEO
            InlineMediaKind.FILE -> AttachmentDisplay.FILE
        }
    }
}

internal val MediaSource.declaredSize: Long?
    get() = when (this) {
        is MediaSource.AgentResource -> ref.size
        is MediaSource.MessageAttachment -> ref?.size
        is MediaSource.UploadedFile -> null
    }

/** Which glyph a file card shows. Routing to inline display is [MediaRouting]'s job, not this. */
enum class FileKind { IMAGE, VIDEO, AUDIO, PDF, TEXT, CODE, ARCHIVE, OTHER }

object FileKinds {
    private val byExtension = buildMap {
        listOf("png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "avif").forEach { put(it, FileKind.IMAGE) }
        listOf("mp4", "m4v", "webm", "mov", "mkv", "avi", "3gp").forEach { put(it, FileKind.VIDEO) }
        listOf("mp3", "m4a", "aac", "wav", "flac", "ogg", "opus").forEach { put(it, FileKind.AUDIO) }
        put("pdf", FileKind.PDF)
        listOf("txt", "md", "markdown", "rtf", "doc", "docx", "odt", "pages", "csv", "tsv", "xls", "xlsx", "ods",
            "numbers", "ppt", "pptx", "key", "log").forEach { put(it, FileKind.TEXT) }
        listOf("svg", "html", "htm", "xml", "json", "yaml", "yml", "js", "mjs", "ts", "tsx", "jsx", "css", "kt",
            "java", "py", "rb", "go", "rs", "swift", "c", "h", "cpp", "sh", "sql", "ex", "exs").forEach { put(it, FileKind.CODE) }
        listOf("zip", "gz", "tgz", "tar", "7z", "rar", "bz2", "xz").forEach { put(it, FileKind.ARCHIVE) }
    }

    /** A specific declared type wins; a missing or generic one falls back to the extension. */
    fun kind(fileName: String?, mimeType: String?): FileKind {
        val mime = InlineMediaPolicy.normalize(mimeType).substringBefore(';').trim()
        val extension = fileName.orEmpty().substringAfterLast('/').substringAfterLast('.', "").lowercase()
        return when {
            mime == "application/pdf" -> FileKind.PDF
            mime == "image/svg+xml" || mime == "text/html" || mime == "application/xhtml+xml" -> FileKind.CODE
            mime in setOf("application/zip", "application/gzip", "application/x-tar", "application/x-7z-compressed",
                "application/vnd.rar", "application/x-rar-compressed") -> FileKind.ARCHIVE
            mime.startsWith("image/") -> FileKind.IMAGE
            mime.startsWith("video/") -> FileKind.VIDEO
            mime.startsWith("audio/") -> FileKind.AUDIO
            mime.startsWith("text/") -> byExtension[extension]?.takeIf { it == FileKind.CODE } ?: FileKind.TEXT
            else -> byExtension[extension] ?: FileKind.OTHER
        }
    }

    /** The type handed to other apps: the declared one, else the extension's, else generic. */
    fun openType(fileName: String?, mimeType: String?): String {
        val declared = InlineMediaPolicy.normalize(mimeType).substringBefore(';').trim()
        if (declared.isNotEmpty() && declared != "application/octet-stream" && declared.contains('/')) return declared
        val extension = fileName.orEmpty().substringAfterLast('/').substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream"
    }

    /** A name safe to create on disk that keeps the extension other apps look at. */
    fun safeFileName(fileName: String?): String {
        val base = fileName.orEmpty().substringAfterLast('/').substringAfterLast('\\')
            .filter { !it.isISOControl() && it !in "/\\:*?\"<>|" }.trim().trimStart('.')
        if (base.isEmpty()) return "attachment"
        if (base.length <= 120) return base
        val extension = base.substringAfterLast('.', "").take(16)
        return if (extension.isEmpty()) base.take(120) else base.take(120 - extension.length - 1) + "." + extension
    }
}
