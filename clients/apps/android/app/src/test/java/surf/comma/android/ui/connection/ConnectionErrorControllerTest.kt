package surf.comma.android.ui.connection

import org.junit.Assert.*
import org.junit.Test
import surf.comma.android.auth.*
import surf.comma.android.conversation.*

class ConnectionErrorControllerTest {
    private val retries = mutableListOf<ConnectionRetryTarget>()
    private val controller = ConnectionErrorController({}, retries::add)
    private val connected = AuthState.Connected(Account("a", "a@example.test", null, "active"),
        WorkspaceSelection(Workspace("w", "g", "Workspace"), "chat"))
    private fun chat(problem: ConversationProblem? = ConversationProblem.NETWORK) = ConversationState(
        cacheLoaded = true, connection = Connection.RECONNECTING, problem = problem,
    )

    @Test fun `IO failure is offline only when the system reports no internet`() {
        controller.present(AuthState.Retry(AuthProblem.NETWORK))
        assertEquals(ConnectionErrorReason.UNREACHABLE, controller.state?.reason)
        controller.connectivityChanged(false)
        assertEquals(ConnectionErrorReason.OFFLINE, controller.state?.reason)
    }

    @Test fun `both auth 5xx categories show service unavailable when online`() {
        controller.connectivityChanged(true)
        for (problem in listOf(AuthProblem.SERVER, AuthProblem.EMAIL_UNAVAILABLE)) {
            controller.present(AuthState.Retry(problem))
            assertEquals(ConnectionErrorReason.SERVICE, controller.state?.reason)
        }
    }

    @Test fun `conversation network and server failures have distinct reasons`() {
        controller.connectivityChanged(true)
        controller.present(connected, chat())
        assertEquals(ConnectionErrorReason.UNREACHABLE, controller.state?.reason)
        controller.present(connected, chat(ConversationProblem.SERVER))
        assertEquals(ConnectionErrorReason.SERVICE, controller.state?.reason)
        controller.connectivityChanged(false)
        assertEquals(ConnectionErrorReason.OFFLINE, controller.state?.reason)
    }

    @Test fun `storage workspace and throttling errors never claim the device is offline`() {
        controller.connectivityChanged(false)
        mapOf(AuthProblem.STORAGE to ConnectionErrorReason.STORAGE, AuthProblem.NO_WORKSPACE to ConnectionErrorReason.NO_WORKSPACE,
            AuthProblem.RATE_LIMITED to ConnectionErrorReason.RATE_LIMITED).forEach { (problem, reason) ->
            controller.present(AuthState.Retry(problem))
            assertEquals(reason, controller.state?.reason)
        }
        controller.present(connected, chat(ConversationProblem.FORBIDDEN).copy(connection = Connection.PAUSED))
        assertEquals(ConnectionErrorReason.CHAT_UNAVAILABLE, controller.state?.reason)
    }

    @Test fun `session retry takes priority and holds its reason through connecting`() {
        controller.connectivityChanged(false)
        controller.present(AuthState.Retry(AuthProblem.NETWORK), chat(ConversationProblem.SERVER))
        controller.retry()
        controller.retry()
        assertEquals(listOf(ConnectionRetryTarget.SESSION), retries)
        assertTrue(controller.state!!.busy)
        controller.present(AuthState.Connecting(ConnectionStep.SESSION), chat())
        controller.connectivityChanged(true)
        assertEquals(ConnectionErrorReason.OFFLINE, controller.state?.reason)
        assertTrue(controller.state!!.busy)
        assertEquals(1, retries.size)
        controller.present(AuthState.Retry(AuthProblem.SERVER), chat())
        assertFalse(controller.state!!.busy)
        assertEquals(ConnectionErrorReason.SERVICE, controller.state?.reason)
        controller.retry()
        assertEquals(2, retries.size)
    }

    @Test fun `connectivity recovery retries once and duplicate callbacks cannot restart it`() {
        controller.connectivityChanged(false)
        controller.present(AuthState.Retry(AuthProblem.NETWORK))
        controller.connectivityChanged(true)
        controller.connectivityChanged(true)
        controller.retry()
        assertEquals(listOf(ConnectionRetryTarget.SESSION), retries)
        controller.present(AuthState.Connecting(ConnectionStep.SESSION))
        controller.present(connected)
        assertNull(controller.state)
    }

    @Test fun `conversation recovery leaves backoff once then follows repository progress`() {
        controller.connectivityChanged(false)
        controller.present(connected, chat())
        controller.connectivityChanged(true)
        assertEquals(listOf(ConnectionRetryTarget.CONVERSATION), retries)
        assertTrue(controller.state!!.busy)
        controller.present(connected, chat(null).copy(connection = Connection.CONNECTING))
        assertTrue(controller.state!!.busy)
        controller.retry()
        assertEquals(1, retries.size)
        controller.present(connected, chat(ConversationProblem.SERVER))
        assertFalse(controller.state!!.busy)
        controller.present(connected, chat(null).copy(connection = Connection.LIVE))
        assertNull(controller.state)
    }

    @Test fun `already online first observation and irrelevant recovery do not cause requests`() {
        controller.present(AuthState.Retry(AuthProblem.NETWORK))
        controller.connectivityChanged(true)
        assertTrue(retries.isEmpty())
        controller.connectivityChanged(false)
        controller.present(AuthState.Retry(AuthProblem.STORAGE))
        controller.connectivityChanged(true)
        assertTrue(retries.isEmpty())
        controller.present(AuthState.Login())
        controller.retry()
        assertNull(controller.state)
    }

    @Test fun `wait for cache and never cover existing messages including pending sends`() {
        controller.present(AuthState.Retry(AuthProblem.NETWORK), chat().copy(cacheLoaded = false))
        assertNull(controller.state)
        val pending = PendingMessage("id", "Hello", emptyList(), null, 0, PendingStatus.FAILED)
        controller.present(AuthState.Retry(AuthProblem.NETWORK), chat().copy(timeline = listOf(TimelineEntry.Pending("id", pending))))
        assertNull(controller.state)
        controller.connectivityChanged(false)
        controller.connectivityChanged(true)
        assertTrue(retries.isEmpty())
    }

    @Test fun `conflated retry progress still unlocks on an equal but fresh failure`() {
        controller.present(connected, chat())
        controller.retry()
        assertTrue(controller.state!!.busy)
        controller.present(connected, chat())
        assertFalse(controller.state!!.busy)
        controller.retry()
        assertEquals(2, retries.size)
    }

    @Test fun `return to login removes a busy error and ignored retry unlocks the action`() {
        controller.present(AuthState.Retry(AuthProblem.NETWORK))
        controller.retry()
        controller.sessionRetryFinished()
        assertFalse(controller.state!!.busy)
        controller.retry()
        controller.present(AuthState.Login())
        assertNull(controller.state)
    }
}
