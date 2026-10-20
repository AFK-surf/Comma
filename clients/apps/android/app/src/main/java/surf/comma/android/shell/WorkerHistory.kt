package surf.comma.android.shell

import android.content.res.ColorStateList
import android.text.format.DateFormat
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import androidx.activity.ComponentActivity
import androidx.core.graphics.ColorUtils
import androidx.core.view.isVisible
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.ui.kit.CommaSheet
import surf.comma.android.ui.kit.EmptyStateView
import surf.comma.android.ui.kit.Row
import surf.comma.android.ui.kit.RowsAdapter
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.rounded
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.workspace.WorkspaceStore
import java.time.Instant

/** A Worker step as the phone shows it: what the Worker read, said, or ran, and how a tool call ended. */
data class WorkerHistoryItem(val id: String, var kind: Kind, var tool: String?, var summary: String, val startedAt: Long?) {
    enum class Kind { INPUT, MODEL, THINKING, CALL, RUNNING, SUCCESS, FAILURE, CANCELLED, RESULT }
}

/**
 * A Worker's session ledger projected into readable steps, as the desktop and the iOS app do. Tool lifecycle
 * records join their call only by explicit call id; context, system and runtime bookkeeping records are not shown.
 */
object WorkerHistory {
    data class Record(val id: String, val kind: String, val content: Any?, val inputText: String?, val startedAt: Long?,
                      val executionId: String?, val lane: String?)

    fun records(page: JSONObject): List<Record> {
        val array = page.optJSONArray("records") ?: return emptyList()
        return (0 until array.length()).mapNotNull { index ->
            val row = array.optJSONObject(index) ?: return@mapNotNull null
            val id = row.optString("id").takeIf(String::isNotEmpty) ?: return@mapNotNull null
            val execution = row.optJSONObject("execution")
            val ms = execution?.optDouble("started_at_ms")?.takeIf { !it.isNaN() } ?: row.optDouble("timestamp_ms").takeIf { !it.isNaN() }
            val started = ms?.toLong() ?: when (val created = row.opt("created_at")) {
                is Number -> created.toLong().let { if (it < 100_000_000_000L) it * 1000 else it }
                is String -> runCatching { Instant.parse(created).toEpochMilli() }.getOrNull()
                else -> null
            }
            Record(id, row.optString("kind"), row.opt("content"), row.optString("input_text").takeIf { row.has("input_text") && it.isNotEmpty() },
                started, execution?.optString("id")?.takeIf(String::isNotEmpty), execution?.optString("lane")?.takeIf(String::isNotEmpty))
        }
    }

    fun items(records: List<Record>): List<WorkerHistoryItem> {
        val items = mutableListOf<WorkerHistoryItem>()
        val calls = mutableMapOf<String, Int>()
        for (record in records) {
            val content = obj(record.content)
            when (record.kind) {
                "user" -> {
                    val summary = text(record.inputText ?: content?.opt("content") ?: record.content)
                    if (summary.isNotEmpty()) items += WorkerHistoryItem(record.id, WorkerHistoryItem.Kind.INPUT, null, summary, record.startedAt)
                }
                "assistant" -> {
                    val prose = text(content?.opt("content") ?: record.content)
                    val toolCalls = toolCalls(content?.opt("tool_calls"))
                    if (prose.isNotEmpty()) items += WorkerHistoryItem(record.id, WorkerHistoryItem.Kind.MODEL, null, prose, record.startedAt)
                    else if (toolCalls.isEmpty()) {
                        val reasoning = text(content?.opt("reasoning") ?: content?.opt("reasoning_content"))
                        if (reasoning.isNotEmpty()) items += WorkerHistoryItem(record.id, WorkerHistoryItem.Kind.THINKING, null, reasoning, record.startedAt)
                    }
                    for (call in toolCalls) {
                        if (call.id.isNotEmpty() && calls[call.id] != null) {
                            val index = calls.getValue(call.id)
                            items[index].tool = items[index].tool ?: call.name
                            continue
                        }
                        if (call.id.isNotEmpty()) calls[call.id] = items.size
                        items += WorkerHistoryItem("tool:" + call.id.ifEmpty { record.id + call.name }, WorkerHistoryItem.Kind.CALL,
                            call.name, argumentSummary(call.args), record.startedAt)
                    }
                }
                "summary", "system", "developer", "runtime", "runtime.event" -> Unit
                else -> {
                    val (callId, item) = toolItem(record) ?: continue
                    val index = callId?.let(calls::get)
                    if (index != null) {
                        val existing = items[index]
                        if (item.kind == WorkerHistoryItem.Kind.RUNNING && existing.kind != WorkerHistoryItem.Kind.CALL &&
                            existing.kind != WorkerHistoryItem.Kind.RUNNING) continue
                        existing.kind = item.kind
                        existing.tool = item.tool ?: existing.tool
                        if (item.summary.isNotEmpty() && (item.kind != WorkerHistoryItem.Kind.RUNNING || existing.summary.isEmpty())) existing.summary = item.summary
                    } else {
                        if (callId != null) calls[callId] = items.size
                        items += item
                    }
                }
            }
        }
        return items
    }

