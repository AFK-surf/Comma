package surf.comma.android.chat.live

import androidx.activity.ComponentActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode
import surf.comma.android.conversation.AgentRequest
import surf.comma.android.conversation.AgentRequestInput
import surf.comma.android.conversation.AgentRequestOutcome
import surf.comma.android.conversation.AgentRequestStatus
import surf.comma.android.routines.ProviderMarks
import java.time.Duration

// Invented test data only.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "en")
@LooperMode(LooperMode.Mode.PAUSED)
class AgentRequestCardViewTest {
    private class Host : AgentRequestCardHost {
        override val opened = HashSet<String>()
        val authorized = mutableListOf<String>()
        val declined = mutableListOf<String>()
        val filled = mutableListOf<String>()
        var takes = true

        override fun authorize(url: String) {
            authorized += url
        }

        override fun decline(requestId: String, done: (Boolean) -> Unit) {
            declined += requestId
            done(takes)
        }

        override fun fill(request: AgentRequest, done: (Boolean) -> Unit) {
            filled += request.id
            done(takes)
        }

        val installed = mutableListOf<String>()
        /** The install's answer, held until the test gives it. */
        var installDone: ((Boolean) -> Unit)? = null

        override fun installPlugin(request: AgentRequest, done: (Boolean) -> Unit) {
            installed += request.plugin!!.id
            installDone = done
        }

        val shared = mutableListOf<Pair<String, Boolean>>()
        var locationAnswer = AgentLocationAnswer.TAKEN
        var answering = false

        override fun answeringLocation(requestId: String) = answering

        override fun shareLocation(requestId: String, always: Boolean, done: (AgentLocationAnswer) -> Unit) {
            shared += requestId to always
            done(locationAnswer)
        }
    }

    private var now = 1_000_000L

    private fun request(status: AgentRequestStatus = AgentRequestStatus.PENDING, outcome: AgentRequestOutcome? = null,
                        expiresAt: Long? = now + 90_000, account: String? = null) =
        AgentRequest("cap-1", status, outcome, expiresAt, createdAt = now - 1_000, sourceMessageId = "msg-1",
            provider = "github", reason = "An app keeps its code in GitHub.",
            authorizationUrl = "https://github.com/login/oauth/authorize?state=s".takeIf { status == AgentRequestStatus.PENDING },
            account = account)

    private fun withCard(host: Host? = Host(), block: (AgentRequestCardView, Host?) -> Unit) {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        try {
            val card = AgentRequestCardView(activity.get()) { now }.apply { hostOf = { host } }
            block(card, host)
        } finally {
            activity.pause().stop().destroy()
        }
    }

    @Test fun `a secret's fields read from the core, each shown or masked, required or optional`() {
        val input = AgentRequestInput.parse(org.json.JSONObject("""{"kind":"secret","fields":[
            {"name":"app_key","label":"App Key","secret":false,"optional":false},
            {"name":"token","label":"Token","secret":true,"optional":true},{"label":"no name"}]}"""))!!
        assertEquals(listOf(
            AgentRequestInput.Field("app_key", "App Key", secret = false, optional = false),
            AgentRequestInput.Field("token", "Token", secret = true, optional = true),
        ), input.fields)
        assertEquals(input, AgentRequestInput.parse(input.json()))
    }

    @Test fun `a secret named for a service with a logo shows that logo, not the plain mark`() {
        fun secret(alias: String) = request().copy(provider = "secret", alias = alias)
        assertEquals("didi", markKey(secret("didi")))
        assertTrue(ProviderMarks.hasArtwork(markKey(secret("didi"))))
        assertFalse(ProviderMarks.hasArtwork(markKey(secret("lumen-erp"))))
        assertEquals("github", markKey(request()))
    }

    @Test fun `authorizing opens the provider's page, and only then does the card say it waits for the browser`() = withCard { card, host ->
        card.show(request())
        assertNull(card.receiptLine)
        assertNull(card.noteShown)
        card.authorize.performClick()
        assertEquals(listOf("https://github.com/login/oauth/authorize?state=s"), host!!.authorized)
        assertEquals("Finish authorizing in your browser…", card.noteShown)
        assertEquals("Open again", card.authorize.text)
    }

    @Test fun `a decline goes to the core, and a refused one says so on the card`() = withCard { card, host ->
        card.show(request())
        host!!.takes = false
        card.decline.performClick()
        assertEquals(listOf("cap-1"), host.declined)
        assertEquals("Could not decline. Try again.", card.noteShown)
        assertTrue(card.decline.isEnabled)
    }

    @Test fun `a request with input asks for it, and a refused answer says so on the card`() = withCard { card, host ->
        val secret = request().copy(provider = "secret", alias = "openai", label = "OpenAI API Key",
            input = AgentRequestInput(AgentRequestInput.Kind.SECRET, helpUrl = null, redirectUri = null))
        card.show(secret)
        assertEquals("Fill in", card.authorize.text)
        host!!.takes = false
        card.authorize.performClick()
        assertEquals(listOf("cap-1"), host.filled)
        assertEquals(emptyList<String>(), host.authorized)
        assertEquals("Could not save. Try again.", card.noteShown)
    }

