package surf.comma.android.people

import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.json.JSONObject
import surf.comma.android.core.TopicValue
import surf.comma.android.settings.desktop.TaskRequestsModel
import surf.comma.android.settings.desktop.WorkspaceScope
import surf.comma.android.settings.desktop.int
import surf.comma.android.settings.desktop.json
import surf.comma.android.settings.desktop.objects
import surf.comma.android.settings.desktop.string
import surf.comma.android.tasks.TaskSummary
import java.text.Collator

/** A person of People, as the core's `taskRequests` topic lists them (`people`). Nothing of it is stored. */
internal data class PeoplePerson(
    val id: String,
    val name: String,
    val email: String?,
    /** Where their avatar is read (a `files.read` source), when they have one. */
    val avatar: JSONObject?,
    /** Their grant to send requests to the workspace, and how the workspace takes them (`review`, `auto_accept`). */
    val sendsGrant: String?,
    val sendsMode: String,
    /** The grant of a workspace of theirs the member may send a request to now; null when they take none. */
    val requestGrant: String?,
) {
    companion object {
        fun of(contact: JSONObject): PeoplePerson? {
            val id = contact.string("id") ?: return null
            val email = contact.string("email")
            val sends = contact.optJSONObject("sends")
            val receives = contact.objects("receives")
            return PeoplePerson(
                id = id,
                name = contact.string("name") ?: email.orEmpty(),
                email = email,
                avatar = contact.optJSONObject("avatar"),
                sendsGrant = sends?.string("grant"),
                sendsMode = sends?.string("mode") ?: "review",
                requestGrant = (receives.firstOrNull { !it.optBoolean("full") } ?: receives.firstOrNull())?.string("grant"),
            )
        }
    }
}

/** A Collaborative Task another person hosts, as one of its people sees it (`collaborations`). */
internal data class PeopleCollaboration(
    val id: String,
    val invited: Boolean,
    val title: String,
    val taskId: String,
    val groupId: String,
    val hostId: String?,
    val hostName: String,
    /** Everyone else still in it (invited or joined), by name. */
    val memberNames: List<String>,
    val memberIds: List<String>,
    val members: List<Pair<String?, String>> = emptyList(),
    /** Where the host's and members' avatars are read (`files.read` sources, as JSON), by user id. */
    val avatars: Map<String, String> = emptyMap(),
    /** Seconds. */
    val invitedAt: Long?,
) {
    fun includes(person: String) = hostId == person || person in memberIds

    companion object {
        fun of(item: JSONObject, self: String?): PeopleCollaboration? {
            val id = item.string("id") ?: return null
            val task = item.optJSONObject("task") ?: return null
            val host = item.optJSONObject("host")
            val members = item.objects("members").filter { it.string("status") in setOf("invited", "active") }
                .mapNotNull { it.optJSONObject("person") }.filter { it.string("id") != self }
            return PeopleCollaboration(
                id = id,
                invited = item.string("status") == "invited",
                title = item.optString("title"),
                taskId = task.string("id") ?: return null,
                groupId = task.string("group_id") ?: return null,
                hostId = host?.string("id"),
                hostName = host?.string("name") ?: host?.string("email").orEmpty(),
                memberNames = members.mapNotNull { it.string("name") ?: it.string("email") },
                memberIds = members.mapNotNull { it.string("id") },
                members = members.mapNotNull { m ->
                    val name = m.string("name") ?: m.string("email") ?: return@mapNotNull null
                    m.string("id") to name
                },
                avatars = (listOfNotNull(host) + members).mapNotNull { person ->
                    val id = person.string("id") ?: return@mapNotNull null
                    person.optJSONObject("avatar")?.let { id to it.toString() }
                }.toMap(),
                invitedAt = item.int("invited_at"),
            )
        }
    }
}

/**
 * People: the account's People (the selected workspace's `taskRequests` topic) and the Collaborative Tasks it was
 * invited to or joined (`collaborations`), for one page scope; the scope retires with the account or workspace.
 */
internal class PeopleModel(val scope: WorkspaceScope, private val self: String?) {
    val requests = TaskRequestsModel(scope)
    var collaborations: List<PeopleCollaboration> = emptyList()
        private set
    var collaborationsLoaded = false
        private set

    val loaded: Boolean get() = requests.feed.loaded && requests.feed.value?.optJSONArray("people") != null

    /** Everyone, by name. */
    val people: List<PeoplePerson>
        get() {
            val collator = Collator.getInstance()
            return requests.rows("people").mapNotNull(PeoplePerson::of).sortedWith { a, b -> collator.compare(a.name, b.name) }
        }

    fun person(id: String) = people.firstOrNull { it.id == id }

