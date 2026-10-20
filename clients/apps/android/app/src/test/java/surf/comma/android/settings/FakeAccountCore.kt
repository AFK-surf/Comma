package surf.comma.android.settings

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreBytes
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The client core's account topics and calls, as far as the settings read and change them: `profile`, the Group's
 * `taskLabels` policy, `accountSessions`, a workspace's `devices` and `voice` keys. A saved change shows in the topic as
 * the core's would. [fail] makes a call fail with its error, [hold] makes it wait until completed. What the core does
 * with the server (the requests, paging, which sessions are open) is the core's and is tested there.
 */
internal class FakeAccountCore : CoreApi {
    /** Each call, as `name params`. */
    val calls = CopyOnWriteArrayList<Pair<String, JSONObject>>()
    val subscribed = CopyOnWriteArrayList<JSONObject>()
    val fail = ConcurrentHashMap<String, CoreError>()
    /** Refuses one call by what it asks, before [fail] is looked at. */
    @Volatile var refuse: (name: String, params: JSONObject) -> CoreError? = { _, _ -> null }
    val hold = ConcurrentHashMap<String, CompletableDeferred<Unit>>()

    val profile = MutableStateFlow<JSONObject?>(profile())
    val policy = MutableStateFlow("ask")
    val sessions = MutableStateFlow(listOf(session("ses-this", current = true), session("ses-other", label = "Web on Android")))
    val devices = MutableStateFlow(listOf(device()))
    val keys = MutableStateFlow(listOf(JSONObject().put("key_id", "gak_test").put("name", "Kitchen (dev_test_1)")))

    fun profile(id: String = "usr_test_a", name: String? = "Ada", avatar: String? = null): JSONObject = JSONObject().put("id", id)
        .put("email", "ada@example.test").put("name", name ?: JSONObject.NULL).put("avatar_id", avatar ?: JSONObject.NULL)

    fun session(id: String, label: String? = null, current: Boolean = false): JSONObject = JSONObject().put("id", id)
        .put("deviceLabel", label ?: JSONObject.NULL).put("current", current)

    fun device(id: String = "dev_test_1", status: String = "connected", allows: Boolean = false): JSONObject =
        JSONObject().put("device_id", id).put("name", "Kitchen").put("status", status).put("allows_operations", allows)
            .put("system_info", JSONObject().put("client_source", "t-circle"))

    fun called(name: String) = calls.filter { it.first == name }.map { it.second }

    override suspend fun call(name: String, params: JSONObject): Any? {
        calls += name to params
        hold[name]?.await()
        refuse(name, params)?.let { throw it }
        fail[name]?.let { throw it }
        return when (name) {
            "profile.update" -> profile.value!!.put("name", params.getString("name")).also { profile.value = JSONObject(it.toString()) }
            "profile.uploadAvatar" -> profile.value!!.put("avatar_id", "av-${calls.size}").also { profile.value = JSONObject(it.toString()) }
            "profile.removeAvatar" -> profile.value!!.put("avatar_id", JSONObject.NULL).also { profile.value = JSONObject(it.toString()) }
            "taskLabels.setPolicy" -> null.also { policy.value = params.getString("policy") }
            "accountSessions.revoke" -> null.also { sessions.value = sessions.value.filterNot { it.getString("id") == params.getString("id") } }
            "accountSessions.revokeOthers" -> sessions.value.count { !it.getBoolean("current") }
                .also { sessions.value = sessions.value.filter { it.getBoolean("current") } }
            "files.read" -> JSONObject().put("bytes", CoreBytes.json(byteArrayOf(1, 2, 3))).put("type", "image/png")
            "devices.get" -> devices.value.firstOrNull { it.getString("device_id") == params.getString("device") }
            "devices.setAccess" -> params.getBoolean("allow").also { allow ->
                devices.value = devices.value.map {
                    if (it.getString("device_id") == params.getString("device")) JSONObject(it.toString()).put("allows_operations", allow) else it
                }
            }
            "devices.remove" -> null.also { devices.value = devices.value.filterNot { it.getString("device_id") == params.getString("device") } }
            "voice.deleteKey" -> null.also { keys.value = keys.value.filterNot { it.getString("key_id") == params.getString("key") } }
            else -> null
        }
    }

    override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> {
        subscribed += topic
        val values: Flow<JSONObject?> = when (topic.getString("topic")) {
            "profile" -> profile.map { value -> JSONObject().put("status", if (value == null) "loading" else "ready").put("profile", value ?: JSONObject.NULL) }
            "taskLabels" -> policy.map { JSONObject().put("loading", false).put("error", false)
                .put("catalog", JSONObject().put("approval_policy", it).put("labels", JSONArray())) }
            "accountSessions" -> sessions.map { JSONObject().put("status", "ready").put("sessions", JSONArray(it)) }
            "devices" -> devices.map { JSONObject().put("workspace", topic.optString("prefer")).put("loading", false)
                .put("failed", false).put("devices", JSONArray(it)) }
            "voice" -> keys.map { JSONObject().put("workspace", topic.optString("prefer")).put("keys", JSONArray(it)) }
            else -> MutableStateFlow(null)
        }
        return values.map { TopicValue.Value(read(it)) }
    }
}
