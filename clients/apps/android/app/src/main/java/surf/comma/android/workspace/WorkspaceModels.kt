package surf.comma.android.workspace

import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.tasks.TaskLabel

/**
 * A Workspace skill. The composer's / menu lists them; a message names one as `/<skill_id>` and tags
 * its [location] in the send's `skills` field, which is what activates it.
 */
data class Skill(val id: String, val name: String, val description: String?, val location: String) {
    companion object {
        /** The server activates at most this many tagged skills in one message. */
        const val MAX_MENTIONS = 10
        private val MENTION = Regex("(^|\\s)/([a-z0-9][a-z0-9_-]*)", RegexOption.IGNORE_CASE)

        fun parse(json: JSONObject): Skill? {
            val id = json.optString("skill_id").takeIf(String::isNotEmpty) ?: return null
            val location = json.optString("location").takeIf(String::isNotEmpty) ?: return null
            return Skill(id, json.optString("name").ifEmpty { id },
                json.optString("description").takeIf { it.isNotEmpty() && it != "null" }, location)
        }

        /** The locations of the catalog skills [text] names, in text order, each once, at most [MAX_MENTIONS]. */
        fun mentionedLocations(text: String, catalog: List<Skill>): List<String> {
            if (catalog.isEmpty() || '/' !in text) return emptyList()
            val byId = catalog.associateBy { it.id.lowercase() }
            val found = mutableListOf<String>()
            for (match in MENTION.findAll(text)) {
                val skill = byId[match.groupValues[2].lowercase()] ?: continue
                if (skill.location !in found && found.size < MAX_MENTIONS) found += skill.location
            }
            return found
        }
    }
}

/**
 * A model the Workspace can run, which the router chat's @ menu offers to start a Task with. [efforts] are the thinking
 * efforts it takes beyond its default; none, it has only the default.
 */
data class MentionModel(val id: String, val name: String, val vendor: String, val efforts: List<String>) {
    companion object {
        /**
         * The models a value of the core's `models` topic lists that some profile serves, in its order; null while the
         * catalog is read, none when the read failed.
         */
        fun fromTopic(value: Any?): List<MentionModel>? {
            val json = value as? JSONObject ?: return null
            if (json.optJSONObject("catalog") == null) return if (json.optBoolean("error")) emptyList() else null
            val models = json.optJSONArray("models") ?: return emptyList()
            return (0 until models.length()).mapNotNull { index ->
                val row = models.optJSONObject(index) ?: return@mapNotNull null
                val id = row.optString("id").takeIf(String::isNotEmpty) ?: return@mapNotNull null
                if (wireStrings(row.optJSONArray("serving")).isEmpty()) return@mapNotNull null
                MentionModel(id, row.optString("name").ifBlank { id }, row.optString("vendor"), wireStrings(row.optJSONArray("efforts")))
            }
        }
    }
}

/** The owner's view of a Task's public share link. */
data class TaskShare(
    val url: String,
    val sharedAt: Long,
    val messageCount: Int,
    val artifactCount: Int,
    /** Messages arrived after the link's cutoff; publishing again moves the cutoff to the latest message. */
    val hasNewerMessages: Boolean,
) {
    companion object {
        fun parse(json: JSONObject): TaskShare? {
            val url = json.optString("url").takeIf { it.startsWith("https://") || it.startsWith("http://") } ?: return null
            return TaskShare(url, json.optLong("shared_at"), json.optInt("message_count"), json.optInt("artifact_count"),
                json.optBoolean("has_newer_messages"))
        }
    }
}

/** A label change an agent proposed. It applies only after a member approves it. */
data class LabelProposal(
    val id: String,
    /** `create`, `update`, `delete` or `apply`. */
    val op: String,
    val summary: String?,
    val labels: List<TaskLabel>,
    val conversationTitle: String?,
)

/** The Group's label catalog, the agent proposals awaiting a member, and the approval policy. */
data class LabelCatalog(
    val labels: List<TaskLabel>,
    val descriptions: Map<String, String>,
    val proposals: List<LabelProposal>,
    /** Preset colour names the server accepts. */
    val colors: List<String>,
    /** `ask` keeps agent proposals pending; `auto` applies them. */
    val approvalPolicy: String,
) {
    companion object {
        fun parse(json: JSONObject): LabelCatalog {
            val labels = json.optJSONArray("labels") ?: throw surf.comma.android.core.CoreError("invalid", "No labels")
            val parsed = objects(labels).mapNotNull { row ->
                val id = row.optString("id").takeIf(String::isNotEmpty) ?: return@mapNotNull null
                val name = row.optString("name").takeIf(String::isNotEmpty) ?: return@mapNotNull null
                Triple(TaskLabel(id, name, row.optString("color").ifEmpty { "gray" }),
                    id, row.optString("description").takeIf { it.isNotEmpty() && it != "null" })
            }.distinctBy { it.second }
            val proposals = objects(json.optJSONArray("proposals")).mapNotNull { row ->
                if (row.optString("status") != "pending") return@mapNotNull null
                val id = row.optString("id").takeIf(String::isNotEmpty) ?: return@mapNotNull null
                val payload = row.optJSONObject("payload")
                LabelProposal(id, row.optString("op"), row.optString("summary").takeIf { it.isNotEmpty() && it != "null" },
                    objects(payload?.optJSONArray("labels")).mapNotNull { label ->
                        label.optString("name").takeIf(String::isNotEmpty)?.let {
                            TaskLabel(label.optString("id"), it, label.optString("color").ifEmpty { "gray" })
                        }
                    },
                    payload?.optString("conversation_title")?.takeIf { it.isNotEmpty() && it != "null" })
            }
            val colors = json.optJSONArray("colors")?.let { array -> (0 until array.length()).map(array::optString) }.orEmpty()
            return LabelCatalog(parsed.map { it.first }, parsed.mapNotNull { (_, id, text) -> text?.let { id to it } }.toMap(),
                proposals, colors.filter(String::isNotEmpty), json.optString("approval_policy").ifEmpty { "ask" })
        }

        private fun objects(array: JSONArray?): List<JSONObject> =
            if (array == null) emptyList() else (0 until array.length()).mapNotNull(array::optJSONObject)
    }
}

/** Server timestamps arrive in seconds or milliseconds; this reads either as milliseconds. */
fun wireMillis(value: Long): Long = if (value in 1 until 100_000_000_000L) value * 1000 else value

/** A wire array's non-blank strings, in order; anything else in it is skipped. */
fun wireStrings(array: JSONArray?): List<String> = if (array == null) emptyList() else
    (0 until array.length()).mapNotNull { (array.opt(it) as? String)?.takeIf(String::isNotBlank) }
