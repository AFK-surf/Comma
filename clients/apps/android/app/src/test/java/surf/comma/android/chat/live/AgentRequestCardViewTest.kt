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
import surf.comma.android.conversation.AgentRequestOutcome
import surf.comma.android.conversation.AgentRequestStatus
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
        var takes = true

        override fun authorize(url: String) {
            authorized += url
        }

        override fun decline(requestId: String, done: (Boolean) -> Unit) {
            declined += requestId
            done(takes)
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
