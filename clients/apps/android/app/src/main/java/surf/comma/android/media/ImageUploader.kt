package surf.comma.android.media

/** No message-body formatting is performed here. */
data class UploadedImage(val path: String, val name: String, val size: Long, val dimensions: ImageDimensions, val mimeType: String)
