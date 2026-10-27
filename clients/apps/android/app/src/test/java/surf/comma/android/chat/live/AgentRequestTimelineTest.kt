package surf.comma.android.chat.live

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import surf.comma.android.conversation.AgentRequest
import surf.comma.android.conversation.AgentRequestOutcome
import surf.comma.android.conversation.AgentRequestStatus
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.conversation.display

// Invented test data only.
class AgentRequestTimelineTest {
    private fun message(seq: Long, actor: String, words: String): TimelineEntry.Message {
        val json = JSONObject().put("message_id", "msg_$seq").put("seq", seq).put("actor_type", actor)
            .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", words)))
            .put("created_at", 1_700_000_000_000L + seq)
            .apply { if (actor == "agent") put("agent_id", "agt_1") }
        return TimelineEntry.Message("m:msg_$seq", display(json)!!)
    }

    private fun request(id: String, source: String?, status: AgentRequestStatus = AgentRequestStatus.PENDING,
                        outcome: AgentRequestOutcome? = null, createdAt: Long = 1) =
        AgentRequest(id, status, outcome, expiresAt = null, createdAt = createdAt, sourceMessageId = source,
            provider = "github", reason = "An app keeps its code in GitHub.",
            authorizationUrl = "https://github.com/login/oauth/authorize?state=s", account = null)

    private fun kinds(state: ConversationState, requests: List<AgentRequest>) =
        mapConversation(state, requests = requests).rows.map { row ->
            if (row.cardKind == LiveRowKinds.AGENT_REQUEST) "card:" + decodeAgentRequest(row.cardPayload)!!.id
            else "${row.role}:${row.text}"
        }

    @Test fun `a card sits under the reply to the message its turn served, a waiting one on the newest turn`() {
        val state = ConversationState(conversationId = "cnv_1", timeline = listOf(
            message(1, "user", "Hello"),
            message(2, "agent", "First answer"),
            message(3, "agent", "Second answer"),
            message(4, "user", "Second"),
        ))
        val answered = request("cap-1", "msg_1", AgentRequestStatus.COMPLETED, AgentRequestOutcome.CONNECTED)
        val waiting = request("cap-2", "msg_4", createdAt = 2)
        assertEquals(
            listOf("USER:Hello", "AGENT:First answer", "card:cap-1",
                "AGENT:Second answer", "USER:Second", "card:cap-2"),
            kinds(state, listOf(waiting, answered)),
        )
    }

    @Test fun `a finished request whose turn is not loaded shows nowhere, rather than on the newest turn`() {
        val state = ConversationState(conversationId = "cnv_1", timeline = listOf(
            message(5, "user", "Hello"),
            message(6, "agent", "Answer"),
        ))
        val older = request("cap-1", "msg_0", AgentRequestStatus.COMPLETED, AgentRequestOutcome.DECLINED)
        val unsourced = request("cap-2", null, AgentRequestStatus.EXPIRED)
        val waiting = request("cap-3", null)
        assertEquals(listOf("USER:Hello", "AGENT:Answer", "card:cap-3"), kinds(state, listOf(older, unsourced, waiting)))
    }

    @Test fun `the core's request reads back the same, and a kind without a card is left out`() {
        val read = request("cap-1", "msg_1", AgentRequestStatus.COMPLETED, AgentRequestOutcome.CONNECTED)
            .copy(expiresAt = 2_000_000, account = "octocat")
        assertEquals(read, AgentRequest.parse(read.json()))
        val value = JSONObject().put("requests", JSONArray()
            .put(read.json())
            .put(JSONObject().put("id", "cap-x").put("type", "location").put("status", "pending")))
        assertEquals(listOf(read), AgentRequest.list(value))
        // Only an https page opens in the browser.
        val plain = read.json().apply { getJSONObject("oauth").put("authorizationUrl", "http://example.com/authorize") }
        assertEquals(null, AgentRequest.parse(plain)!!.authorizationUrl)
    }
}
