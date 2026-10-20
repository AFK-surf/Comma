package surf.comma.android.notify

import surf.comma.android.conversation.replyOf
import surf.comma.android.auth.ConversationScope
import surf.comma.android.conversation.ChatMessage
import surf.comma.android.conversation.ChatRole
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.MessagePart
import surf.comma.android.conversation.ParticipantStatus
import surf.comma.android.conversation.PendingMessage
import surf.comma.android.conversation.PendingStatus
import surf.comma.android.conversation.ReplyDraft
import surf.comma.android.conversation.TimelineEntry

// All identifiers and text below are invented test data.
internal const val ACCOUNT_A = "usr_test_a"
internal const val ACCOUNT_B = "usr_test_b"
internal const val CHAT = "cnv_test_main"

internal fun scope(generation: Long = 1, account: String = ACCOUNT_A, chat: String = CHAT) =
    ConversationScope(generation, account, "grp_test_1", chat)

internal fun userEntry(seq: Long, text: String = "question $seq") = TimelineEntry.Message("r:req-$seq",
    chatMessage(seq, ChatRole.USER, "user", text))

internal fun agentEntry(seq: Long, text: String = "answer $seq") = TimelineEntry.Message("m:msg_test_$seq",
    chatMessage(seq, ChatRole.ASSISTANT, "agent", text))

internal fun pendingEntry(id: String = "req-local-1", status: PendingStatus = PendingStatus.SENDING) =
    TimelineEntry.Pending("r:$id", PendingMessage(id, "question", emptyList(), null, 0L, status))

internal fun draftEntry(text: String = "partial", ended: Boolean = false) = ReplyDraft("resp-1", listOf("msg_test_1"),
    "draft-a", 1, text, ended).let { TimelineEntry.Draft(it.key, it) }

internal fun state(
    vararg timeline: TimelineEntry,
    scope: ConversationScope? = scope(),
    awaiting: Boolean = false,
    participant: String? = null,
    title: String? = "Test chat",
) = ConversationState(
    groupId = scope?.groupId, conversationId = scope?.conversationId, title = title, timeline = timeline.toList(),
    participant = participant?.let { ParticipantStatus("ptp_test_agent", it, null, null, null, null) },
    reply = replyOf(participant?.let { ParticipantStatus("ptp_test_agent", it, null, null, null, null) }, awaiting,
        timeline.toList()),
    scope = scope,
)

private fun chatMessage(seq: Long, role: ChatRole, actor: String, text: String) = ChatMessage(
    messageId = "msg_test_$seq", seq = seq, role = role, actorType = actor, agentId = null, clientRequestId = null,
    replyToMessageId = null, threadRootMessageId = null, createdAt = null, parts = listOf(MessagePart.Text(text)),
    attachments = emptyList(), refs = emptyList(), workspaceFiles = emptyList(),
)

/** The core's notice for agent message [seq] of [chat], as it words one in Home chat. */
internal fun noticeOf(seq: Long, text: String = "answer $seq", chat: String = CHAT) =
    AppendedNotice("grp_test_1", chat, "msg_test_$seq", "Comma", text)
