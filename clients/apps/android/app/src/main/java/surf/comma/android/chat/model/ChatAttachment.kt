package surf.comma.android.chat.model

import surf.comma.android.media.*

/** Validated media identity and geometry, carried directly to the native timeline card. */
data class ChatAttachment(
    val file: MediaAttachment,
    val dimensions: surf.comma.android.media.ImageDimensions? = null,
    val preview: ViewerImage.Local? = null,
    val gallery: List<ViewerImage> = emptyList(),
    val galleryIndex: Int = 0,
    val session: MediaSessionId? = null,
) {
    val display: AttachmentDisplay get() = MediaRouting.display(file)
    fun image(): ViewerImage? = if (display == AttachmentDisplay.IMAGE) {
        preview ?: ViewerImage.Remote(MediaImage(file.source!!, file.fileName, file.mimeType, dimensions))
    } else null
}
