package surf.comma.android.miniapps

import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.core.CoreError

/** UI projections of the existing Mini App and Version contracts. The server owns publication and authorization. */
data class MiniAppRecord(
    val id: String,
    val workspaceId: String,
    val name: String,
    val summary: String,
    val iconUrl: String?,
    /** The shown Version's cover, for gallery cards; screenshots show on its details page. */
    val coverUrl: String?,
    val screenshotUrls: List<String>,
    val visibility: String,
    val status: String,
    val liveVersion: Int?,
    val latestVersion: Int?,
    val installed: Boolean,
    val pinnedVersion: Int?,
    val author: String,
) {
    val runningVersion: Int? get() = if (installed) pinnedVersion ?: liveVersion else liveVersion ?: latestVersion
    val active: Boolean get() = status == "active"

    companion object {
        fun parse(json: JSONObject?): MiniAppRecord? {
            json ?: return null
            val id = json.text("id") ?: return null
            val workspace = json.text("workspace_id") ?: return null
            return MiniAppRecord(
                id = id, workspaceId = workspace, name = json.text("name") ?: "", summary = json.text("description").orEmpty(),
                iconUrl = json.text("icon_url"), coverUrl = json.text("cover_url"),
                screenshotUrls = strings(json.optJSONArray("screenshot_urls")).take(MAX_SCREENSHOTS),
                visibility = json.text("visibility") ?: "private", status = json.text("status") ?: "disabled",
                liveVersion = json.number("live_version"), latestVersion = json.number("latest_version"),
                installed = json.optBoolean("installed"), pinnedVersion = json.optJSONObject("install")?.number("pinned_version"),
                author = json.optJSONObject("author")?.text("name").orEmpty(),
            )
        }

        const val MAX_SCREENSHOTS = 6
    }
}

data class MiniAppVersionRecord(
    val number: Int,
    val state: String,
    val live: Boolean,
    val commit: String?,
    val notes: String,
    val conversationId: String?,
) {
    companion object {
        fun parse(json: JSONObject?): MiniAppVersionRecord? {
            val number = json?.number("number")?.takeIf { it > 0 } ?: return null
            return MiniAppVersionRecord(number, json.text("state") ?: "failed", json.optBoolean("live"), json.text("commit"),
                json.text("notes").orEmpty(), json.text("conversation_id"))
        }
    }
}

/** A previewed Version and the build review it was previewed under. Publication sends both. */
data class MiniAppPublication(val appId: String, val version: Int, val conversationId: String, val reviewVersion: Long)

/**
 * A route selects an app. The core session supplies authority for every app operation. [conversationId] is the build
 * Task the app was opened from, which the run screen may offer to publish while its review still matches.
 */
data class MiniAppTarget(
    val workspaceId: String,
    val appId: String,
    val version: Int? = null,
    val conversationId: String? = null,
    val shareToken: String? = null,
) {
    val runtimeKey: String get() = "$workspaceId/$appId"
}

/** A chat message's Mini App card: a launch card, never a background WebView. */
data class MiniAppCardValue(val appId: String, val version: Int, val name: String, val summary: String, val conversationId: String) {
    fun json(): JSONObject = JSONObject().put("appId", appId).put("appVersion", version).put("name", name)
        .put("summary", summary).put("conversationId", conversationId)

    companion object {
        fun parse(json: JSONObject?): MiniAppCardValue? {
            json ?: return null
            val app = json.text("appId")?.takeIf { it.length <= 256 } ?: return null
            val version = json.number("appVersion")?.takeIf { it > 0 } ?: return null
            val conversation = json.text("conversationId") ?: return null
            return MiniAppCardValue(app, version, json.text("name") ?: "", json.text("summary").orEmpty(), conversation)
        }
    }
}

/** Public links (`/a/<token>`), which open the Shared app page. The token goes only to the core. */
object MiniAppLinks {
    private const val PROD = "app.comma.surf"
    private const val STAGING = "app-staging.comma.surf"

    /** The web origin's host that belongs to [apiOrigin]; null for a development backend. */
    fun webHost(apiOrigin: Uri): String? {
        if (apiOrigin.scheme != "https" || apiOrigin.port != -1) return null
        return when (apiOrigin.host) {
            "salix.comma.surf" -> PROD
            "salix-staging.comma.surf", "salix-staging.cue.surf" -> STAGING
            else -> null
        }
    }

    /** The token of a public link of this environment, or null. */
    fun sharedToken(url: Uri, apiOrigin: Uri): String? {
        val host = webHost(apiOrigin) ?: return null
        if (!plain(url, host)) return null
        val parts = (url.encodedPath ?: return null).trim('/').split('/')
        if (parts.size != 2 || parts[0] != "a" || !validToken(parts[1])) return null
        val path = url.encodedPath
        return parts[1].takeIf { path == "/a/${parts[1]}" || path == "/a/${parts[1]}/" }
    }

    /** A path either environment claims, even when invalid: it gets a bounded error instead of another environment. */
    fun isClaimed(url: Uri): Boolean =
        url.scheme == "https" && url.host in setOf(PROD, STAGING) && (url.path ?: "").startsWith("/a/")

    fun validToken(value: String): Boolean =
        value.length == 43 && value.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '-' || it == '_' }

    private fun plain(url: Uri, host: String) =
        url.scheme == "https" && url.host == host && url.port == -1 && url.userInfo == null
}

/** One host-owned photo selection. It holds no platform permission or library identifier. */
class MiniAppPhotoRequest(val multiple: Boolean, val png: Boolean) {
    val limit: Int get() = if (multiple) MAX_PHOTOS else 1

    companion object {
        const val MAX_PHOTOS = 6
        const val MAX_PHOTO_BYTES = 4 * 1024 * 1024
        const val MAX_TOTAL_BYTES = 8 * 1024 * 1024

        fun parse(args: JSONObject?): MiniAppPhotoRequest {
            val accept = args?.optJSONArray("accept")?.let(::strings)?.map { it.lowercase() } ?: listOf("image/*")
            val jpeg = accept.isEmpty() || accept.any { it in setOf("image/*", "*/*", "image/jpeg", ".jpg", ".jpeg") }
            val png = accept.any { it in setOf("image/*", "*/*", "image/png", ".png") }
            if (!jpeg && !png) throw CoreError("unsupported", "This device can select JPEG and PNG photos.")
            return MiniAppPhotoRequest(args?.optBoolean("multiple") == true, png = !jpeg && png)
        }
    }
}

class MiniAppPhoto(val data: ByteArray, val png: Boolean)

internal fun JSONObject.text(key: String): String? = optString(key).takeIf { has(key) && !isNull(key) && it.isNotEmpty() }
internal fun JSONObject.number(key: String): Int? = if (has(key) && !isNull(key)) (opt(key) as? Number)?.toInt() else null
internal fun JSONObject.objects(key: String): List<JSONObject> =
    optJSONArray(key)?.let { array -> (0 until array.length()).mapNotNull(array::optJSONObject) }.orEmpty()
internal fun strings(array: JSONArray?): List<String> =
    array?.let { (0 until it.length()).mapNotNull { index -> it.opt(index) as? String } }.orEmpty()
