package surf.comma.android.chat.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.auth.Account
import surf.comma.android.auth.AuthProblem
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.ConnectionStep
import surf.comma.android.auth.Workspace
import surf.comma.android.auth.WorkspaceSelection
import surf.comma.android.conversation.ChatMessage
import surf.comma.android.conversation.ChatRole
import surf.comma.android.conversation.Connection
import surf.comma.android.conversation.ConversationProblem
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.ui.connection.ConnectionRetryTarget

class ConnectionNoticeControllerTest {
    private var now = 0L
    private val wakes = mutableListOf<Long>()
    private val retries = mutableListOf<ConnectionRetryTarget>()
    private val networkChanges = mutableListOf<Boolean>()
    private val controller = ConnectionNoticeController(
        clock = { now }, wakeIn = wakes::add, onChanged = {}, onRetry = retries::add, onNetworkChanged = networkChanges::add,
    )
    private val connected = AuthState.Connected(Account("a", "a@example.test", null, "active"),
        WorkspaceSelection(Workspace("w", "g", "Workspace"), "chat"))
    private val message = TimelineEntry.Message("m1", ChatMessage("m1", 1, ChatRole.USER, "user", null, null, null, null, null,
        emptyList(), emptyList(), emptyList(), emptyList()))

    /** A chat with something on screen, so the full-page error never covers it. */
    private fun chat(connection: Connection, problem: ConversationProblem? = null) =
        ConversationState(cacheLoaded = true, timeline = listOf(message), connection = connection, problem = problem)

    private fun advance(millis: Long) {
        now += millis
        controller.tick()
    }

    @Test fun `a short cold start never shows the notice`() {
        controller.present(AuthState.Starting, null)
        controller.present(AuthState.Connecting(ConnectionStep.SESSION), chat(Connection.CONNECTING))
        advance(ConnectionNoticeController.DELAY_MILLIS * 2)
        assertNull("connecting without a failure is not offline", controller.shown)
        controller.present(connected, chat(Connection.LIVE))
        assertNull(controller.shown)
    }

    @Test fun `a brief failure that recovers within the delay never shows`() {
        controller.present(connected, chat(Connection.LIVE))
        controller.present(connected, chat(Connection.RECONNECTING, ConversationProblem.NETWORK))
        advance(ConnectionNoticeController.DELAY_MILLIS - 1)
        assertNull(controller.shown)
        controller.present(connected, chat(Connection.LIVE))
        advance(10_000)
        assertNull(controller.shown)
    }

    @Test fun `a lasting loss shows once the delay is up, stays through retries and goes once live`() {
        controller.connectivityChanged(true)
        controller.present(connected, chat(Connection.LIVE))
        controller.present(connected, chat(Connection.RECONNECTING, ConversationProblem.NETWORK))
        assertEquals("asks to be woken when the delay is up", ConnectionNoticeController.DELAY_MILLIS, wakes.last())
        advance(ConnectionNoticeController.DELAY_MILLIS)
        assertEquals(ConnectionNotice.OFFLINE, controller.shown)

        controller.retry()
        assertEquals(listOf(ConnectionRetryTarget.CONVERSATION), retries)
        // The retry clears the problem while it connects; the notice does not blink off and on.
        controller.present(connected, chat(Connection.CONNECTING))
        assertEquals(ConnectionNotice.OFFLINE, controller.shown)
        controller.present(connected, chat(Connection.RECONNECTING, ConversationProblem.NETWORK))
        assertEquals(ConnectionNotice.OFFLINE, controller.shown)

        controller.present(connected, chat(Connection.LIVE))
        assertNull(controller.shown)
    }

    @Test fun `the delay counts from the moment the connection was lost`() {
        controller.present(connected, chat(Connection.LIVE))
        controller.present(connected, chat(Connection.CONNECTING))
        advance(ConnectionNoticeController.DELAY_MILLIS + 500)
        controller.present(connected, chat(Connection.RECONNECTING, ConversationProblem.NETWORK))
        assertEquals(ConnectionNotice.OFFLINE, controller.shown)
    }

    @Test fun `a failed session check shows its own line and retries the session`() {
        controller.present(connected, chat(Connection.LIVE))
        controller.present(AuthState.Retry(AuthProblem.SERVER), chat(Connection.LIVE))
        advance(ConnectionNoticeController.DELAY_MILLIS)
        assertEquals(ConnectionNotice.FAILED, controller.shown)
        controller.retry()
        assertEquals(listOf(ConnectionRetryTarget.SESSION), retries)
    }

    @Test fun `the notice stays off while the full-page error owns an empty chat`() {
        val empty = ConversationState(cacheLoaded = true, connection = Connection.RECONNECTING, problem = ConversationProblem.NETWORK)
        controller.present(connected, empty)
        advance(10_000)
        assertNull(controller.shown)
        controller.connectivityChanged(false)
        controller.present(AuthState.Retry(AuthProblem.NETWORK), empty)
        controller.connectivityChanged(true)
        assertTrue("the page retries the session itself", retries.isEmpty())
    }

    @Test fun `a hidden chat shows nothing`() {
        controller.present(connected, chat(Connection.RECONNECTING, ConversationProblem.NETWORK))
        advance(ConnectionNoticeController.DELAY_MILLIS)
        controller.present(connected, chat(Connection.BACKGROUND))
        assertNull(controller.shown)
    }

    @Test fun `network changes reach the conversation, and a session that failed retries when the network returns`() {
        controller.connectivityChanged(null)
        controller.connectivityChanged(true)
        assertTrue("the first known value is not a change", networkChanges.isEmpty())
        controller.connectivityChanged(false)
        controller.present(AuthState.Retry(AuthProblem.NETWORK), chat(Connection.LIVE))
        controller.connectivityChanged(true)
        assertEquals(listOf(false, true), networkChanges)
        assertEquals(listOf(ConnectionRetryTarget.SESSION), retries)
    }
}
