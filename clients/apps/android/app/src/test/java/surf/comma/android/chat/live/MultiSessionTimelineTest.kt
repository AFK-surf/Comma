package surf.comma.android.chat.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.conversation.ParticipantIssueDetail
import surf.comma.android.conversation.WorkerSession

class MultiSessionTimelineTest {

    @Test
    fun sameRunSpeakerSplitsDistinctParticipantIdsAndMergesMatchingOnes() {
        val lead1 = ChatMessage(
            id = 1L,
            conversationId = "cnv_1",
            turnId = "t1",
            role = ChatRole.AGENT,
            text = "Lead msg 1",
            createdAt = 1_000L,
            speaker = "worker",
            participantId = "prt_lead",
        )
        val lead2 = lead1.copy(id = 2L, text = "Lead msg 2")
        val reviewer = lead1.copy(id = 3L, text = "Reviewer msg", participantId = "prt_reviewer")
        val legacy = lead1.copy(id = 4L, text = "Legacy msg", participantId = null)

        assertTrue(sameRunSpeaker(lead1, lead2))
        assertFalse(sameRunSpeaker(lead1, reviewer))
        assertTrue(sameRunSpeaker(lead1, legacy))
    }

    @Test
    fun markSpeakerRunsShowsWriterLabelForMultiSessionWorkerRows() {
        val rows = mutableListOf(
            ChatMessage(
                id = 1L,
                conversationId = "cnv_1",
                turnId = "t1",
                role = ChatRole.AGENT,
                text = "Lead first",
                createdAt = 1_000L,
                speaker = "worker",
                participantId = "prt_lead",
                otherWriterName = "Lead @lead",
            ),
            ChatMessage(
                id = 2L,
                conversationId = "cnv_1",
                turnId = "t1",
                role = ChatRole.AGENT,
                text = "Lead second",
                createdAt = 1_001L,
                speaker = "worker",
                participantId = "prt_lead",
                otherWriterName = "Lead @lead",
            ),
            ChatMessage(
                id = 3L,
                conversationId = "cnv_1",
                turnId = "t1",
                role = ChatRole.AGENT,
                text = "Reviewer first",
                createdAt = 1_002L,
                speaker = "worker",
                participantId = "prt_rev",
                otherWriterName = "Reviewer @reviewer",
            ),
        )

        markSpeakerRuns(rows)

        assertTrue(rows[0].writerLabel)
        assertFalse(rows[0].speakerAvatar)
        assertFalse(rows[1].writerLabel)
        assertTrue(rows[1].speakerAvatar)
        assertTrue(rows[2].writerLabel)
        assertTrue(rows[2].speakerAvatar)
    }

    @Test
    fun workerSessionHoldsWaitingStateAndIssueDetail() {
        val detail = ParticipantIssueDetail(
            source = "openai",
            profileId = "prof_1",
            profileName = "Work",
            resetAt = 1_720_003_600L,
            credits = true,
            trigger = "background",
        )
        val session = WorkerSession(
            participantId = "prt_rev",
            actorId = "agt_w",
            slot = "reviewer",
            label = "Reviewer",
            model = "gpt-6.2-sol",
            isPrimary = false,
            subscribed = true,
            state = "waiting",
            status = "Waiting",
            updatedAt = 1_720_000_002L,
            issue = "rate_limit",
            issueDetail = detail,
        )

        assertEquals("waiting", session.state)
        assertEquals(true, session.subscribed)
        assertEquals("openai", session.issueDetail?.source)
        assertEquals(true, session.issueDetail?.credits)
        assertNull(WorkerSession(participantId = "prt_1", slot = "lead", label = "Lead").issueDetail)
    }

    @Test
    fun taskDockRenderKeyTracksHasLiveWorkerStateAcrossSubscribedTransitions() {
        val lead = WorkerSession(
            participantId = "prt_lead",
            slot = "lead",
            label = "Lead",
            isPrimary = true,
            subscribed = true,
            state = "active",
            status = "Working",
        )
        val stoppedSubscribed = WorkerSession(
            participantId = "prt_rev",
            slot = "reviewer",
            label = "Reviewer",
            isPrimary = false,
            subscribed = true,
            state = "stopped",
            status = "",
        )
        val stoppedUnsubscribed = stoppedSubscribed.copy(subscribed = false)

        org.junit.Assert.assertTrue(surf.comma.android.shell.hasLiveWorkerState(stoppedSubscribed))
        org.junit.Assert.assertFalse(surf.comma.android.shell.hasLiveWorkerState(stoppedUnsubscribed))

        val keyWithSub = surf.comma.android.shell.workerSessionRenderKey(listOf(lead, stoppedSubscribed))
        val keyWithoutSub = surf.comma.android.shell.workerSessionRenderKey(listOf(lead, stoppedUnsubscribed))
        org.junit.Assert.assertNotEquals(keyWithSub, keyWithoutSub)
        assertEquals(keyWithSub, surf.comma.android.shell.workerSessionRenderKey(listOf(lead, stoppedUnsubscribed.copy(subscribed = true))))
    }
}
