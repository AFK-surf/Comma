package surf.comma.android.notify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.conversation.PendingStatus

class ReplyWatchTest {
    private val watch = ReplyWatch(windowMillis = 1_000)

    @Test fun `leaving with a reply on its way starts a hold`() {
        assertTrue(ReplyWatch().chatHidden(state(userEntry(1), awaiting = true), 0, allowed = true))
        assertTrue(ReplyWatch().chatHidden(state(userEntry(1), participant = "active"), 0, allowed = true))
        assertTrue(ReplyWatch().chatHidden(state(userEntry(1), draftEntry()), 0, allowed = true))
        // The data layer reports an unanswered send as awaiting.
        assertTrue(ReplyWatch().chatHidden(state(pendingEntry(), awaiting = true), 0, allowed = true))
        // The agent reported itself done before its message replaced the reply's text.
        assertTrue(ReplyWatch().chatHidden(state(userEntry(1), draftEntry(ended = true), participant = "stopped"), 0,
            allowed = true))
    }

    @Test fun `leaving with nothing on its way, or notifications not allowed, holds nothing`() {
        assertFalse(watch.chatHidden(state(userEntry(1), agentEntry(2)), 0, allowed = true))
        assertFalse(watch.chatHidden(state(pendingEntry(status = PendingStatus.FAILED)), 0, allowed = true))
        assertFalse(watch.chatHidden(state(userEntry(1), awaiting = true), 0, allowed = false))
        assertFalse(watch.chatHidden(state(userEntry(1), awaiting = true, scope = null), 0, allowed = true))
        assertFalse(watch.holding)
    }

    @Test fun `the hold ends when the reply's message has landed`() {
        val held = scope()
        watch.chatHidden(state(agentEntry(2), userEntry(3), awaiting = true, scope = held), 0, allowed = true)
        watch.update(state(agentEntry(2), userEntry(3), agentEntry(4, "first part"), participant = "active",
            scope = held), 10)
        assertTrue(watch.holding)
        // Done, but the reply's text still stands in for its message.
        watch.update(state(agentEntry(2), userEntry(3), draftEntry(ended = true), participant = "stopped", scope = held), 20)
        assertTrue(watch.holding)
        watch.update(state(agentEntry(2), userEntry(3), agentEntry(5, "Done."), participant = "stopped", scope = held), 30)
        assertFalse(watch.holding)
    }

    @Test fun `a reply that ends without an answer ends the hold`() {
        val held = scope()
        watch.chatHidden(state(userEntry(1), awaiting = true, scope = held), 0, allowed = true)
        watch.update(state(userEntry(1), participant = "error", scope = held), 10)
        assertFalse(watch.holding)
    }

    @Test fun `the window running out ends the hold`() {
        val held = scope()
        watch.chatHidden(state(userEntry(1), awaiting = true, scope = held), 0, allowed = true)
        assertEquals(1_000L, watch.deadline)
        assertFalse(watch.expire(999))
        assertTrue(watch.holding)
        assertTrue(watch.expire(1_000))
        assertFalse(watch.holding)
    }

    @Test fun `a state after the deadline ends the hold even before the timer fires`() {
        val held = scope()
        watch.chatHidden(state(userEntry(1), awaiting = true, scope = held), 0, allowed = true)
        watch.update(state(userEntry(1), awaiting = true, scope = held), 1_000)
        assertFalse(watch.holding)
    }

    @Test fun `showing the chat ends the hold`() {
        watch.chatHidden(state(userEntry(1), awaiting = true, scope = scope()), 0, allowed = true)
        watch.chatShown()
        assertFalse(watch.holding)
        assertTrue(watch.chatVisible)
    }

    @Test fun `another account's state ends the hold`() {
        watch.chatHidden(state(userEntry(1), awaiting = true, scope = scope()), 0, allowed = true)
        watch.update(state(userEntry(1), awaiting = true, scope = scope(2, ACCOUNT_B)), 10)
        assertFalse(watch.holding)
    }
}
