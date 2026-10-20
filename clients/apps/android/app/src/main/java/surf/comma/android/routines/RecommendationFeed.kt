package surf.comma.android.routines

import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary

/**
 * The workspace's Routines briefing as the phone shows it: a summary, a few cards, and the connected
 * sources they come from. Read from `GET /workspaces/:id/recommendations`. Prompt references are
 * resolved here; unknown card templates keep only their server-authored fallback text.
 */
data class RecommendationFeed(
    /** `empty`, `fresh`, `refreshing`, `stale` or `error`. */
    val state: String,
    val sources: List<RecommendationSource> = emptyList(),
    val summary: List<RecommendationPart> = emptyList(),
    val cards: List<RecommendationCard> = emptyList(),
    /** Identifies the snapshot; a new briefing has a new generation. */
    val generation: Long? = null,
) {
    val isRefreshing: Boolean get() = state == "refreshing"
    val hasSnapshot: Boolean get() = generation != null
    /** A source is needed before a refresh can generate anything. */
    val canRefresh: Boolean get() = sources.any { it.enabled }

    /** The summary's prose without the briefing's title, which the server puts first as a paragraph of its own. */
    val summaryBody: List<RecommendationPart>
        get() {
            val first = summary.firstOrNull() as? RecommendationPart.Text ?: return summary
            val split = first.text.indexOf("\n\n")
            if (split < 0) return summary
            val rest = first.text.substring(split + 2)
            return (if (rest.isEmpty()) emptyList() else listOf(RecommendationPart.Text(rest))) + summary.drop(1)
        }

    /** The source a card or chip names: by connection id, else by app id. */
    fun source(id: String?): RecommendationSource? =
        id?.let { key -> sources.firstOrNull { it.connectionId == key || it.appId == key } }

    /** The card's single source, which gives it its logo. A card from several sources has none. */
    fun source(card: RecommendationCard): RecommendationSource? = if (card.sourceIds.size == 1) source(card.sourceIds[0]) else null

    /**
     * Home's platform cards: the briefing's cards in server order, most pressing first, then each enabled
     * source no card names. A disabled source without a card is left out.
     */
    val platforms: List<PlatformRoutine>
        get() {
            val used = mutableSetOf<String>()
            val named = cards.flatMap { it.sourceIds }.mapNotNull { source(it)?.connectionId }.toSet()
            val all = cards.map { card ->
                val source = source(card)
                val id = source?.connectionId?.takeIf(used::add) ?: card.id
                PlatformRoutine(id, source, card)
            } + sources.filter { it.enabled && it.connectionId !in named }.map { PlatformRoutine(it.connectionId, it, null) }
            val repeated = all.groupBy { it.name }.filterValues { it.size > 1 }.keys
            return all.map { if (it.name in repeated) it.copy(connectionLabel = it.source?.label) else it }
        }

    companion object {
        fun parse(root: JSONObject): RecommendationFeed {
            val state = root.optString("state").takeIf(String::isNotEmpty) ?: throw IllegalArgumentException("state")
            val sources = objects(root.optJSONObject("settings")?.optJSONArray("sources")).take(12)
                .mapNotNull(RecommendationSource::parse)
            val snapshot = root.optJSONObject("snapshot") ?: return RecommendationFeed(state, sources)
            val prompts = mutableMapOf<String, String>()
            snapshot.optJSONObject("prompts")?.let { map ->
                for (key in map.keys()) {
                    val prompt = map.optJSONObject(key) ?: continue
                    val objective = prompt.optString("objective").takeIf(String::isNotEmpty) ?: continue
                    val url = prompt.optString("sourceUrl").takeIf(String::isNotEmpty)
                    prompts[key] = if (url != null) "$objective\n\n$url" else objective
                }
            }
            return RecommendationFeed(
                state = state,
                sources = sources,
                summary = RecommendationPart.parse(snapshot.optJSONArray("summary")),
                cards = objects(snapshot.optJSONArray("cards")).take(6).mapNotNull { RecommendationCard.parse(it, prompts) },
                generation = if (snapshot.has("generation") && !snapshot.isNull("generation")) snapshot.optLong("generation") else null,
            )
        }

        internal fun objects(array: JSONArray?): List<JSONObject> =
            if (array == null) emptyList() else (0 until array.length()).mapNotNull(array::optJSONObject)
    }
}

