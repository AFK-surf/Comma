package surf.comma.android.settings.desktop

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.map
import org.json.JSONObject
import surf.comma.android.auth.ConversationScope
import surf.comma.android.conversation.FakeSessions
import surf.comma.android.core.CoreApi
import surf.comma.android.core.TopicValue
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The client core's topics and calls as the desktop settings pages use them. [publish] sends a topic's next value;
 * [on] answers a call. What the core does with the server is the core's and is tested there.
 */
internal class FakeDesktopCore : CoreApi {
    val calls = CopyOnWriteArrayList<Pair<String, JSONObject>>()
    val subscribed = CopyOnWriteArrayList<JSONObject>()
    private val topics = mutableMapOf<String, MutableStateFlow<Any?>>()
    private val handlers = mutableMapOf<String, suspend (JSONObject) -> Any?>()
    private val streams = mutableMapOf<String, suspend (JSONObject, (Any?) -> Unit) -> Any?>()

    fun on(name: String, handler: suspend (JSONObject) -> Any?) { handlers[name] = handler }
    /** Answers a call that says how it goes: each value given to its progress, then its answer. */
    fun onStream(name: String, handler: suspend (JSONObject, (Any?) -> Unit) -> Any?) { streams[name] = handler }
    fun publish(topic: String, value: Any?) { topic(topic).value = value }
    fun called(name: String) = calls.filter { it.first == name }.map { it.second }

    /** Set: views get a sink, and [picture] hands it pictures as the core's thread would. */
    var sinks = false
    private val sinkHandlers = mutableMapOf<Int, (surf.comma.android.core.ScreenFrame) -> Unit>()

    override fun screenSink(handler: (surf.comma.android.core.ScreenFrame) -> Unit): surf.comma.android.core.ScreenSink? {
        if (!sinks) return null
        val id = sinkHandlers.size + 1
        sinkHandlers[id] = handler
        return surf.comma.android.core.ScreenSink(id) { sinkHandlers.remove(id) }
    }

    fun picture(sink: Int, frame: surf.comma.android.core.ScreenFrame) { sinkHandlers[sink]?.invoke(frame) }

    private fun topic(name: String) = topics.getOrPut(name) { MutableStateFlow(null) }

    override suspend fun call(name: String, params: JSONObject): Any? {
        calls += name to JSONObject(params.toString())
        return handlers[name]?.invoke(params)
    }

    override suspend fun call(name: String, params: JSONObject, progress: (Any?) -> Unit): Any? {
        val streamed = streams[name] ?: return call(name, params)
        calls += name to JSONObject(params.toString())
        return streamed(params, progress)
    }

    override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> {
        subscribed += topic
        return topic(topic.getString("topic")).filterNotNull().map { TopicValue.Value(read(it)) }
    }
}

/** A page's scope on the fake core, in workspace `wsp_test` of group `grp_test_1`; [switch] changes Workspace. */
internal class DesktopHarness {
    val core = FakeDesktopCore()
    val sessions = FakeSessions().apply { scopes.value = session(1, "wsp_test", "grp_test_1") }
    /** Work runs at once on the caller's thread, so a step's effect is there when it returns. */
    val owner = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    val scope = WorkspaceScope(core, sessions, sessions.scopes.value!!, owner)

    fun switch() { sessions.scopes.value = session(2, "wsp_other", "grp_other") }

    private fun session(generation: Long, workspace: String, group: String) =
        ConversationScope(generation, "usr_test_a", group, "cnv_test_main", workspace)
}
