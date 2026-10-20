package surf.comma.android

import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.render.MessageAction
import surf.comma.android.chat.render.MessageActionLabels
import surf.comma.android.chat.render.messageActionsFor
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 失败行尾的显式按钮。
 *
 * 以前重试是「整格任意位置轻点」——读一半失败回答随手一点就把请求重发了。
 * 现在只有失败/中断行带按钮，其余行一个可点目标都没有。
 */
class MessageActionsTest {

    private val labels = MessageActionLabels(retry = "重试", discard = "放弃")

    private fun message(
        role: ChatRole,
        status: MessageStatus,
        retryable: Boolean = false,
        text: String = "内容",
    ) = ChatMessage(
        id = 1,
        conversationId = "c",
        turnId = "t",
        role = role,
        text = text,
        createdAt = 0,
        status = status,
        retryable = retryable,
    )

    private fun kinds(message: ChatMessage) =
        messageActionsFor(message, labels).map { it.first }

    @Test
    fun aCompletedAnswerHasNoTapTargets() {
        assertEquals(
            emptyList<MessageAction>(),
            kinds(message(ChatRole.AGENT, MessageStatus.COMPLETED)),
        )
    }

    @Test
    fun aStreamingAnswerHasNoTapTargets() {
        assertEquals(
            emptyList<MessageAction>(),
            kinds(message(ChatRole.AGENT, MessageStatus.STREAMING)),
        )
        assertEquals(
            emptyList<MessageAction>(),
            kinds(message(ChatRole.AGENT, MessageStatus.PENDING)),
        )
    }

    @Test
    fun aRetryableFailureOffersRetryAndDiscard() {
        assertEquals(
            listOf(MessageAction.RETRY, MessageAction.DISCARD),
            kinds(message(ChatRole.AGENT, MessageStatus.FAILED, retryable = true)),
        )
    }

    /** Core 说过不能安全重放时不给「重试」——那会重复执行手机动作。 */
    @Test
    fun anUnsafeFailureOnlyOffersDiscard() {
        assertEquals(
            listOf(MessageAction.DISCARD),
            kinds(message(ChatRole.AGENT, MessageStatus.FAILED, retryable = false)),
        )
    }

    /** An unsent user message has no buttons; its failure mark and note open retry / delete. */
    @Test
    fun anUndeliveredUserMessageHasNoButtons() {
        assertEquals(
            emptyList<MessageAction>(),
            kinds(message(ChatRole.USER, MessageStatus.FAILED)),
        )
    }

    @Test
    fun aDeliveredOrInFlightUserMessageHasNoTapTargets() {
        assertEquals(
            emptyList<MessageAction>(),
            kinds(message(ChatRole.USER, MessageStatus.COMPLETED)),
        )
        assertEquals(
            emptyList<MessageAction>(),
            kinds(message(ChatRole.USER, MessageStatus.PENDING)),
        )
    }

    @Test
    fun theLabelsComeFromTheUiLayer() {
        val english = MessageActionLabels(retry = "Retry", discard = "Discard")
        assertEquals(
            listOf("Retry", "Discard"),
            messageActionsFor(
                message(ChatRole.AGENT, MessageStatus.FAILED, retryable = true),
                english,
            ).map { it.second },
        )
    }
}