/** A connected app the briefing reads from. */
data class RecommendationSource(
    val connectionId: String,
    val appId: String,
    val appName: String,
    val iconUrl: String? = null,
    val enabled: Boolean = true,
    val needsReconnect: Boolean = false,
    /** The connected account, such as a Slack workspace, which tells two connections of one app apart. */
    val label: String? = null,
) {
    companion object {
        fun parse(json: JSONObject): RecommendationSource? {
            val connection = json.optString("connectionId").takeIf(String::isNotEmpty) ?: return null
            val app = json.optString("appId").takeIf(String::isNotEmpty) ?: return null
            return RecommendationSource(connection, app, json.optString("appName").ifEmpty { app },
                json.optString("iconUrl").takeIf { it.startsWith("https://") }, json.optBoolean("enabled", false),
                json.optBoolean("needsReconnect", false), json.optString("label").takeIf { it.isNotEmpty() && it != "null" })
        }

        /** The provider brand key shared with the desktop logo resolver: lower case, letters and digits only. */
        fun brandKey(value: String?): String? =
            value?.lowercase()?.filter { it in 'a'..'z' || it in '0'..'9' }?.takeIf(String::isNotEmpty)
    }
}

/** One run of briefing prose: text, a source link, or a Task. */
sealed interface RecommendationPart {
    data class Text(val text: String) : RecommendationPart
    data class Link(val label: String, val url: String, val sourceId: String?) : RecommendationPart
    data class Task(val label: String, val conversationId: String, val sourceId: String?) : RecommendationPart

    companion object {
        fun parse(array: JSONArray?): List<RecommendationPart> = RecommendationFeed.objects(array).take(24).mapNotNull { part ->
            when (part.optString("kind")) {
                "markdown" -> part.optString("text").takeIf { part.has("text") }?.let(::Text)
                "inline-link" -> part.optJSONObject("link")?.let { link ->
                    val label = link.optString("label").takeIf(String::isNotEmpty) ?: return@let null
                    val href = link.optString("href").takeIf { it.startsWith("https://") || it.startsWith("http://") } ?: return@let null
                    Link(label, href, link.optString("sourceId").takeIf(String::isNotEmpty))
                }
                "inline-task" -> part.optJSONObject("task")?.let { task ->
                    val label = task.optString("label").takeIf(String::isNotEmpty) ?: return@let null
                    val id = task.optString("conversationId").takeIf(String::isNotEmpty) ?: return@let null
                    Task(label, id, task.optString("sourceId").takeIf(String::isNotEmpty))
                }
                else -> null
            }
        }

        fun plainText(parts: List<RecommendationPart>): String = parts.joinToString("") {
            when (it) {
                is Text -> it.text
                is Link -> it.label
                is Task -> it.label
            }
        }.trim()
    }
}

data class RecommendationCard(
    val id: String,
    val title: String,
    val sourceIds: List<String>,
    val items: List<RecommendationItem>,
    /** The card's text when its template is unknown to this client. */
    val fallbackText: String?,
) {
    companion object {
        fun parse(json: JSONObject, prompts: Map<String, String>): RecommendationCard? {
            val id = json.optString("id").takeIf(String::isNotEmpty) ?: return null
            val title = json.optString("title").takeIf { json.has("title") } ?: return null
            val template = json.optString("template")
            val items = if (template == "text-list@1" || template == "media-list@1")
                RecommendationFeed.objects(json.optJSONArray("items")).take(4).mapNotNull { RecommendationItem.parse(it, prompts) }
            else emptyList()
            val fallback = if (items.isEmpty()) json.optString("fallbackText").takeIf(String::isNotEmpty) else null
            if (items.isEmpty() && fallback == null) return null
            val ids = json.optJSONArray("sourceIds")?.let { array -> (0 until array.length()).map(array::optString) }.orEmpty()
            return RecommendationCard(id, title, ids.filter(String::isNotEmpty), items, fallback)
        }
    }
}

