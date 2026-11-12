package surf.comma.android.chat.live

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AgentLocationAnswersTest {
    private class Core : CoreApi {
        val requests = MutableStateFlow(JSONArray())
        val shared = ArrayList<JSONObject>()
        var subscribers = 0

        override suspend fun call(name: String, params: JSONObject): Any? {
            assertEquals("agentRequests.shareLocation", name)
            shared += params
            return null
        }

        override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> {
            assertEquals("agentLocationRequests", topic.getString("topic"))
            subscribers++
            return requests.map { TopicValue.Value(read(JSONObject().put("requests", it))) }
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val core = Core()
    private var allowed = true
    private val reads = ArrayList<(DeviceLocation.Reading) -> Unit>()
    private val answers = AgentLocationAnswers(RuntimeEnvironment.getApplication(), core, scope,
        allowed = { allowed }, read = { _, done -> reads += done })

    private fun asked(vararg ids: String) {
        core.requests.value = JSONArray(ids.map {
            JSONObject().put("id", it).put("group", "group-2").put("conversation", "conversation-2")
        })
        org.robolectric.shadows.ShadowLooper.idleMainLooper()
    }

    @After fun tearDown() = scope.cancel()

    @Test fun `with location allowed, a request in any conversation is answered once, without the person`() {
        answers.setForeground(true)
        var changes = 0
        answers.watch { changes++ }
        asked("cap-1")
        assertTrue(answers.answering("cap-1"))
        asked("cap-1")
        assertEquals(1, reads.size)
        reads.single()(DeviceLocation.Reading.At(35.67, 139.76, 20f))
        org.robolectric.shadows.ShadowLooper.idleMainLooper()
        val shared = core.shared.single()
        assertEquals("group-2", shared.getString("group"))
        assertEquals("conversation-2", shared.getString("conversation"))
        assertEquals("cap-1", shared.getString("request"))
        assertEquals(35.67, shared.getDouble("latitude"), 0.0)
        assertFalse(answers.answering("cap-1"))
        assertEquals(2, changes)
    }

    @Test fun `without location allowed, the card asks`() {
        allowed = false
        answers.setForeground(true)
        asked("cap-1")
        assertEquals(0, reads.size)
        assertFalse(answers.answering("cap-1"))
    }

    @Test fun `a position it cannot read leaves the request on its card until the app opens again`() {
        answers.setForeground(true)
        asked("cap-1")
        reads.single()(DeviceLocation.Reading.Unavailable)
        assertFalse(answers.answering("cap-1"))
        asked("cap-1")
        assertEquals(1, reads.size)
        assertEquals(emptyList<JSONObject>(), core.shared)

        answers.setForeground(false)
        answers.setForeground(true)
        org.robolectric.shadows.ShadowLooper.idleMainLooper()
        assertEquals(2, reads.size)
    }

    @Test fun `in the background it follows nothing`() {
        answers.setForeground(true)
        answers.setForeground(false)
        asked("cap-1")
        assertEquals(0, reads.size)
        assertEquals(1, core.subscribers)
    }
}
