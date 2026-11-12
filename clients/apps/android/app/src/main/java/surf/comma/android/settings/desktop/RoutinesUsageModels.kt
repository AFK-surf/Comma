package surf.comma.android.settings.desktop

import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.core.TopicValue
import surf.comma.android.routines.RecommendationSource
import java.time.Instant
import java.util.TimeZone

/**
 * Settings > Routines: the briefing schedule and sources from one read of the `recommendations` topic (at most 12
 * sources; Home keeps its own polling), and the owner's proactive messages. Each save changes one setting.
 */
internal class RoutinesSettingsModel(val scope: WorkspaceScope, private val timezone: () -> String = { TimeZone.getDefault().id }) {
    var settings: JSONObject? = null
        private set
    var sources: List<RecommendationSource> = emptyList()
        private set
    var loaded = false
        private set
    /** `ready`, `owner-only`, `failed`, or null while it loads. */
    var proactive: JSONObject? = null
        private set

    val schedule get() = settings?.optJSONObject("schedule")
    val enabled get() = schedule?.optBoolean("enabled") == true
    val autoEnable get() = settings?.optBoolean("autoEnableNewSources") == true
    val zone get() = schedule?.string("timezone") ?: timezone()
    val hour get() = schedule?.int("hour")?.toInt() ?: 8
    val minute get() = schedule?.int("minute")?.toInt() ?: 0

    fun follow(): Job = scope.work.launch {
        val topic = json("topic" to "recommendations", "workspace" to scope.workspaceId, "timezone" to timezone(), "reads" to "once")
        scope.core.subscribe(topic) { it }.collect { update ->
            if (!scope.current) return@collect
            val value = (update as? TopicValue.Value)?.value as? JSONObject
            val envelope = value?.optJSONObject("envelope")
            val next = envelope?.optJSONObject("settings")
            when {
                next != null -> {
                    settings = next
                    sources = next.objects("sources").take(MAX_SOURCES).mapNotNull(RecommendationSource::parse)
                    loaded = true
                    scope.changed()
                }
                update is TopicValue.Failed || value?.string("failure") == "unavailable" -> {
                    loaded = true
                    scope.error = PageError.Text(R.string.ds_routines_load_failed)
                }
            }
        }
    }

    fun followProactive(): Job = scope.work.launch {
        scope.core.subscribe(json("topic" to "proactive", "prefer" to scope.workspaceId)) { it }.collect { update ->
            if (!scope.current) return@collect
            val value = (update as? TopicValue.Value)?.value as? JSONObject
            proactive = when {
                value == null -> json("kind" to "failed")
                value.string("kind") == "ready" && value.string("groupId") != scope.groupId -> json("kind" to "failed")
                else -> value
            }
            scope.changed()
        }
    }

    suspend fun save(patch: JSONObject) { scope.perform("recommendations.updateSettings", json("patch" to patch)) }

    suspend fun setSchedule(enabled: Boolean? = null, hour: Int? = null, minute: Int? = null) {
        val schedule = schedule ?: return
        save(json("schedule" to json("enabled" to (enabled ?: this.enabled),
            "hour" to (hour ?: schedule.int("hour")?.toInt() ?: 8), "minute" to (minute ?: schedule.int("minute")?.toInt() ?: 0),
            "timezone" to timezone())))
    }

    suspend fun setSource(source: RecommendationSource, enabled: Boolean) =
        save(json("sources" to JSONArray().put(json("connectionId" to source.connectionId, "enabled" to enabled))))

    suspend fun setProactive(enabled: Boolean) {
        val value = proactive ?: return
        if (value.string("kind") != "ready" || value.string("groupId") != scope.groupId) return
        scope.perform("proactive.set", json("prefer" to scope.workspaceId, "enabled" to enabled), workspaceParameter = false)
    }

    suspend fun refresh() { scope.perform("recommendations.visit") }

    private companion object { const val MAX_SOURCES = 12 }
}

/** Settings > Usage: the core's billing projection for this Workspace. It never starts checkout. */
internal class UsageModel(val scope: WorkspaceScope) {
    var value: JSONObject = json("status" to "loading")
        private set

    val status get() = value.string("status") ?: "loading"
    val summary get() = value.optJSONObject("summary")
    val subscription get() = summary?.optJSONObject("active_subscription")
    val usage get() = value.optJSONObject("planUsage")
    val allowance get() = value.optJSONObject("allowance")
    val credits get() = summary?.int("current_credits") ?: 0
    val unlimited get() = value.optBoolean("unlimited")
    val grants get() = summary?.objects("active_grants").orEmpty()

    /** The plan's name, or null without a subscription; an unnamed plan is "". */
    val planName: String?
        get() {
            val subscription = subscription ?: return null
            return subscription.optJSONObject("plan")?.string("name") ?: value.objects("plans").firstOrNull {
                it.string("package_code") == subscription.string("package_code") &&
                    it.string("package_version") == subscription.string("package_version")
            }?.string("name") ?: ""
        }

    fun follow(): Job = scope.work.launch {
        scope.core.subscribe(json("topic" to "billing", "prefer" to scope.workspaceId)) { it }.collect { update ->
            if (!scope.current) return@collect
            val next = (update as? TopicValue.Value)?.value as? JSONObject
            value = when {
                next == null -> json("status" to "unavailable")
                next.string("status") == "ready" && next.optJSONObject("workspace")?.string("id") != scope.workspaceId ->
                    json("status" to "unavailable")
                else -> next
            }
            scope.changed()
        }
    }

    suspend fun refresh() { scope.perform("billing.refresh") }

    companion object {
        fun date(text: String?): Instant? = text?.let { runCatching { Instant.parse(it) }.getOrNull() }
    }
}
