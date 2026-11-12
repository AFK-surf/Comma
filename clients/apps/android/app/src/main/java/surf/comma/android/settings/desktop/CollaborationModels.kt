package surf.comma.android.settings.desktop

import org.json.JSONObject
import surf.comma.android.R

/** A chat channel that reaches this Workspace's Router. */
internal enum class Channel(val wire: String) {
    TELEGRAM("telegram"), WECHAT("wechat"), SIGNAL("signal"), IMESSAGE("imessage"), LINEAR("linear");

    val logo: Int get() = when (this) {
        TELEGRAM -> R.drawable.provider_telegram
        WECHAT -> R.drawable.provider_wechat
        SIGNAL -> R.drawable.provider_signal
        IMESSAGE -> R.drawable.provider_imessage
        LINEAR -> R.drawable.provider_linear
    }
}

/** One channel's core topic and connection calls; the core tracks the connection. */
internal class ChannelModel(scope: WorkspaceScope, val channel: Channel, private val apiHost: String) {
    val feed = WorkspaceTopic(scope, channel.wire,
        if (channel == Channel.TELEGRAM) json() else json("workspace" to scope.workspaceId), workspaceField = channel == Channel.TELEGRAM)
    val scope get() = feed.scope
    var signalCode: JSONObject? = null
        private set

    val state get() = feed.value?.optJSONObject("state")
    val busy get() = scope.busy || feed.value?.optBoolean("busy") == true
    val hasState get() = if (channel == Channel.SIGNAL) feed.value?.optJSONObject("integration") != null else state != null
    val connected: Boolean
        get() = when (channel) {
            Channel.TELEGRAM -> state?.optJSONObject("link") != null
            Channel.WECHAT -> state?.optJSONObject("connection")?.optBoolean("connection_active") == true
            Channel.IMESSAGE -> state?.optJSONObject("link") != null && state?.optBoolean("connection_active") == true
            Channel.SIGNAL -> feed.value?.optJSONObject("integration")?.objects("bindings")?.isNotEmpty() == true
            Channel.LINEAR -> state?.optJSONObject("member") != null
        }

    suspend fun action(name: String, params: JSONObject = JSONObject()): Done? =
        scope.perform(channel.wire + "." + name, params, workspaceParameter = channel != Channel.TELEGRAM)

    /** Starts connecting; Telegram and Linear answer with a browser link. [handle] is iMessage's account. */
    suspend fun connect(handle: String = ""): String? {
        // The deployed callback channels the service accepts; other hosts use its production default.
        val environment = when (apiHost) {
            "salix-staging.cue.surf", "salix-staging.comma.surf" -> "staging"
            "localhost", "127.0.0.1", "10.0.2.2" -> "dev"
            else -> "prod"
        }
        when (channel) {
            Channel.TELEGRAM, Channel.LINEAR ->
                return action("connect", json("environment" to environment))?.json?.string("authorizationUrl")?.takeIf { it.startsWith("https://") }
            Channel.WECHAT -> action("start")
            Channel.IMESSAGE -> action("start", json("handle" to handle))
            Channel.SIGNAL -> { signalCode = action("newCode")?.json; scope.changed() }
        }
        return null
    }
}

/** Settings > Task requests: the core's `taskRequests` topic for this Workspace and its calls. */
internal class TaskRequestsModel(scope: WorkspaceScope) {
    val feed = WorkspaceTopic(scope, "taskRequests", json("prefer" to scope.workspaceId), workspaceField = true)
    val scope get() = feed.scope
    var invite: String? = null
        private set
    var linkPreview: JSONObject? = null
        private set
    private var previewedLink = ""
    var invitePreview: JSONObject? = null
        private set
    private var previewedInvite = ""

    fun rows(key: String) = feed.value?.objects(key).orEmpty()
    val grants get() = rows("grants").filter { it.string("status") != "revoked" }

    suspend fun refresh() { scope.perform("taskRequests.refresh", workspaceParameter = false) }

    suspend fun invitePerson(): String? {
        invite = scope.perform("taskRequests.createInvite", json("mode" to "review"))?.json?.string("inviteUrl")
        scope.changed()
        return invite
    }

    suspend fun setMode(grant: String, mode: String) { scope.perform("taskRequests.setMode", json("grant" to grant, "mode" to mode)) }

    suspend fun setOwnAutoAccept(enabled: Boolean) {
        scope.perform("taskRequests.setOwnMode", json("mode" to if (enabled) "auto_accept" else "review"))
    }

    /** What accepting [invitation] in this Workspace gives the inviter; an answer for a link since changed is dropped. */
    suspend fun previewInvitation(invitation: String, current: () -> String) {
        val value = scope.perform("taskRequests.invitePreview", json("invite" to invitation.trim()))
        if (invitation != current()) return
        previewedInvite = invitation
        invitePreview = value?.json
        scope.changed()
    }

    fun invalidateInvitePreview() {
        invitePreview = null
        previewedInvite = ""
    }

    /** Accepted only as previewed, in this Workspace: the inviter may send requests back to it. */
    suspend fun acceptInvitation(invitation: String): Boolean {
        val preview = invitePreview
        if (previewedInvite != invitation || preview == null || preview.optBoolean("own")) return false
        if (scope.perform("taskRequests.acceptInvite", json("invite" to invitation.trim())) == null) return false
        invalidateInvitePreview()
        return true
    }

    /** Previews [link]; an answer for a link the member has since changed is dropped. */
    suspend fun previewLink(link: String, current: () -> String) {
        val value = scope.perform("taskRequests.linkPreview", json("link" to link), workspaceParameter = false)
        if (link != current()) return
        previewedLink = link
        linkPreview = value?.json
        scope.changed()
    }

    fun invalidatePreview() {
        linkPreview = null
        previewedLink = ""
    }

    /** Links the account only when [link] is the one previewed. */
    suspend fun acceptLink(link: String): Boolean {
        if (previewedLink != link || linkPreview == null) return false
        if (scope.perform("taskRequests.acceptLink", json("link" to link), workspaceParameter = false) == null) return false
        invalidatePreview()
        scope.changed()
        return true
    }

    suspend fun send(target: JSONObject, title: String, content: String, key: String): Boolean {
        val grant = target.string("grant_id") ?: return false
        return scope.perform("taskRequests.send", json("grant" to grant, "title" to title, "content" to content, "key" to key)) != null
    }

    companion object {
        /** Whether [target] takes no more requests today, or has too many waiting. */
        fun full(target: JSONObject) = (target.int("sent_today") ?: 0) >= (target.int("daily_limit") ?: 0) ||
            (target.int("pending") ?: 0) >= (target.int("pending_limit") ?: 0)
    }
}