    private fun toolItem(record: Record): Pair<String?, WorkerHistoryItem>? {
        val content = obj(record.content) ?: JSONObject()
        val data = JSONObject(content.toString())
        obj(decoded(content.opt("content") ?: record.content))?.let { merge(data, it) }
        content.optJSONObject("event")?.let { merge(data, it) }
        val result = obj(decoded(data.opt("result"))) ?: JSONObject()
        val payload = obj(decoded(result.opt("content") ?: data.opt("content"))) ?: JSONObject()
        val eventType = text(data.opt("type")).ifEmpty { record.kind }
        val status = listOf(data.opt("status"), data.opt("state"), result.opt("status"), payload.opt("status")).map(::text).firstOrNull { it.isNotEmpty() }.orEmpty()
        val failed = listOf(data, result, payload).any {
            it.optBoolean("is_error") || it.opt("error") == true || text(it.opt("error_message")).isNotEmpty() || (it.opt("error") as? String)?.isNotEmpty() == true
        }
        val isTool = record.kind == "tool" || record.kind.startsWith("session.async_tool_call_") || record.lane == "tool" || eventType.startsWith("tool_call_")
        if (record.kind.startsWith("session.") && !isTool) return null
        val callId = listOf(data.opt("tool_call_id"), result.opt("id")).map(::text).firstOrNull { it.isNotEmpty() } ?: if (isTool) record.executionId else null
        val tool = listOf(data.opt("tool_name"), result.opt("name"), data.opt("name")).map(::text).firstOrNull { it.isNotEmpty() }
        val kind = when {
            failed || eventType.endsWith("error") || eventType.endsWith("failed") || status in setOf("failed", "error") -> WorkerHistoryItem.Kind.FAILURE
            eventType.endsWith("cancelled") || status in setOf("cancelled", "canceled") -> WorkerHistoryItem.Kind.CANCELLED
            (eventType.contains("tool") && (eventType.endsWith("started") || eventType.endsWith("progress"))) ||
                status in setOf("running", "pending", "in_progress", "waiting") -> WorkerHistoryItem.Kind.RUNNING
            (eventType.contains("tool") && eventType.endsWith("completed")) || status in setOf("completed", "success", "succeeded") -> WorkerHistoryItem.Kind.SUCCESS
            isTool -> WorkerHistoryItem.Kind.RESULT
            else -> return null
        }
        val summary = when (kind) {
            WorkerHistoryItem.Kind.FAILURE -> listOf(data.opt("error_message"), result.opt("error_message"), payload.opt("error_message"),
                data.opt("error"), result.opt("error"), data.opt("message")).map(::text).firstOrNull { it.isNotEmpty() }.orEmpty()
            WorkerHistoryItem.Kind.CANCELLED -> text(data.opt("cancel_reason") ?: data.opt("message"))
            WorkerHistoryItem.Kind.RUNNING -> text(data.opt("progress"))
            else -> text(data.opt("output") ?: result.opt("content") ?: data.opt("result"))
        }
        return callId?.takeIf(String::isNotEmpty) to WorkerHistoryItem(record.id, kind, tool, summary, record.startedAt)
    }

    private data class ToolCall(val id: String, val name: String, val args: JSONObject)

    private fun toolCalls(value: Any?): List<ToolCall> {
        val array = value as? JSONArray ?: return emptyList()
        return (0 until array.length()).map { index ->
            val call = array.optJSONObject(index) ?: JSONObject()
            val function = call.optJSONObject("function") ?: JSONObject()
            val args = obj(decoded(call.opt("args") ?: call.opt("arguments") ?: function.opt("arguments"))) ?: JSONObject()
            val name = text(call.opt("name") ?: function.opt("name"))
            if (name == "call") ToolCall(text(call.opt("id")), text(args.opt("tool")).ifEmpty { name }, args.optJSONObject("params") ?: JSONObject())
            else ToolCall(text(call.opt("id")), name, args)
        }
    }

    private fun argumentSummary(args: JSONObject): String =
        listOf("description", "content", "query", "command", "path", "url", "title").map { text(args.opt(it)) }.firstOrNull { it.isNotEmpty() }.orEmpty()

    private fun merge(into: JSONObject, from: JSONObject) { for (key in from.keys()) into.put(key, from.opt(key)) }

    private fun obj(value: Any?): JSONObject? = value as? JSONObject

