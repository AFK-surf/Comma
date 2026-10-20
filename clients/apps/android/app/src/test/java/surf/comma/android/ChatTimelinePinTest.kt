package surf.comma.android

import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.chat.render.lastTurnHeight
import surf.comma.android.chat.render.lastTurnStartIndex
import surf.comma.android.chat.render.latestUserTurnId
import org.junit.Assert.assertEquals
import org.junit.Test

class ChatTimelinePinTest {

    @Test
    fun lastTurnIsTheTrailingUserAndReplies() {
        val messages = listOf(
            prepared(id = 1, role = ChatRole.USER, height = 80),
            prepared(id = 2, role = ChatRole.AGENT, height = 200),
            prepared(id = 3, role = ChatRole.USER, height = 50),
            prepared(id = 4, role = ChatRole.AGENT, height = 120),
        )
        assertEquals(170, lastTurnHeight(messages))
    }

    @Test
    fun lastTurnIsJustTheUserWhileWaitingForAReply() {
        val messages = listOf(
            prepared(id = 1, role = ChatRole.USER, height = 80),
            prepared(id = 2, role = ChatRole.AGENT, height = 200),
            prepared(id = 3, role = ChatRole.USER, height = 50),
        )
        assertEquals(50, lastTurnHeight(messages))
        assertEquals(2, lastTurnStartIndex(messages))
    }

    @Test
    fun lastTurnFallsBackToTheLastItemWhenThereIsNoUser() {
        val messages = listOf(
            prepared(id = 1, role = ChatRole.SYSTEM, height = 20),
            prepared(id = 2, role = ChatRole.AGENT, height = 40),
        )
        assertEquals(40, lastTurnHeight(messages))
    }

    @Test
    fun assistantUpdatesInsideTheSameTurnDoNotLookLikeANewTurn() {
        val user = prepared(id = 10, role = ChatRole.USER, height = 50, turnId = "turn-a")
        val waiting = listOf(user)
        val streaming = waiting + prepared(
            id = 11,
            role = ChatRole.AGENT,
            height = 90,
            turnId = "turn-a",
        )
        assertEquals("turn-a", latestUserTurnId(waiting))
        assertEquals(latestUserTurnId(waiting), latestUserTurnId(streaming))
    }

    private fun prepared(
        id: Long,
        role: ChatRole,
        height: Int,
        turnId: String = "turn-$id",
    ) = PreparedChatMessage(
        message = ChatMessage(
            id = id,
            conversationId = "c",
            turnId = turnId,
            role = role,
            text = "x",
            createdAt = 0,
        ),
        cacheKey = "$id",
        contents = emptyList(),
        blocks = emptyList(),
        bubbleWidthPx = 0,
        bubbleHeightPx = 0,
        bubbleTopPx = 0,
        cellHeightPx = height,
        horizontalPaddingPx = 0,
        verticalPaddingPx = 0,
        sideMarginPx = 0,
        topMarginPx = 0,
        cornerRadiusPx = 0f,
        drawBubble = false,
        imageCornerRadiusPx = 0f,
        imageSources = emptyList(),
    )

}
