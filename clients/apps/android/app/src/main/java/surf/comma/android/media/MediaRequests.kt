package surf.comma.android.media

import org.json.JSONObject
import java.security.MessageDigest

/** Exact wire ref. The message layer keeps the original content-array attachment index. */
data class MediaBlobRef(val uuid: String, val hash: String, val size: Long) {
    init {
        require(uuid.matches(Regex("[0-9a-f]{32}")))
        require(hash.matches(Regex("[0-9a-f]{64}")))
        require(size >= 0)
    }
    internal fun json() = JSONObject().put("kind", "blob").put("uuid", uuid).put("hash", hash).put("size", size)
}

sealed interface MediaSource {
    data class AgentResource(val agentId: String, val ref: MediaBlobRef) : MediaSource {
        init { require(agentId.isNotBlank()) }
    }
    /** A message's file by its place in it; [ref], when the server names its blob, is what its download is checked against. */
    data class MessageAttachment(
        val conversationId: String,
        val messageId: String,
        val index: Int,
        val ref: MediaBlobRef?,
    ) : MediaSource {
        init { require(conversationId.isNotBlank() && messageId.isNotBlank() && index >= 0) }
    }
    data class UploadedFile(val path: String) : MediaSource {
        init { require(validUploadedImagePath(path)) { "Not an uploaded image path" } }
    }
}

fun validUploadedImagePath(path: String): Boolean = path.length <= 4096 &&
    Regex("/uploads/[A-Za-z0-9_-]{22}-[A-Za-z0-9._-]+\\.(png|jpe?g|gif|webp)", RegexOption.IGNORE_CASE).matches(path)

data class MediaImage(val source: MediaSource, val fileName: String?, val mimeType: String?, val dimensions: ImageDimensions? = null) {
    init { require(InlineMediaPolicy.classify(fileName, mimeType) == InlineMediaKind.IMAGE) }
    val mime: String get() = requireNotNull(InlineMediaPolicy.mime(fileName, mimeType))
}

/** Hash tuples with length prefixes, so identifiers cannot collide through separators. */
internal fun mediaDigest(vararg parts: String): String {
    val hash = MessageDigest.getInstance("SHA-256")
    parts.forEach {
        val bytes = it.toByteArray(Charsets.UTF_8)
        hash.update("${bytes.size}:".toByteArray(Charsets.UTF_8))
        hash.update(bytes)
    }
    return hash.digest().joinToString("") { "%02x".format(it) }
}

fun mediaCacheKey(session: AuthorizedSession, source: MediaSource): String {
    val identity = when (source) {
        is MediaSource.AgentResource -> mediaDigest("blob", source.ref.hash)
        is MediaSource.MessageAttachment -> mediaDigest("attachment", source.conversationId, source.messageId, source.index.toString(), source.ref?.hash ?: "")
        is MediaSource.UploadedFile -> mediaDigest("file", source.path)
    }
    return mediaDigest(session.baseUrl.toString(), session.id.accountId, session.id.generation, session.id.groupId, identity)
}

/** Reserved for a later local-file video renderer; no player is instantiated by this module. */
interface VideoMediaHandle : AutoCloseable {
    fun setVisible(visible: Boolean)
    override fun close()
}
