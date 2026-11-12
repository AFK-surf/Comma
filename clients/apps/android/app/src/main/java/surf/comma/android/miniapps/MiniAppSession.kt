package surf.comma.android.miniapps

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreBytes
import surf.comma.android.core.CoreError

/**
 * The device side effects of host operations the core already authorized. The run screen supplies them; the session
 * calls them only while the run is in the foreground.
 */
interface MiniAppDeviceHost {
    /** Adds [text] to the current chat's draft; false when no chat can take it. Nothing is sent. */
    fun draft(text: String): Boolean
    fun copy(text: String)
    /** Opens an HTTPS link outside the app; whether something opened it. */
    fun open(url: String): Boolean
    /** Posts a notification; false when the member does not permit notifications. */
    suspend fun notify(title: String, body: String): Boolean
}

/** An owned native runtime, retained across presentations without exposing the WebView to session authority. */
interface MiniAppRuntimeHandle {
    fun stop()
    fun suspend()
    fun resume()
}

/**
 * One in-memory execution. The core authorizes every operation; the host confirms each photo delivery. App messages
 * cannot select a session, core method, grant or confirmation.
 */
class MiniAppSession(private val core: CoreApi, val target: MiniAppTarget) {
    /** What the run screen shows. */
    data class State(
        val name: String? = null,
        val version: Int? = null,
        val failure: String? = null,
        val ready: Boolean = false,
        val needsConsent: Boolean = false,
        val running: Boolean = false,
        val suspended: Boolean = false,
        val photoRequest: PhotoRequest? = null,
        val hostRequest: HostRequest? = null,
    )

    class PhotoRequest(val id: Long, val request: MiniAppPhotoRequest)

    /** A host confirmation: [op] is the operation or capability, [detail] the text or link it carries. */
    class HostRequest(val id: Long, val op: String, val detail: String)

    private val mutableState = MutableStateFlow(State())
    val state: StateFlow<State> = mutableState.asStateFlow()
    private val background = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private var session: String? = null
    private var info: JSONObject? = null
    private var generation = 0
    private var photoEpoch = 0
    private var photoIds = 0L
    private var photoReply: CompletableDeferred<List<MiniAppPhoto>>? = null
    private var hostReply: CompletableDeferred<Boolean>? = null
    /** The run screen's device effects; null while no screen shows the run. */
    var device: MiniAppDeviceHost? = null
    private var approved = false
    private var opened = false
    /** Whether the run screen shows the app edge to edge. Kept across presentations of this execution. */
    var immersive = true

    var runtime: MiniAppRuntimeHandle? = null
        set(value) {
            field = value
            if (state.value.suspended) value?.suspend()
        }

    val canRun: Boolean get() = approved && session != null
    val canContinue: Boolean get() = canRun && state.value.failure == null
    val isSuspended: Boolean get() = state.value.suspended

    fun suspend() {
        photoEpoch++
        cancelHostRequest()
        cancelPhotoRequest()
        val suspended = canContinue
        mutableState.update { it.copy(suspended = suspended) }
        if (suspended) runtime?.suspend()
    }

    fun resume() {
        mutableState.update { it.copy(suspended = false) }
        runtime?.resume()
    }

