package surf.comma.android.dynamicui

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.core.CoreApi
import surf.comma.android.core.TopicValue

/**
 * One opened widget, as the iOS app has it: the core reads its JSON (`dynamicUi`) and what it saved on this device
 * (`dynamicUiState`); the runtime's messages become a proposal, a link to confirm, a failure, or saves. No message
 * selects a core method or a native capability. Everything stops when [current] says the account or Workspace changed.
 */
class DynamicUiModel(
    private val core: CoreApi,
    val target: DynamicUiTarget,
    private val groupId: String,
    /** The saved state's key: the API, the account, the Workspace and the content. */
    val stateKey: String,
    private val current: () -> Boolean,
    private val scope: CoroutineScope,
) {
    data class State(
        /** The widget's JSON once the core read it. */
        val ui: Any? = null,
        /** Why the widget cannot show; null while it loads or shows. */
        val unavailable: String? = null,
        /** False until the saved state was read: the runtime starts only after. */
        val stateLoaded: Boolean = false,
        val savedState: Any? = JSONObject.NULL,
        val savedCards: Any? = JSONObject.NULL,
        val runtimeReady: Boolean = false,
        val proposal: String? = null,
        val link: String? = null,
        /** A failure to show; [failed] with no reason uses the screen's own words. */
        val failed: Boolean = false,
        val failure: String? = null,
    )

    private val mutableState = MutableStateFlow(State())
    val state: StateFlow<State> = mutableState.asStateFlow()
    private val pending = LinkedHashMap<String, String>()
    private var saving: Job? = null
    private var jobs = emptyList<Job>()

    fun start() {
        if (jobs.isNotEmpty()) return
        val feed = JSONObject().put("topic", "dynamicUi").put("group", groupId).put("conversation", target.conversationId)
            .put("message", target.messageId).put("index", target.index.toString())
        jobs = listOf(
            scope.launch {
                core.subscribe(feed) { it as? JSONObject }.collect { update ->
                    if (!current()) return@collect
                    when (update) {
                        is TopicValue.Value -> update.value?.let(::feed)
                        is TopicValue.Failed -> mutableState.update { it.copy(unavailable = update.error.message.orEmpty()) }
                    }
                }
            },
            scope.launch {
                val saved = runCatching {
                    core.subscribe(JSONObject().put("topic", "dynamicUiState").put("key", stateKey)) { it as? JSONObject }.first()
                }.getOrNull()
                if (!current()) return@launch
                val value = (saved as? TopicValue.Value)?.value
                mutableState.update {
                    it.copy(stateLoaded = true, savedState = decode(value, "state"), savedCards = decode(value, "cards"))
                }
            },
        )
    }

    fun stop() {
        jobs.forEach(Job::cancel)
        saving?.cancel()
    }

    private fun feed(value: JSONObject) {
        when (value.optString("status")) {
            "ready" -> if (value.has("ui")) mutableState.update { it.copy(ui = value.get("ui"), unavailable = null) }
            "failed" -> mutableState.update { it.copy(unavailable = value.optString("reason")) }
        }
    }

    /** The runtime's start values, iOS's set: the widget, what it saved, and the host's look, copy and clock. */
    fun initialization(theme: Map<String, String>, copy: Map<String, String>, locale: String, timeZone: String): JSONObject {
        val now = state.value
        return JSONObject().put("payload", now.ui ?: JSONObject.NULL).put("state", now.savedState)
            .put("cardState", now.savedCards).put("seed", target.id).put("theme", JSONObject(theme))
            .put("tokens", JSONObject()).put("icons", JSONObject()).put("copy", JSONObject(copy))
            .put("locale", locale).put("timeZone", timeZone)
    }

    fun receive(event: DynamicUiEvent) {
        if (!current()) return
        when (event) {
            DynamicUiEvent.Ready -> mutableState.update { it.copy(runtimeReady = true) }
            is DynamicUiEvent.Request -> mutableState.update { it.copy(proposal = event.text) }
            is DynamicUiEvent.OpenLink -> mutableState.update { it.copy(link = event.url) }
            is DynamicUiEvent.Error -> fail(event.reason)
            is DynamicUiEvent.Save -> {
                pending.remove(event.kind)
                pending[event.kind] = event.text
                if (saving?.isActive != true) saving = scope.launch { flush() }
            }
        }
    }

    fun fail(reason: String?) = mutableState.update { it.copy(failed = true, failure = reason?.take(DynamicUiEvent.MAX_REASON)) }

    /** The proposal, once: the screen adds it to the draft. */
    fun takeProposal(): String? = state.value.proposal?.takeIf { current() }.also { dismissProposal() }

    fun dismissProposal() = mutableState.update { it.copy(proposal = null) }

    /** [url], if it is still the link waiting for the member: the screen opens it. */
    fun takeLink(url: String): String? = state.value.link?.takeIf { it == url && current() }.also { dismissLink(url) }

    /** Lets [url] go; a newer link that arrived meanwhile keeps waiting. */
    fun dismissLink(url: String) = mutableState.update { if (it.link == url) it.copy(link = null) else it }

    /** Saves the latest value of each kind, one at a time; values that arrive meanwhile replace the waiting ones. */
    private suspend fun flush() {
        while (current()) {
            val (kind, text) = pending.entries.firstOrNull()?.toPair() ?: return
            pending.remove(kind)
            try {
                core.call("dynamicUiState.save", JSONObject().put("key", stateKey).put("kind", kind).put("text", text))
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                fail(error.message)
                return
            }
        }
    }

    companion object {
        fun stateKey(baseUrl: String, accountId: String, workspaceId: String, contentId: String): String =
            JSONArray(listOf("comma-ui:1", baseUrl, accountId, workspaceId, contentId)).toString().replace("\\/", "/")

        private fun decode(saved: JSONObject?, name: String): Any {
            val text = saved?.opt(name) as? String ?: return JSONObject.NULL
            return runCatching { org.json.JSONTokener(text).nextValue() }.getOrNull() ?: JSONObject.NULL
        }
    }
}
