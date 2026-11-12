package surf.comma.android.dynamicui

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.core.CoreApi
import surf.comma.android.core.TopicValue

/**
 * The Android Dynamic UI bridge's boundary: what the host page may tell the app, what the container loads, and what
 * a widget's messages can make the app do.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class DynamicUiTest {
    private fun event(json: JSONObject) = DynamicUiFrame.parse(JSONObject().put("kind", "event").put("wire", json.toString()).toString())

    @Test
    fun takesOnlyTheRuntimeMessagesTheAppActsOn() {
        assertEquals(DynamicUiFrame.Connected, DynamicUiFrame.parse("""{"kind":"connected"}"""))
        assertEquals(DynamicUiFrame.Failed("no"), DynamicUiFrame.parse("""{"kind":"failed","reason":"no"}"""))
        assertEquals(DynamicUiFrame.Event(DynamicUiEvent.Ready), event(JSONObject().put("type", "ready")))
        assertEquals(DynamicUiFrame.Event(DynamicUiEvent.Request("Book it")),
            event(JSONObject().put("type", "request").put("value", "Book it")))
        // Unknown kinds, unknown types, other shapes and broken JSON are dropped.
        for (data in listOf(null, "", "nope", "[]", """{"kind":"invoke"}""", """{"kind":"event","wire":{"type":"ready"}}"""))
            assertNull(data, DynamicUiFrame.parse(data))
        for (type in listOf("height", "init", "core.call"))
            assertNull(event(JSONObject().put("type", type).put("value", "x")))
        assertNull(event(JSONObject().put("type", "request").put("value", 7)))
        assertNull(event(JSONObject().put("type", "request").put("value", "x".repeat(4001))))
    }

    @Test
    fun opensOnlyHttpsLinksWithoutCredentials() {
        assertEquals(DynamicUiFrame.Event(DynamicUiEvent.OpenLink("https://example.com/a?b=1")),
            event(JSONObject().put("type", "open-link").put("url", "https://example.com/a?b=1")))
        for (url in listOf("http://example.com", "javascript:alert(1)", "https://user:pw@example.com/", "intent://x", "https://"))
            assertNull(url, event(JSONObject().put("type", "open-link").put("url", url)))
    }

    @Test
    fun boundsErrorsAndSavedState() {
        val error = event(JSONObject().put("type", "error").put("reason", "x".repeat(500))) as DynamicUiFrame.Event
        assertEquals(200, (error.event as DynamicUiEvent.Error).reason!!.length)
        val saved = event(JSONObject().put("type", "save").put("value", JSONObject().put("step", 2))) as DynamicUiFrame.Event
        assertEquals(DynamicUiEvent.Save("state", """{"step":2}"""), saved.event)
        val cards = event(JSONObject().put("type", "card-state").put("value", JSONObject.NULL)) as DynamicUiFrame.Event
        assertEquals(DynamicUiEvent.Save("cards", "null"), cards.event)
        assertNull(event(JSONObject().put("type", "save")))
        assertNull(event(JSONObject().put("type", "save").put("value", "x".repeat(33_000))))
        // Over the wire bound in UTF-8 bytes, though not in characters.
        assertNull(DynamicUiEvent.parse(JSONObject().put("type", "request").put("value", "界".repeat(14_000)).toString()))
    }

    @Test
    fun servesOnlyTheFixedPageAndItsScriptAndNeverNavigatesTheMainFrame() {
        val origin = DynamicUiWebHost.ORIGIN
        assertEquals(DynamicUiWebHost.Route.PAGE, DynamicUiWebHost.route("GET", "$origin/", mainFrame = true))
        assertEquals(DynamicUiWebHost.Route.SCRIPT, DynamicUiWebHost.route("GET", "$origin/dynamic-ui-host.js", mainFrame = false))
        assertEquals(DynamicUiWebHost.Route.REFUSED, DynamicUiWebHost.route("GET", "https://example.com/", mainFrame = true))
        assertEquals(DynamicUiWebHost.Route.REFUSED, DynamicUiWebHost.route("GET", "$origin/other", mainFrame = false))
        assertEquals(DynamicUiWebHost.Route.REFUSED, DynamicUiWebHost.route("POST", "https://cdn.example.com/a.js", mainFrame = false))
        assertEquals(DynamicUiWebHost.Route.REFUSED, DynamicUiWebHost.route("GET", "http://cdn.example.com/a.js", mainFrame = false))
        assertEquals(DynamicUiWebHost.Route.REFUSED, DynamicUiWebHost.route("GET", "file:///data/a", mainFrame = false))
        // What the runtime's policy permits a widget: HTTPS images, styles, fonts and scripts.
        assertEquals(DynamicUiWebHost.Route.NETWORK, DynamicUiWebHost.route("GET", "https://cdn.example.com/a.js", mainFrame = false))
    }

    @Test
    fun readsTheTargetOnlyWithAnIdentity() {
        val part = JSONObject().put("kind", "dynamic-ui").put("contentId", "c1").put("conversationId", "cnv")
            .put("messageId", "m1").put("attachmentIndex", 2).put("summary", "Sales")
        val target = DynamicUiTarget.parse(part)!!
        assertEquals(target, DynamicUiTarget.decode(target.json().toString()))
        assertNull(DynamicUiTarget.parse(JSONObject(part.toString()).apply { remove("contentId") }))
        assertNull(DynamicUiTarget.parse(JSONObject(part.toString()).put("attachmentIndex", -1)))
        assertNull(DynamicUiTarget.decode("not json"))
    }

    /** A core that answers the widget's topics and records its calls. */
    private class Core(private val saved: JSONObject? = null) : CoreApi {
        val calls = MutableStateFlow(emptyList<JSONObject>())
        val feed = MutableSharedFlow<TopicValue<Any?>>(replay = 1)
        var gate: CompletableDeferred<Unit>? = null

        override suspend fun call(name: String, params: JSONObject): Any? {
            calls.update { it + JSONObject(params.toString()).put("name", name) }
            gate?.await()
            return null
        }

        @Suppress("UNCHECKED_CAST")
        override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> = when (topic.getString("topic")) {
            "dynamicUiState" -> flowOf(TopicValue.Value(read(saved)))
            else -> feed as Flow<TopicValue<T>>
        }
    }

    private val target = DynamicUiTarget("c1", "cnv", "m1", 2, "Sales")

    private fun model(core: Core, scope: CoroutineScope, current: () -> Boolean = { true }) =
        DynamicUiModel(core, target, "grp", "key", current, scope)

    @Test
    fun startsFromTheSavedStateAndKeepsOnlyTheLatestSaveOfEachKind() = runBlocking {
        val core = Core(JSONObject().put("state", """{"step":1}""").put("cards", JSONObject.NULL))
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val model = model(core, scope)
        model.start()
        core.feed.emit(TopicValue.Value(JSONObject().put("status", "ready").put("ui", JSONObject().put("html", "<p>"))))
        model.state.first { it.stateLoaded && it.ui != null }
        val init = model.initialization(mapOf("scheme" to "dark"), mapOf("high" to "High"), "en-US", "UTC")
        assertEquals(1, init.getJSONObject("state").getInt("step"))
        assertTrue(init.isNull("cardState"))
        assertEquals("c1", init.getString("seed"))
        assertEquals("<p>", init.getJSONObject("payload").getString("html"))

        core.gate = CompletableDeferred()
        model.receive(DynamicUiEvent.Save("state", "1"))
        model.receive(DynamicUiEvent.Save("state", "2"))
        model.receive(DynamicUiEvent.Save("state", "3"))
        model.receive(DynamicUiEvent.Save("cards", "[]"))
        core.gate!!.complete(Unit)
        val calls = core.calls.first { it.size == 3 }
        assertEquals(listOf("state:1", "state:3", "cards:[]"), calls.map { "${it.getString("kind")}:${it.getString("text")}" })
        assertTrue(calls.all { it.getString("name") == "dynamicUiState.save" && it.getString("key") == "key" })
        scope.cancel()
    }

    @Test
    fun aProposalOrLinkWaitsForTheMemberAndNothingActsAfterTheScopeChanged() = runBlocking {
        val core = Core()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        var current = true
        val model = model(core, scope) { current }
        model.receive(DynamicUiEvent.Request("Book the 9:00 train"))
        model.receive(DynamicUiEvent.OpenLink("https://example.com"))
        assertEquals("Book the 9:00 train", model.state.value.proposal)
        assertEquals("https://example.com", model.takeLink("https://example.com"))
        assertNull(model.state.value.link)
        // Closing the first link's dialog after a second link arrived leaves the second one waiting.
        model.receive(DynamicUiEvent.OpenLink("https://example.com/a"))
        model.receive(DynamicUiEvent.OpenLink("https://example.com/b"))
        model.dismissLink("https://example.com/a")
        assertEquals("https://example.com/b", model.state.value.link)
        assertNull(model.takeLink("https://example.com/a"))
        assertEquals("https://example.com/b", model.takeLink("https://example.com/b"))
        assertNull(model.state.value.link)
        current = false
        assertNull(model.takeProposal())
        model.receive(DynamicUiEvent.Request("other"))
        model.receive(DynamicUiEvent.Save("state", "1"))
        assertNull(model.state.value.proposal)
        assertTrue(core.calls.value.isEmpty())
        assertFalse(model.state.value.failed)
        scope.cancel()
    }

    @Test
    fun theStateKeyNamesTheApiAccountWorkspaceAndContent() {
        val key = DynamicUiModel.stateKey("https://api.example.com", "usr", "wsp", "c1")
        assertEquals(listOf("comma-ui:1", "https://api.example.com", "usr", "wsp", "c1"),
            JSONArray(key).let { array -> (0 until array.length()).map(array::getString) })
        assertFalse(key.contains("\\/"))
    }
}