    @Test fun `a location request shares through the host, says why it could not, and ends in a receipt`() = withCard { card, host ->
        val asked = AgentRequest("cap-2", AgentRequestStatus.PENDING, null, now + 90_000, createdAt = now, sourceMessageId = "msg-1",
            provider = AgentRequest.LOCATION_PROVIDER, reason = "Find cafes near you.", authorizationUrl = null, account = null)
        card.show(asked)
        assertEquals("Always share", card.authorize.text)
        assertTrue(card.authorize.isEnabled)
        assertEquals(android.view.View.VISIBLE, card.shareOnce.visibility)
        card.shareOnce.performClick()
        host!!.locationAnswer = AgentLocationAnswer.DENIED
        card.authorize.performClick()
        assertEquals(listOf("cap-2" to false, "cap-2" to true), host.shared)
        assertEquals("Location is off for Comma. Turn it on in your settings, then try again.", card.noteShown)
        card.show(asked.copy(status = AgentRequestStatus.COMPLETED, outcome = AgentRequestOutcome.SHARED))
        assertEquals("Location shared", card.receiptLine)
        card.show(asked.copy(status = AgentRequestStatus.COMPLETED, outcome = AgentRequestOutcome.DECLINED))
        assertEquals("You did not share your location", card.receiptLine)
    }

    @Test fun `while the phone answers by itself the card only says so, and asks again if it could not`() = withCard { card, host ->
        val asked = AgentRequest("cap-2", AgentRequestStatus.PENDING, null, now + 90_000, createdAt = now, sourceMessageId = null,
            provider = AgentRequest.LOCATION_PROVIDER, reason = "Find cafes near you.", authorizationUrl = null, account = null)
        host!!.answering = true
        card.show(asked)
        assertEquals("Getting your location…", card.noteShown)
        assertFalse(card.authorize.isEnabled)
        host.answering = false
        card.show(asked)
        assertEquals(null, card.noteShown)
        assertTrue(card.authorize.isEnabled)
    }

    @Test fun `a Router's plugin install reads from the core and comes back the same from the row`() {
        val read = AgentRequest.parse(org.json.JSONObject("""{"id":"cap-9","type":"plugin_install","status":"pending",
            "expiresAt":2000000,"sourceMessageId":"msg-1","plugin":{"id":"google-colab","name":"Google Colab",
            "reason":"Rendering needs a GPU.","brand":"google-colab","workspace":"wsp_test"}}"""))!!
        assertEquals(surf.comma.android.conversation.AgentPluginInstall("google-colab", "Google Colab", "google-colab", "wsp_test"), read.plugin)
        assertEquals("Rendering needs a GPU.", read.reason)
        assertNull(read.authorizationUrl)
        assertEquals("google-colab", markKey(read))
        assertTrue(ProviderMarks.hasArtwork(markKey(read)))
        assertEquals(read, decodeAgentRequest(read.json().toString()))
        assertNull("a request naming no Workspace has nowhere to install", AgentRequest.parse(org.json.JSONObject(
            """{"id":"cap-10","type":"plugin_install","status":"pending","plugin":{"id":"google-colab","name":"Google Colab","reason":""}}""")))
        val installed = AgentRequest.parse(org.json.JSONObject("""{"id":"cap-9","type":"plugin_install","status":"completed",
            "outcome":"installed","plugin":{"id":"google-colab","name":"Google Colab","reason":"","workspace":"wsp_test"}}"""))!!
        assertEquals(AgentRequestOutcome.INSTALLED, installed.outcome)
        assertEquals(AgentRequestShown.CONNECTED, agentRequestShown(installed, now))
    }

    @Test fun `adding a plugin installs it through the host, says when it could not, and ends in a receipt`() = withCard { card, host ->
        val asked = AgentRequest("cap-9", AgentRequestStatus.PENDING, null, now + 90_000, createdAt = now, sourceMessageId = "msg-1",
            provider = "google-colab", reason = "Rendering needs a GPU.", authorizationUrl = null, account = null,
            plugin = surf.comma.android.conversation.AgentPluginInstall("google-colab", "Google Colab", "google-colab", "wsp_test"))
        card.show(asked)
        assertEquals("Add to Comma", card.authorize.text)
        assertTrue(card.authorize.isEnabled)
        card.authorize.performClick()
        assertEquals(listOf("google-colab"), host!!.installed)
        assertEquals("Adding…", card.noteShown)
        assertFalse("one install at a time", card.authorize.isEnabled)
        card.authorize.performClick()
        assertEquals(1, host.installed.size)
        host.installDone!!(false)
        assertEquals("Could not add it. Try again.", card.noteShown)
        assertTrue(card.authorize.isEnabled)
        assertEquals(emptyList<String>(), host.authorized)
        card.show(asked.copy(status = AgentRequestStatus.COMPLETED, outcome = AgentRequestOutcome.INSTALLED))
        assertEquals("Added Google Colab", card.receiptLine)
        card.show(asked.copy(status = AgentRequestStatus.COMPLETED, outcome = AgentRequestOutcome.DECLINED))
        assertEquals("You did not add Google Colab", card.receiptLine)
    }

    @Test fun `the card closes into a receipt when its deadline passes`() = withCard { card, _ ->
        card.show(request(expiresAt = now + 31_000))
        now += 30_000
        shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofSeconds(30))
        assertNull(card.receiptLine)
        now += 1_000
        shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertEquals("The request expired", card.receiptLine)
    }

    @Test fun `an ended request shows how it ended, and a page that cannot answer shows the card without actions`() {
        withCard { card, _ ->
            card.show(request(AgentRequestStatus.COMPLETED, AgentRequestOutcome.CONNECTED, account = "octocat"))
            assertEquals("Connected GitHub · octocat", card.receiptLine)
            card.show(request(AgentRequestStatus.COMPLETED, AgentRequestOutcome.DECLINED))
            assertEquals("You did not connect GitHub", card.receiptLine)
            card.show(request(AgentRequestStatus.CANCELLED))
            assertEquals("The Agent withdrew this request", card.receiptLine)
        }
        withCard(host = null) { card, _ ->
            card.show(request())
            assertNull(card.receiptLine)
            assertFalse(card.authorize.isEnabled)
            assertFalse(card.decline.isEnabled)
        }
    }
}
