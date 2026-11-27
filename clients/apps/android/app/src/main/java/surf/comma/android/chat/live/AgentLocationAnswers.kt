package surf.comma.android.chat.live

import android.content.Context
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject
import surf.comma.android.auth.AuthGraph
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue

/**
 * Answers the location requests the person's own messages led to while the app is open (the core's
 * `agentLocationRequests`, in any conversation): while the person shares their location (Settings › Share location, or
 * Always share on a card) and the system allows it, the phone sends its position and the person is not asked.
 * Otherwise, or when the position cannot be read, the request stays on its card, which asks them. Nothing here keeps a
 * position. Runs on the main thread.
 */
internal class AgentLocationAnswers(
    private val context: Context,
    private val core: CoreApi?,
    private val scope: CoroutineScope,
    private val allowed: (Context) -> Boolean = DeviceLocation::allowed,
    private val read: (Context, (DeviceLocation.Reading) -> Unit) -> Unit = DeviceLocation::readGranted,
    /** Whether the person shares their location now. */
    private val shared: () -> Boolean,
) {
    private class Own(val id: String, val group: String, val conversation: String)

    private var following: Job? = null
    private val tried = HashSet<String>()
    /** The requests still waiting, as the core last said. */
    private var waiting: List<Own> = emptyList()
    private val reading = HashSet<String>()
    private val watchers = LinkedHashSet<() -> Unit>()

    /** Whether this phone is reading its position for request [id] now, so the card only says so. */
    fun answering(id: String): Boolean = id in reading

    /** Calls [changed] when [answering] may have changed, until the returned function is called. */
    fun watch(changed: () -> Unit): () -> Unit {
        watchers += changed
        return { watchers -= changed }
    }

    /** Sharing was turned on or off: a request still waiting may be answered now. */
    fun sharingChanged() = waiting.forEach(::answer)

    fun setForeground(visible: Boolean) {
        if (!visible) {
            following?.cancel()
            following = null
            // Back in the app, a request still waiting is tried again.
            tried.clear()
            return
        }
        val api = core ?: return
        if (following?.isActive == true) return
        following = scope.launch {
            api.subscribe(JSONObject().put("topic", "agentLocationRequests"), ::parse).collect { value ->
                if (value !is TopicValue.Value) return@collect
                tried.retainAll(value.value.mapTo(HashSet()) { it.id })
                waiting = value.value
                value.value.forEach(::answer)
            }
        }
    }

    private fun answer(request: Own) {
        if (!shared() || !allowed(context) || !tried.add(request.id)) return
        reading += request.id
        changed()
        read(context) { position ->
            // Sharing may have been turned off while the phone read its position.
            if (position !is DeviceLocation.Reading.At || !shared()) {
                finish(request.id)
                return@read
            }
            scope.launch {
                try {
                    core?.call("agentRequests.shareLocation", JSONObject().put("group", request.group)
                        .put("conversation", request.conversation).put("request", request.id)
                        .put("latitude", position.latitude).put("longitude", position.longitude)
                        .apply { position.accuracy?.let { put("accuracy", it.toDouble()) } })
                } catch (e: CancellationException) {
                    throw e
                } catch (_: CoreError) {
                    // Answered elsewhere or refused: the card shows how it stands.
                } finally {
                    finish(request.id)
                }
            }
        }
    }

    private fun finish(id: String) {
        reading -= id
        changed()
    }

    private fun changed() = watchers.toList().forEach { it() }

    private fun parse(value: Any?): List<Own> {
        val requests = (value as? JSONObject)?.optJSONArray("requests") ?: return emptyList()
        return (0 until requests.length()).mapNotNull { index ->
            val json = requests.optJSONObject(index) ?: return@mapNotNull null
            Own(json.optString("id"), json.optString("group"), json.optString("conversation"))
                .takeIf { it.id.isNotEmpty() && it.group.isNotEmpty() && it.conversation.isNotEmpty() }
        }
    }

    companion object {
        @Volatile private var instance: AgentLocationAnswers? = null

        /** The process's one, so every screen's cards see what it is reading. */
        fun of(context: Context): AgentLocationAnswers = instance ?: synchronized(this) {
            instance ?: LocationSharing.of(context).let { sharing ->
                AgentLocationAnswers(
                    context.applicationContext,
                    AuthGraph.core(context),
                    CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
                    shared = { sharing.enabled == true },
                ).also { answers ->
                    sharing.watch(answers::sharingChanged)
                    instance = answers
                }
            }
        }
    }
}