    suspend fun open() {
        if (opened) return
        opened = true
        mutableState.update { it.copy(failure = null) }
        val current = generation
        try {
            val via = target.shareToken?.let { JSONObject().put("token", it) } ?: JSONObject().put("workspace", target.workspaceId)
            val params = JSONObject().put("app", target.appId).put("via", via).put("platform", "android")
            if (target.shareToken == null) target.version?.let { params.put("version", it) }
            val answer = core.call("miniApps.session.open", params) as? JSONObject
                ?: throw CoreError("invalid", "The app has no session.")
            val id = answer.text("session") ?: throw CoreError("invalid", "The app has no session.")
            if (current != generation) {
                runCatching { core.call("miniApps.session.close", JSONObject().put("session", id)) }
                return
            }
            session = id
            info = answer
            mutableState.update {
                it.copy(name = answer.optJSONObject("app")?.text("name"), version = answer.number("version"), needsConsent = true)
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (current == generation) mutableState.update { it.copy(failure = message(error)) }
        }
    }

    /** The host's Run button approves cloud access for this run. App messages cannot approve it. */
    fun approve() {
        if (session == null) return
        approved = true
        mutableState.update { it.copy(needsConsent = false, running = true) }
    }

    suspend fun bundle(): JSONObject {
        val id = session.takeIf { approved } ?: throw CoreError("denied", "Cloud access was not approved.")
        val current = generation
        val bundle = core.call("miniApps.bundle", JSONObject().put("session", id)) as? JSONObject
            ?: throw CoreError("invalid", "The app bundle is invalid.")
        if (current != generation) throw CancellationException("The app closed.")
        return bundle
    }

    /**
     * The frame's initial values. The app receives no credentials or native objects, and the viewer only under an
     * existing identity grant.
     */
    fun initialization(dark: Boolean, tokens: Map<String, String>, locale: String = "en", timeZone: String = "UTC"): JSONObject {
        val info = info
        val app = info?.optJSONObject("app")
        val grants = info?.optJSONArray("grants")
        val identity = grants != null && (0 until grants.length()).any { grants.optString(it) == "identity.basic" }
        return JSONObject()
            .put("app", JSONObject().put("id", app?.text("id").orEmpty()).put("name", app?.text("name").orEmpty())
                .put("version", info?.number("version") ?: 0))
            .put("viewer", info?.optJSONObject("viewer")?.takeIf { identity } ?: JSONObject.NULL)
            .put("theme", if (dark) "dark" else "light")
            .put("tokens", JSONObject(tokens))
            .put("locale", locale).put("timeZone", timeZone)
            .put("capabilities", info?.optJSONArray("capabilities") ?: JSONArray())
            .put("grants", info?.optJSONArray("grants") ?: JSONArray())
            .put("storage", info?.optJSONArray("storage") ?: JSONArray())
            .put("backend", info?.optBoolean("backend") ?: false)
    }

    /** One frame call, answered as the runtime expects: `{ok, value}` or `{ok: false, error}`. */
    suspend fun invoke(request: JSONObject): JSONObject {
        val id = session.takeIf { approved } ?: return error("denied", "The app is not running.")
        val op = request.text("op")?.takeIf(::permits) ?: return error("unsupported", "This operation is not available on Android.")
        val current = generation
        val epoch = photoEpoch
        if (op == "files.pick" && isSuspended) return error("unavailable", "The app is not in the foreground.")
        fun stale() = current != generation
        fun left() = stale() || epoch != photoEpoch || isSuspended
        val args = request.optJSONObject("args") ?: JSONObject()
        return try {
            val params = JSONObject().put("session", id).put("op", op).put("args", args)
            var answer = core.call("miniApps.invoke", params) as? JSONObject ?: JSONObject()
            if (stale()) return error("unavailable", "The app closed.")
            if (answer.text("status") == "grant") {
                val capability = answer.text("capability")
                if (capability == null || capability !in GRANTABLE) return error("unsupported", "This capability is not available on Android.")
                if (capability !in CLOUD_GRANTS && (!requestHost(capability, "") || left())) return error("denied", "The request was cancelled.")
                core.call("miniApps.grant", JSONObject().put("session", id).put("capability", capability))
                if (stale()) return error("unavailable", "The app closed.")
                answer = core.call("miniApps.invoke", params) as? JSONObject ?: JSONObject()
            }
            if (stale()) return error("unavailable", "The app closed.")
            if (op != "files.pick" && answer.text("status") == "confirm") {
                val detail = (args.text("text") ?: args.text("url") ?: "").take(4000)
                if (!requestHost(op, detail) || left()) return error("denied", "The request was cancelled.")
                answer = core.call("miniApps.invoke", JSONObject(params.toString()).put("confirmed", true)) as? JSONObject ?: JSONObject()
                if (stale()) return error("unavailable", "The app closed.")
            }
            if (op == "files.pick" && answer.text("status") == "confirm") {
                if (left()) return error("unavailable", "The app left the foreground.")
                val photos = requestPhotos(MiniAppPhotoRequest.parse(request.optJSONObject("args")))
                if (left()) return error("unavailable", "The app left the foreground.")
                if (photos.isEmpty()) return JSONObject().put("ok", true).put("value", JSONArray())
                answer = core.call("miniApps.invoke", JSONObject(params.toString()).put("confirmed", true)) as? JSONObject ?: JSONObject()
                if (left()) return error("unavailable", "The app left the foreground.")
                if (answer.text("status") == "host") {
                    val files = JSONArray()
                    photos.forEachIndexed { index, photo ->
                        files.put(JSONObject().put("name", "photo-${index + 1}." + if (photo.png) "png" else "jpg")
                            .put("mime", if (photo.png) "image/png" else "image/jpeg").put("data", CoreBytes.json(photo.data)))
                    }
                    return JSONObject().put("ok", true).put("value", files)
                }
            }
            if (op != "files.pick" && answer.text("status") == "host") {
                // Only the device side effect waits for the foreground; a call the server already completed reports its result.
                if (left()) return error("unavailable", "The app left the foreground.")
                return host(op, answer.optJSONObject("args") ?: args, ::left)
            }
            if (answer.text("status") == "done") JSONObject().put("ok", true).put("value", answer.opt("value") ?: JSONObject.NULL)
            else error(answer.text("code") ?: "unsupported", answer.text("message") ?: "The app call was refused.")
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            error((failure as? CoreError)?.code ?: "unavailable", "The app call failed.")
        }
    }

    private suspend fun host(op: String, args: JSONObject, left: () -> Boolean): JSONObject {
        val device = device ?: return error("unavailable", "The app is not in the foreground.")
        val ok = JSONObject().put("ok", true).put("value", JSONObject.NULL)
        return when (op) {
            "chat.draft" -> {
                val text = args.text("text") ?: return error("invalid", "Text is required.")
                if (device.draft(text)) ok else error("unavailable", "Open a chat first.")
            }
            "clipboard.write" -> {
                if (!args.has("text") || args.isNull("text")) return error("invalid", "Text is required.")
                device.copy(args.optString("text"))
                ok
            }
            "links.open" -> {
                val url = args.text("url")?.takeIf(::isOpenableLink) ?: return error("invalid", "Only HTTPS links open.")
                JSONObject().put("ok", true).put("value", JSONObject().put("opened", device.open(url)))
            }
            "notify" -> when {
                !device.notify(args.text("title") ?: state.value.name.orEmpty(), args.text("body").orEmpty()) ->
                    error("denied", "Notifications are disabled.")
                left() -> error("unavailable", "The app left the foreground.")
                else -> ok
            }
            else -> error("unsupported", "This host operation is unavailable.")
        }
    }

    /** Waits for the member's answer to one host confirmation. Leaving the foreground answers no. */
    private suspend fun requestHost(op: String, detail: String): Boolean {
        if (hostReply != null || photoReply != null || isSuspended) return false
        val reply = CompletableDeferred<Boolean>()
        val shown = HostRequest(++photoIds, op, detail)
        hostReply = reply
        mutableState.update { it.copy(hostRequest = shown) }
        try {
            return reply.await()
        } finally {
            if (hostReply === reply) finishHostRequest(shown.id, approved = false)
        }
    }

    /** The member answered host request [id]. A suspended run answers no. */
    fun finishHostRequest(id: Long, approved: Boolean) {
        if (state.value.hostRequest?.id != id) return
        val reply = hostReply
        hostReply = null
        mutableState.update { it.copy(hostRequest = null) }
        reply?.complete(approved && !isSuspended)
    }

    fun cancelHostRequest() {
        state.value.hostRequest?.let { finishHostRequest(it.id, approved = false) }
    }

    private suspend fun requestPhotos(request: MiniAppPhotoRequest): List<MiniAppPhoto> {
        if (photoReply != null || hostReply != null) throw CoreError("rate_limited", "Finish the current photo request first.")
        val reply = CompletableDeferred<List<MiniAppPhoto>>()
        val shown = PhotoRequest(++photoIds, request)
        photoReply = reply
        mutableState.update { it.copy(photoRequest = shown) }
        try {
            return reply.await()
        } finally {
            if (photoReply === reply) cancelPhotoRequest(shown.id)
        }
    }

    /** The member confirmed [photos] for request [id]. A selection over the bounds fails the call instead. */
    fun finishPhotoRequest(id: Long, photos: List<MiniAppPhoto>) {
        val shown = state.value.photoRequest?.takeIf { it.id == id && !isSuspended } ?: return
        val reply = photoReply
        photoReply = null
        mutableState.update { it.copy(photoRequest = null) }
        val request = shown.request
        val bounded = photos.size <= request.limit &&
            photos.all { it.data.isNotEmpty() && it.data.size <= MiniAppPhotoRequest.MAX_PHOTO_BYTES && it.png == request.png } &&
            photos.sumOf { it.data.size } <= MiniAppPhotoRequest.MAX_TOTAL_BYTES
        if (bounded) reply?.complete(photos)
        else reply?.completeExceptionally(CoreError("quota_exceeded", "The photo selection is too large."))
    }

    fun cancelPhotoRequest(id: Long? = null) {
        if (id != null && id != state.value.photoRequest?.id) return
        val reply = photoReply
        photoReply = null
        if (state.value.photoRequest != null) mutableState.update { it.copy(photoRequest = null) }
        reply?.complete(emptyList())
    }

    fun started() {
        if (approved) mutableState.update { it.copy(ready = true) }
    }

    fun failed(error: Throwable) {
        mutableState.update { it.copy(failure = message(error)) }
        stop()
    }

    /** Closes the core session and the runtime. Nothing is replayed after this. */
    fun stop() {
        cancelHostRequest()
        cancelPhotoRequest()
        val previous = runtime
        runtime = null
        opened = false
        generation++
        approved = false
        mutableState.update { it.copy(ready = false, needsConsent = false, running = false, suspended = false) }
        session?.let { id -> background.launch { runCatching { core.call("miniApps.session.close", JSONObject().put("session", id)) } } }
        session = null
        previous?.stop()
    }

    private fun message(error: Throwable) = error.message?.takeIf { it.isNotBlank() } ?: "The app is unavailable."

    companion object {
        /** Grants the cloud-access approval covers; the others need the member's separate approval. */
        private val CLOUD_GRANTS = setOf("ai.chat", "web.search")
        private val GRANTABLE = CLOUD_GRANTS + setOf("identity.basic", "drive.app_folder", "notifications")
        private val OPS = setOf("ai.chat", "ai.decide", "web.search", "backend.fetch", "files.pick", "viewer", "chat.draft",
            "clipboard.write", "links.open", "tasks.propose", "drive.list", "drive.read", "drive.write", "drive.delete", "notify")

        /** What a phone container may ask the core for. Device storage and Mac Calendar stay unavailable. */
        fun permits(op: String): Boolean {
            if (op in OPS) return true
            val parts = op.split('.')
            return parts.size == 3 && parts[0] == "storage" && parts[1] in setOf("user", "app") &&
                parts[2] in setOf("get", "put", "delete", "list")
        }

        /** HTTPS without user info, as the core checks it. */
        fun isOpenableLink(url: String): Boolean = runCatching {
            val uri = java.net.URI(url)
            uri.scheme == "https" && uri.rawUserInfo == null && !uri.host.isNullOrEmpty()
        }.getOrDefault(false)

        fun error(code: String, message: String): JSONObject =
            JSONObject().put("ok", false).put("error", JSONObject().put("code", code).put("message", message))
    }
}
