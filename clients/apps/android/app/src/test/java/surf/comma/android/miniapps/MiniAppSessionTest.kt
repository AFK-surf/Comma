package surf.comma.android.miniapps

import android.net.Uri
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreBytes
import surf.comma.android.core.TopicValue
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The Android container's authority boundary: the core decides every operation, the host refuses what a phone does
 * not offer, and photos reach an app only after the member confirms them in the foreground.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MiniAppSessionTest {
    /** The core's Mini App calls, each answered by [answer]. */
    private class Core : CoreApi {
        val calls = CopyOnWriteArrayList<Pair<String, JSONObject>>()
        var answer: (String, JSONObject) -> Any? = { _, _ -> null }

        override suspend fun call(name: String, params: JSONObject): Any? {
            calls += name to JSONObject(params.toString())
            return when (name) {
                "miniApps.session.open" -> JSONObject().put("session", "mas-1").put("version", 3)
                    .put("app", JSONObject().put("id", "app1").put("name", "Notes"))
                    .put("capabilities", JSONArray(listOf("ai.chat", "files.pick"))).put("grants", JSONArray())
                    .put("storage", JSONArray(listOf("app"))).put("backend", true)
                else -> answer(name, params)
            }
        }

        override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> = emptyFlow()

        fun named(name: String) = calls.filter { it.first == name }.map { it.second }
    }

    private val target = MiniAppTarget("wsp", "app1", version = 3)

    private fun opened(core: Core) = MiniAppSession(core, target).also {
        runBlocking { it.open() }
        it.approve()
    }

    private fun op(name: String, args: JSONObject = JSONObject()) = JSONObject().put("op", name).put("args", args)

    @Test
    fun opensAsAndroidAndNeedsTheMembersApprovalBeforeAnyCall() = runBlocking {
        val core = Core()
        val session = MiniAppSession(core, target)
        session.open()
        val params = core.named("miniApps.session.open").single()
        assertEquals("android", params.getString("platform"))
        assertEquals(3, params.getInt("version"))
        assertTrue(session.state.value.needsConsent)
        val refused = session.invoke(op("ai.chat"))
        assertEquals("denied", refused.getJSONObject("error").getString("code"))
        assertTrue(core.named("miniApps.invoke").isEmpty())
        // Without an identity grant the frame learns no viewer, and nothing beyond what the core returned.
        session.approve()
        val init = session.initialization(dark = true, tokens = mapOf("--comma-background" to "rgba(0,0,0,1)"))
        assertTrue(init.isNull("viewer"))
        assertEquals("dark", init.getString("theme"))
        assertEquals(listOf("ai.chat", "files.pick"), (0 until init.getJSONArray("capabilities").length()).map { init.getJSONArray("capabilities").getString(it) })
    }

    /** Records the device effects the session asked for. */
    private class Device : MiniAppDeviceHost {
        val drafts = mutableListOf<String>()
        val opened = mutableListOf<String>()
        override fun draft(text: String) = true.also { drafts += text }
        override fun copy(text: String) = Unit
        override fun open(url: String) = true.also { opened += url }
        override suspend fun notify(title: String, body: String) = true
    }

    @Test
    fun refusesOperationsAPhoneDoesNotOfferWithoutAskingTheCore() = runBlocking {
        val core = Core()
        val session = opened(core)
        for (name in listOf("calendar.events", "storage.device.get", "device.unknown")) {
            val answer = session.invoke(op(name))
            assertEquals(name, "unsupported", answer.getJSONObject("error").getString("code"))
        }
        assertTrue(core.named("miniApps.invoke").isEmpty())
    }

    @Test
    fun grantsCloudAccessDirectlyAndIdentityOnlyAfterTheMembersApproval() = runBlocking {
        val core = Core()
        val granted = mutableSetOf<String>()
        core.answer = { name, params ->
            when (name) {
                "miniApps.grant" -> null.also { granted += params.getString("capability") }
                "miniApps.invoke" -> when (val op = params.getString("op")) {
                    "ai.chat" -> if ("ai.chat" in granted) JSONObject().put("status", "done").put("value", JSONObject().put("content", "Hi"))
                        else JSONObject().put("status", "grant").put("capability", "ai.chat")
                    "viewer" -> if ("identity.basic" in granted) JSONObject().put("status", "done").put("value", JSONObject().put("name", "Ada"))
                        else JSONObject().put("status", "grant").put("capability", "identity.basic")
                    else -> JSONObject().put("status", "grant").put("capability", "calendar.read").also { assertEquals("storage.app.get", op) }
                }
                else -> null
            }
        }
        val session = opened(core)
        val chat = session.invoke(op("ai.chat"))
        assertEquals("Hi", chat.getJSONObject("value").getString("content"))
        assertNull(session.state.value.hostRequest)

        // A declined identity request grants nothing.
        val declined = async { session.invoke(op("viewer")) }
        val first = session.state.first { it.hostRequest != null }.hostRequest!!
        assertEquals("identity.basic", first.op)
        session.finishHostRequest(first.id, approved = false)
        assertEquals("denied", declined.await().getJSONObject("error").getString("code"))
        assertEquals(setOf("ai.chat"), granted)

        val allowed = async { session.invoke(op("viewer")) }
        session.finishHostRequest(session.state.first { it.hostRequest != null }.hostRequest!!.id, approved = true)
        assertEquals("Ada", allowed.await().getJSONObject("value").getString("name"))
        assertEquals(setOf("ai.chat", "identity.basic"), granted)

        val other = session.invoke(op("storage.app.get"))
        assertEquals("unsupported", other.getJSONObject("error").getString("code"))
    }

    @Test
    fun opensALinkOnlyAfterTheMemberConfirmsThatLink() = runBlocking {
        val core = Core()
        core.answer = { name, params ->
            if (name != "miniApps.invoke") null
            else if (params.optBoolean("confirmed")) JSONObject().put("status", "host").put("op", "links.open").put("args", params.getJSONObject("args"))
            else JSONObject().put("status", "confirm").put("capability", "links.open")
        }
        val session = opened(core)
        val device = Device().also { session.device = it }
        val link = async { session.invoke(op("links.open", JSONObject().put("url", "https://example.com/a"))) }
        val request = session.state.first { it.hostRequest != null }.hostRequest!!
        assertEquals("https://example.com/a", request.detail)
        assertTrue(device.opened.isEmpty())
        session.finishHostRequest(request.id, approved = true)
        assertTrue(link.await().getJSONObject("value").getBoolean("opened"))
        assertEquals(listOf("https://example.com/a"), device.opened)
    }

    @Test
    fun aCallTheServerCompletedAcrossABackgroundTripReportsItsResult() = runBlocking {
        val core = Core()
        val reply = kotlinx.coroutines.CompletableDeferred<JSONObject>()
        val entered = kotlinx.coroutines.CompletableDeferred<Unit>()
        core.answer = { name, params ->
            if (name != "miniApps.invoke") null
            else if (params.getString("op") == "ai.chat") runBlocking { entered.complete(Unit); reply.await() }
            else JSONObject().put("status", "host").put("op", "chat.draft").put("args", params.getJSONObject("args"))
        }
        val session = opened(core)
        val device = Device().also { session.device = it }
        val chat = async(kotlinx.coroutines.Dispatchers.IO) { session.invoke(op("ai.chat")) }
        entered.await()
        session.suspend()
        session.resume()
        reply.complete(JSONObject().put("status", "done").put("value", JSONObject().put("content", "Reply")))
        assertEquals("Reply", chat.await().getJSONObject("value").getString("content"))
        assertEquals(1, core.named("miniApps.invoke").size)

        // The device side effect still waits for the foreground: a suspended run adds no draft.
        session.suspend()
        val draft = session.invoke(op("chat.draft", JSONObject().put("text", "Continue")))
        assertEquals("unavailable", draft.getJSONObject("error").getString("code"))
        session.resume()
        assertTrue(session.invoke(op("chat.draft", JSONObject().put("text", "Continue"))).getBoolean("ok"))
        assertEquals(listOf("Continue"), device.drafts)
    }

    @Test
    fun aServerCallStartedWhileSuspendedStillRuns() = runBlocking {
        val core = Core()
        core.answer = { name, _ ->
            if (name == "miniApps.invoke") JSONObject().put("status", "done").put("value", "Reply") else null
        }
        val session = opened(core)
        session.suspend()
        assertEquals("Reply", session.invoke(op("ai.chat")).getString("value"))
        // Picking photos needs the member, so it does not start.
        assertEquals("unavailable", session.invoke(op("files.pick")).getJSONObject("error").getString("code"))
        assertEquals(1, core.named("miniApps.invoke").size)
    }

    @Test
    fun deliversOnlyConfirmedPhotosAndNothingAfterSuspension() = runBlocking {
        val core = Core()
        core.answer = { name, params ->
            if (name != "miniApps.invoke") null
            else if (params.optBoolean("confirmed")) JSONObject().put("status", "host").put("op", "files.pick")
            else JSONObject().put("status", "confirm").put("capability", "files.pick")
        }
        val session = opened(core)
        val pick = async { session.invoke(op("files.pick", JSONObject().put("accept", JSONArray(listOf("image/png"))))) }
        val request = session.state.first { it.photoRequest != null }.photoRequest!!
        assertTrue(request.request.png)
        assertTrue(core.named("miniApps.invoke").none { it.optBoolean("confirmed") })
        session.finishPhotoRequest(request.id, listOf(MiniAppPhoto(byteArrayOf(1, 2, 3), png = true)))
        val answer = pick.await()
        val file = answer.getJSONArray("value").getJSONObject(0)
        assertEquals("image/png", file.getString("mime"))
        assertEquals(listOf<Byte>(1, 2, 3), CoreBytes.read(file.get("data"))!!.toList())
        assertTrue(core.named("miniApps.invoke").last().getBoolean("confirmed"))

        // Leaving the foreground cancels a pending request: the app receives no photo and the core no confirmation.
        val confirmations = core.named("miniApps.invoke").count { it.optBoolean("confirmed") }
        val second = async { session.invoke(op("files.pick")) }
        session.state.first { it.photoRequest != null }
        session.suspend()
        val left = second.await()
        assertEquals("unavailable", left.getJSONObject("error").getString("code"))
        assertNull(session.state.value.photoRequest)
        assertEquals(confirmations, core.named("miniApps.invoke").count { it.optBoolean("confirmed") })
    }

    @Test
    fun linksOpenOnlyInTheirOwnEnvironment() {
        val staging = Uri.parse("https://salix-staging.comma.surf")
        val token = "A".repeat(43)
        assertEquals(token, MiniAppLinks.sharedToken(Uri.parse("https://app-staging.comma.surf/a/$token"), staging))
        assertNull(MiniAppLinks.sharedToken(Uri.parse("https://app.comma.surf/a/$token"), staging))
        assertNull(MiniAppLinks.sharedToken(Uri.parse("https://app-staging.comma.surf/a/short"), staging))
        assertTrue(MiniAppLinks.isClaimed(Uri.parse("https://app.comma.surf/a/$token")))
        assertNull(MiniAppLinks.sharedToken(Uri.parse("https://app.comma.surf/a/$token"), Uri.parse("http://10.0.2.2:8787")))
    }
}
