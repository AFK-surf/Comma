package surf.comma.android.chat.model

/**
 * The Core-held image one timeline row shows, and where it came from.
 *
 * [origin] is the Core environment this arrived from, as `scheme://host[:port]`
 * — a plain address, never a credential and never a token digest. It is
 * persisted for two reasons that are easy to confuse:
 *
 * 1. **Deduplication scope.** [eventId] is only unique inside one Core. Pointing
 *    a debug build at a different server and meeting `req-1:4` again must not
 *    silently collide with the `req-1:4` already in the database.
 * 2. **Refusing to fetch.** A row whose origin is not the Core this build is
 *    configured for is not downloadable here, and saying so is the honest
 *    answer. The bytes are not fetched from the stored address either — see
 *    [CoreMediaRef] for why no address on the wire is ever opened.
 *
 * [eventId] is the message identity (`shared/stream-events.md#image`).
 * `media.mediaId` names bytes and is deliberately not a message key: two sends
 * of one file are two rows.
 */
data class CoreMediaAttachment(
    val origin: String,
    val eventId: String,
    val media: CoreMediaRef,
) {
    /** Opaque identity retained for older stored messages; it is not a downloadable URL. */
    val imageSource: String get() = coreMediaSource(origin, media.mediaId)
}

private const val CORE_MEDIA_PREFIX = "core-media:"

/** `core-media:<mediaId>@<origin>`; the id is 32 hex, so the first `@` splits it. */
fun coreMediaSource(origin: String, mediaId: String): String =
    "$CORE_MEDIA_PREFIX$mediaId@$origin"

/** The two halves of a [coreMediaSource], or null when this is some other image. */
fun parseCoreMediaSource(source: String?): Pair<String, String>? {
    if (source == null || !source.startsWith(CORE_MEDIA_PREFIX)) return null
    val body = source.removePrefix(CORE_MEDIA_PREFIX)
    val at = body.indexOf('@')
    if (at <= 0 || at == body.length - 1) return null
    val mediaId = body.substring(0, at)
    if (!MEDIA_ID_KEY.matches(mediaId)) return null
    return mediaId to body.substring(at + 1)
}

/** True for any string shaped like a Core media key, well-formed or not. */
fun isCoreMediaSource(source: String?): Boolean = source?.startsWith(CORE_MEDIA_PREFIX) == true

private val MEDIA_ID_KEY = Regex("[0-9a-f]{32}")

/**
 * The Core address as an identity: scheme, host and port, nothing else.
 *
 * A path, a query or a trailing slash would make two spellings of one server
 * look like two servers — and, worse, would let a configuration difference
 * quietly split the deduplication scope. Blank in, blank out: an unconfigured
 * build has no origin rather than a fake one.
 */
fun normalizeCoreOrigin(baseUrl: String): String {
    val trimmed = baseUrl.trim()
    if (trimmed.isEmpty()) return ""
    val schemeEnd = trimmed.indexOf("://")
    if (schemeEnd <= 0) return ""
    val scheme = trimmed.substring(0, schemeEnd).lowercase()
    val rest = trimmed.substring(schemeEnd + 3)
    val authority = rest.substringBefore('/').substringBefore('?').substringBefore('#')
    if (authority.isEmpty()) return ""
    return "$scheme://${authority.lowercase()}"
}