    /**
     * Everyone this model can show, by user id: People first (with their avatar), then the Tasks together they host or
     * are in (desktop `usePersonName`).
     */
    fun faces(): Map<String, surf.comma.android.chat.live.WriterFace> {
        val out = HashMap<String, surf.comma.android.chat.live.WriterFace>()
        for (item in collaborations) {
            item.hostId?.let { id ->
                if (item.hostName.isNotBlank()) out[id] = surf.comma.android.chat.live.WriterFace(item.hostName, item.avatars[id])
            }
            for ((id, name) in item.members)
                if (id != null && id !in out) out[id] = surf.comma.android.chat.live.WriterFace(name, item.avatars[id])
        }
        for (person in people) if (person.name.isNotBlank())
            out[person.id] = surf.comma.android.chat.live.WriterFace(person.name, person.avatar?.toString())
        return out
    }

    /** Follows both lists while the page shows; each is read again as it opens (no client is told of a change). */
    fun follow(): List<Job> = listOf(requests.feed.follow { scope.changed() }, followCollaborations())

    /** Only the invitations and memberships, as the Inbox shows them. */
    fun followCollaborations(): Job = scope.work.launch {
        launch { runCatching { scope.call("collaborations.refresh", workspaceParameter = false) } }
        scope.core.subscribe(JSONObject().put("topic", "collaborations")) { it }.collect { update ->
            if (!scope.current || update !is TopicValue.Value) return@collect
            val items = (update.value as? JSONObject)?.objects("items") ?: return@collect
            collaborations = items.mapNotNull { PeopleCollaboration.of(it, self) }
            collaborationsLoaded = true
            scope.changed()
        }
    }

    suspend fun refresh() {
        requests.refresh()
        runCatching { scope.call("collaborations.refresh", workspaceParameter = false) }
    }

    /** Joins or declines an invitation. */
    suspend fun answer(item: PeopleCollaboration, join: Boolean): Boolean =
        scope.perform("collaborations.answer", json("id" to item.id, "answer" to if (join) "accept" else "decline"),
            workspaceParameter = false) != null

    fun hostedTasks(tasks: List<TaskSummary>, person: String) = tasks.filter { person in it.together }

    fun joinedTasks(person: String) = collaborations.filter { it.includes(person) }

    /** Requests either sent the other's Comma: theirs to the workspace, the member's to theirs; the latest first. */
    fun requestsWith(person: String): List<Pair<JSONObject, Boolean>> {
        val incoming = requests.rows("received").filter { it.optJSONObject("sender")?.string("id") == person }.map { it to true }
        val sent = requests.rows("sent").filter {
            it.optJSONObject("workspace")?.optJSONObject("owner")?.string("id") == person
        }.map { it to false }
        return (incoming + sent).sortedByDescending { it.first.int("created_at") ?: 0 }
    }

    /** Where the member's requests to [person] go: their row of `targets`. */
    fun target(person: PeoplePerson): JSONObject? {
        val grant = person.requestGrant ?: return null
        return requests.rows("targets").firstOrNull { it.string("grant_id") == grant }
    }
}

/** A page scope of the signed-in account and its selected workspace, for a page outside Settings; null while there is none. */
internal fun peopleScope(activity: androidx.activity.ComponentActivity): WorkspaceScope? {
    val core = surf.comma.android.auth.AuthGraph.core(activity) ?: return null
    val sessions = surf.comma.android.conversation.AuthConversationSessions(surf.comma.android.auth.AuthGraph.get(activity))
    val session = sessions.scopes.value?.takeIf { it.workspaceId.isNotEmpty() } ?: return null
    return WorkspaceScope(core, sessions, session, activity.lifecycleScope)
}

/**
 * Names the other people writing in an open conversation, for its rows ([MessageWriters]). People is read only once
 * another person has written there, and stops with [close]; [changed] asks the page to show the names it read.
 */
internal class ConversationWriters(
    private val activity: androidx.activity.ComponentActivity,
    private val changed: () -> Unit,
) {
    private var model: PeopleModel? = null

    private val self: String?
        get() = (surf.comma.android.auth.AuthGraph.get(activity).state.value as? surf.comma.android.auth.AuthState.Connected)
            ?.account?.id

    /**
     * Who wrote each message of [timeline], as the names read so far; in a [task], every left-side row shows its
     * speaker. Called on the main thread.
     */
    fun writers(timeline: List<surf.comma.android.conversation.TimelineEntry>, task: Boolean): surf.comma.android.chat.live.MessageWriters {
        val self = self
        val faces = model?.faces().orEmpty()
        val writers = surf.comma.android.chat.live.MessageWriters(self, task) { faces[it] }
        if (model == null && timeline.any { it is surf.comma.android.conversation.TimelineEntry.Message && writers.other(it.message) != null }) {
            model = peopleScope(activity)?.let { scope ->
                PeopleModel(scope, self).also { model ->
                    scope.onChange(changed)
                    model.follow()
                }
            }
        }
        return writers
    }

    fun close() {
        model?.scope?.close()
        model = null
    }
}