data class RecommendationItem(
    val id: String,
    /** A media item's title; text items carry their prose in [parts]. */
    val title: String?,
    val parts: List<RecommendationPart>,
    val detail: String?,
    val imageUrl: String?,
    val action: RecommendationAction?,
) {
    val text: String get() = RecommendationPart.plainText(parts)

    /** A row that stands for one existing Task opens that Task instead of its source link. */
    val linkedTaskId: String?
        get() {
            if (action !is RecommendationAction.OpenUrl) return null
            val tasks = parts.filterIsInstance<RecommendationPart.Task>()
            return tasks.singleOrNull()?.conversationId
        }

    companion object {
        fun parse(json: JSONObject, prompts: Map<String, String>): RecommendationItem? {
            val id = json.optString("id").takeIf(String::isNotEmpty) ?: return null
            val parts = RecommendationPart.parse(json.optJSONArray("parts"))
            val title = json.optString("title").takeIf(String::isNotEmpty)
            if (title == null && parts.isEmpty()) return null
            return RecommendationItem(id, title, parts, json.optString("description").takeIf(String::isNotEmpty),
                json.optString("imageUrl").takeIf { it.startsWith("https://") },
                RecommendationAction.parse(json.optJSONObject("action"), prompts))
        }
    }
}

/** What tapping a recommendation does. A prompt goes into the composer; the member still sends it. */
sealed interface RecommendationAction {
    val label: String

    data class OpenUrl(val url: String, override val label: String) : RecommendationAction

    /** [memberTask]: the prompt is the member's own task, which the composer turns into a request for help. */
    data class Prompt(val prompt: String, override val label: String, val memberTask: Boolean) : RecommendationAction

    companion object {
        fun parse(json: JSONObject?, prompts: Map<String, String>): RecommendationAction? {
            val label = json?.optString("label")?.takeIf(String::isNotEmpty) ?: return null
            return when (val type = json.optString("type")) {
                "open_url" -> json.optString("href").takeIf { it.startsWith("https://") || it.startsWith("http://") }
                    ?.let { OpenUrl(it, label) }
                "open_task_form", "send_to_comma" -> {
                    val referenced = json.optString("promptId").takeIf(String::isNotEmpty)?.let(prompts::get)
                    val prompt = json.optString("prompt").takeIf(String::isNotEmpty) ?: referenced
                    if (prompt.isNullOrBlank()) return null
                    Prompt(prompt, label, type == "send_to_comma" && (referenced != null || json.optBoolean("memberTask")))
                }
                else -> null
            }
        }
    }
}

/**
 * One platform card on Home: a connected app's briefing card, or an enabled app the briefing has nothing
 * from yet. Two connections of the same app are two platforms.
 */
data class PlatformRoutine(
    val id: String,
    val source: RecommendationSource?,
    val card: RecommendationCard?,
    /** The connected account, set only when another platform shows the same name, to tell the two apart. */
    val connectionLabel: String? = null,
) {
    val name: String get() = source?.appName ?: card?.title.orEmpty()

    /** The name a sheet heads the platform with: its account too when two platforms share the name. */
    val heading: String get() = connectionLabel?.let { "$name · $it" } ?: name

    /** The card's items the member can still act on. A row standing for one Task shows only while that Task is open. */
    fun preTasks(task: (String) -> TaskSummary?): List<RecommendationItem> =
        card?.items.orEmpty().filter { item -> item.linkedTaskId?.let { isOpen(task(it)) } ?: true }

    /** Whether the platform has anything for a sheet to draw: pre-tasks, or the card's own words. */
    fun hasPreTasks(task: (String) -> TaskSummary?): Boolean = card?.fallbackText != null || preTasks(task).isNotEmpty()

    companion object {
        /**
         * A Task this client does not know counts as ended, as on the desktop and iOS; otherwise it is open unless its
         * status ended its run, which includes one ready for review. Without a status, its section says instead.
         */
        fun isOpen(task: TaskSummary?): Boolean {
            if (task == null || task.isArchived) return false
            if (task.status.isEmpty()) return task.bucket == TaskStatusBucket.IN_PROGRESS
            return task.status !in ENDED_STATUSES
        }

        private val ENDED_STATUSES = setOf("completed", "cancelled", "archived", "ready_for_review")
    }
}