    /** Tool arguments and results sometimes arrive as JSON text. */
    private fun decoded(value: Any?): Any? {
        val text = value as? String ?: return value
        val first = text.firstOrNull() ?: return value
        if (first != '{' && first != '[') return value
        return runCatching { if (first == '{') JSONObject(text) else JSONArray(text) }.getOrDefault(value)
    }

    private const val SUMMARY_LIMIT = 600

    private fun text(value: Any?): String {
        val raw = when (value) {
            is String -> value
            is JSONArray -> (0 until minOf(8, value.length())).mapNotNull { value.optJSONObject(it)?.optString("text")?.takeIf(String::isNotEmpty) }
                .joinToString("\n")
            else -> ""
        }.trim()
        return if (raw.length > SUMMARY_LIMIT) raw.take(SUMMARY_LIMIT) + "…" else raw
    }
}

/**
 * What the Task's Worker read, said and ran, from its session ledger: the core's `history` topic, the latest page on
 * open and older pages on request, with what the Worker does while the sheet is up.
 */
class WorkerHistorySheet(
    activity: ComponentActivity,
    private val store: WorkspaceStore,
    private val taskId: String,
    private val worker: BoundWorker,
) : CommaSheet(activity, worker.name.ifEmpty { activity.getString(R.string.task_details_worker) }, Detent.LARGE) {
    private val adapter = RowsAdapter()
    private val list = RecyclerView(activity).apply {
        layoutManager = LinearLayoutManager(activity)
        adapter = this@WorkerHistorySheet.adapter
        clipToPadding = false
        setPadding(activity.dp(16), 0, activity.dp(16), activity.dp(24))
    }
    private val empty = EmptyStateView(activity).apply { isVisible = false }
    private var items = emptyList<WorkerHistoryItem>()
    private var shownRecords: Any? = null
    private var hasMore = false
    private var loading = true
    private var loaded = false
    private var error: String? = null
    private var first = true
    private val group = store.tasks.state.value.groupId
    private var following: kotlinx.coroutines.Job? = null

    init {
        setContent(FrameLayout(activity).apply { addView(list); addView(empty) })
        follow()
    }

    /** Shows the Worker's history to the core: the latest page, then what the Worker does while the sheet is up. */
    private fun follow() {
        val group = group ?: return
        val core = surf.comma.android.auth.AuthGraph.core(activity) ?: return
        val topic = JSONObject().put("topic", "history").put("group", group).put("conversation", taskId)
            .put("participant", worker.participantId)
        following = activity.lifecycleScope.launch {
            launch { load("latest") }
            core.subscribe(topic) { it as? JSONObject }.collect { value ->
                val json = (value as? surf.comma.android.core.TopicValue.Value)?.value ?: return@collect
                val records = json.optJSONArray("records")
                if (records !== shownRecords) {
                    shownRecords = records
                    val read = WorkerHistory.records(JSONObject().put("records", records ?: JSONArray()))
                    items = withContext(Dispatchers.Default) { WorkerHistory.items(read) }
                }
                hasMore = json.optBoolean("hasMore")
                val status = json.optString("status")
                loading = status == "loading"
                loaded = loaded || status == "ready" || status == "error"
                error = when (json.optString("error")) {
                    "forbidden" -> activity.getString(R.string.history_forbidden)
                    "unavailable" -> activity.getString(R.string.app_failure_generic)
                    else -> null
                }
                render()
                if (first && items.isNotEmpty()) {
                    first = false
                    list.post { list.scrollToPosition(maxOf(0, adapter.itemCount - 1)) }
                }
            }
        }
    }

    private suspend fun load(mode: String) {
        val group = group ?: return
        try {
            surf.comma.android.auth.AuthGraph.core(activity)?.call("history.load", JSONObject().put("group", group)
                .put("conversation", taskId).put("participant", worker.participantId).put("mode", mode))
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (_: Exception) {
            // The topic says why the read failed.
        }
    }

    private fun loadOlder() {
        if (loading || !hasMore) return
        loading = true
        render()
        activity.lifecycleScope.launch { load("older") }
    }

    override fun onRemoved() {
        following?.cancel()
    }

    private fun render() {
        val rows = mutableListOf<Row>()
        if (hasMore) rows += Row("earlier", 0, loading, create = {
            activity.label(Level.SMALL, R.color.token_bg_brand_solid, DesignFonts.semibold).apply {
                setText(R.string.history_earlier)
                gravity = Gravity.CENTER
                minHeight = activity.dp(44)
                setOnClickListener { loadOlder() }
            }
        }) { it.alpha = if (loading) 0.4f else 1f }
        items.forEach { item -> rows += Row(item.id, 1, item.copy(), create = { stepRow() }) { bindStep(it as LinearLayout, item) } }
        error?.let { message ->
            rows += Row("error", 2, message, create = {
                activity.label(Level.SMALL, R.color.token_text_error_primary, lines = 0).apply { setPadding(0, activity.dp(12), 0, activity.dp(12)) }
            }) { (it as android.widget.TextView).text = message }
        }
        adapter.show(rows)
        empty.isVisible = loaded && items.isEmpty() && error == null
        empty.show(R.drawable.ic_history, activity.getString(R.string.history_empty))
    }

    private fun stepRow() = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        setPadding(0, activity.dp(6), 0, activity.dp(6))
        addView(FrameLayout(activity).apply {
            addView(ImageView(activity), FrameLayout.LayoutParams(activity.dp(14), activity.dp(14), Gravity.CENTER))
        }, LinearLayout.LayoutParams(activity.dp(24), activity.dp(24)))
        addView(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = activity.dp(24)
                addView(activity.label(Level.SMALL, R.color.token_text_secondary, DesignFonts.semibold))
                addView(activity.label(Level.MINI, R.color.token_text_quaternary).apply { typeface = android.graphics.Typeface.MONOSPACE },
                    LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = activity.dp(6) })
                addView(activity.label(Level.MINI, R.color.token_text_placeholder))
            })
            addView(activity.label(Level.SMALL, R.color.token_text_primary, lines = 12).apply { setTextIsSelectable(true) },
                LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(3) })
        }, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = activity.dp(10) })
    }

    private fun bindStep(row: LinearLayout, item: WorkerHistoryItem) {
        val badge = row.getChildAt(0) as FrameLayout
        val icon = badge.getChildAt(0) as ImageView
        val words = row.getChildAt(1) as LinearLayout
        val line = words.getChildAt(0) as LinearLayout
        val title = line.getChildAt(0) as android.widget.TextView
        val tool = line.getChildAt(1) as android.widget.TextView
        val time = line.getChildAt(2) as android.widget.TextView
        val summary = words.getChildAt(1) as android.widget.TextView
        val tint = activity.getColor(when (item.kind) {
            WorkerHistoryItem.Kind.FAILURE -> R.color.token_text_error_primary
            WorkerHistoryItem.Kind.SUCCESS -> R.color.token_fg_success
            WorkerHistoryItem.Kind.MODEL, WorkerHistoryItem.Kind.INPUT -> R.color.token_bg_brand_solid
            else -> R.color.token_text_quaternary
        })
        badge.background = rounded(ColorUtils.setAlphaComponent(tint, 31), activity.dp(12).toFloat())
        icon.setImageResource(when (item.kind) {
            WorkerHistoryItem.Kind.INPUT -> R.drawable.ic_history_input
            WorkerHistoryItem.Kind.MODEL -> R.drawable.ic_history_reply
            WorkerHistoryItem.Kind.THINKING -> R.drawable.ic_history_thinking
            WorkerHistoryItem.Kind.CALL, WorkerHistoryItem.Kind.RESULT -> R.drawable.ic_history_tool
            WorkerHistoryItem.Kind.RUNNING -> R.drawable.ic_action_more
            WorkerHistoryItem.Kind.SUCCESS -> R.drawable.ic_action_check
            WorkerHistoryItem.Kind.FAILURE -> R.drawable.ic_warning_triangle
            WorkerHistoryItem.Kind.CANCELLED -> R.drawable.ic_action_cross_small
        })
        icon.imageTintList = ColorStateList.valueOf(tint)
        title.setText(when (item.kind) {
            WorkerHistoryItem.Kind.INPUT -> R.string.history_received
            WorkerHistoryItem.Kind.MODEL -> R.string.history_replied
            WorkerHistoryItem.Kind.THINKING -> R.string.history_thought
            WorkerHistoryItem.Kind.CALL -> R.string.history_called
            WorkerHistoryItem.Kind.RUNNING -> R.string.history_running
            WorkerHistoryItem.Kind.SUCCESS -> R.string.history_finished
            WorkerHistoryItem.Kind.FAILURE -> R.string.history_failed
            WorkerHistoryItem.Kind.CANCELLED -> R.string.history_cancelled
            WorkerHistoryItem.Kind.RESULT -> R.string.history_result
        })
        tool.text = item.tool
        tool.isVisible = !item.tool.isNullOrEmpty()
        time.text = item.startedAt?.let { DateFormat.getTimeFormat(activity).format(java.util.Date(it)) }
        time.isVisible = item.startedAt != null
        summary.text = item.summary
        summary.isVisible = item.summary.isNotEmpty()
        summary.setTextColor(activity.getColor(if (item.kind == WorkerHistoryItem.Kind.THINKING) R.color.token_text_quaternary else R.color.token_text_primary))
        summary.maxLines = if (item.kind == WorkerHistoryItem.Kind.MODEL || item.kind == WorkerHistoryItem.Kind.INPUT) 12 else 4
    }
}
