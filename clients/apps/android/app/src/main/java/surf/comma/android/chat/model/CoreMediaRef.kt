package surf.comma.android.chat.model

import org.json.JSONException
import org.json.JSONObject

/** The preview Core generated: already upright, so it never carries an orientation. */
data class CoreMediaThumbnail(
    val mimeType: String,
    val widthPx: Int,
    val heightPx: Int,
    val sizeBytes: Long,
)

/** Validated metadata retained for older stored messages. Remote downloads use MediaSource. */
data class CoreMediaRef(
    val mediaId: String,
    val mimeType: String,
    val widthPx: Int,
    val heightPx: Int,
    val sizeBytes: Long,
    val sha256: String,
    val orientation: Int,
    val thumbnail: CoreMediaThumbnail,
) {
    /**
     * The row body. Deliberately not the raw event: a stored copy of whatever
     * arrived would let an unvalidated field survive a restart and be read back
     * as if it had been checked. Only the fields above are written, so what
     * comes out of the database is what went through [parseCoreMediaRef].
     */
    fun toJson(): String = JSONObject()
        .put("mediaId", mediaId)
        .put("mimeType", mimeType)
        .put("width", widthPx)
        .put("height", heightPx)
        .put("sizeBytes", sizeBytes)
        .put("sha256", sha256)
        .put("orientation", orientation)
        .put(
            "thumbnail",
            JSONObject()
                .put("mimeType", thumbnail.mimeType)
                .put("width", thumbnail.widthPx)
                .put("height", thumbnail.heightPx)
                .put("sizeBytes", thumbnail.sizeBytes),
        )
        .toString()

    companion object {
        /** Matches Core's `MAX_SOURCE_BYTES`, and this client's own decode ceiling. */
        const val MAX_ORIGINAL_BYTES: Long = 16L * 1024 * 1024

        /**
         * A thumbnail is at most 1024 px on its longest edge (`shared/media.md`),
         * so this is generous rather than tight. It exists so a claimed size
         * cannot make the client agree in advance to read an original-sized body
         * for a list tile.
         */
        const val MAX_THUMBNAIL_BYTES: Long = 8L * 1024 * 1024

        val SUPPORTED_MIME_TYPES = setOf("image/png", "image/jpeg", "image/webp")

        private val MEDIA_ID = Regex("[0-9a-f]{32}")
        private val SHA256 = Regex("[0-9a-f]{64}")

        /** The only metadata shape this build knows. A bump means something was retyped. */
        const val SUPPORTED_VERSION = 1

        /** Orientation 1 is "upright": what a row written before the field existed meant. */
        const val UPRIGHT = 1

        fun fromJson(raw: String?): CoreMediaRef? {
            if (raw.isNullOrBlank()) return null
            return runCatching { read(JSONObject(raw), requirePaths = false) }.getOrNull()
        }

        /**
         * Parse `image.media`, or return null when it is not something this
         * client will show.
         *
         * Null is the whole vocabulary here: a caller cannot accidentally use
         * "why" to build a message, and nothing from the payload — no id, no
         * path, no JSON — is carried out for a reader to see. The turn's own
         * error surface says an event was unreadable; the event does not get to
         * write that sentence.
         */
        fun parse(media: JSONObject?): CoreMediaRef? {
            if (media == null) return null
            return runCatching { read(media, requirePaths = true) }.getOrNull()
        }

        private fun read(media: JSONObject, requirePaths: Boolean): CoreMediaRef {
            // Unknown extra keys are ignored by construction: every field below is
            // asked for by name. A missing *required* one is an error, per
            // shared/stream-events.md.
            if (requirePaths && media.optInt("version", SUPPORTED_VERSION) != SUPPORTED_VERSION) {
                throw JSONException("unsupported media version")
            }
            val mediaId = media.optString("mediaId")
            require(MEDIA_ID.matches(mediaId)) { "mediaId" }
            val mimeType = media.optString("mimeType").lowercase()
            require(mimeType in SUPPORTED_MIME_TYPES) { "mimeType" }
            val width = media.optInt("width")
            val height = media.optInt("height")
            require(width > 0 && height > 0) { "dimensions" }
            val sizeBytes = media.optLong("sizeBytes")
            require(sizeBytes in 1..MAX_ORIGINAL_BYTES) { "sizeBytes" }
            val sha256 = media.optString("sha256").lowercase()
            require(SHA256.matches(sha256)) { "sha256" }
            // Absent means a Core from before the field existed, and those images
            // were served to a client that applied no transform. Present but out
            // of range is a different thing: it is a value this build cannot act
            // on, so the event is refused rather than silently straightened.
            val orientation = media.optInt("orientation", UPRIGHT)
            require(orientation in 1..8) { "orientation" }

            if (requirePaths) {
                // Checked, then dropped. See the class comment.
                require(media.optString("downloadPath") == "/v1/media/$mediaId") { "downloadPath" }
            }

            val thumbnailJson = media.optJSONObject("thumbnail")
                ?: throw JSONException("thumbnail is required")
            val thumbnailMime = thumbnailJson.optString("mimeType").lowercase()
            require(thumbnailMime in SUPPORTED_MIME_TYPES) { "thumbnail.mimeType" }
            val thumbnailWidth = thumbnailJson.optInt("width")
            val thumbnailHeight = thumbnailJson.optInt("height")
            require(thumbnailWidth > 0 && thumbnailHeight > 0) { "thumbnail dimensions" }
            val thumbnailBytes = thumbnailJson.optLong("sizeBytes")
            require(thumbnailBytes in 1..MAX_THUMBNAIL_BYTES) { "thumbnail.sizeBytes" }
            if (requirePaths) {
                require(
                    thumbnailJson.optString("downloadPath") == "/v1/media/$mediaId/thumbnail",
                ) { "thumbnail.downloadPath" }
            }

            return CoreMediaRef(
                mediaId = mediaId,
                mimeType = mimeType,
                widthPx = width,
                heightPx = height,
                sizeBytes = sizeBytes,
                sha256 = sha256,
                orientation = orientation,
                thumbnail = CoreMediaThumbnail(
                    mimeType = thumbnailMime,
                    widthPx = thumbnailWidth,
                    heightPx = thumbnailHeight,
                    sizeBytes = thumbnailBytes,
                ),
            )
        }
    }
}
