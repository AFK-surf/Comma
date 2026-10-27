// A window's view of one conversation (`chatView`): the coordinator's projection for that window, as the state a
// conversation view renders.
import type { ConversationProjection } from "@comma/chat-contract";
import type { ConversationChannelState } from "./model/conversationChannel.ts";

export function projectionToChannelState(
  projection: ConversationProjection
): ConversationChannelState {
  const conversation = projection.conversation;
  return {
    activity: projection.activity,
    assistantDraft: projection.assistantDraft,
    awaitingReply: projection.awaitingReply,
    awaitingSince: projection.awaitingSince,
    awaitingTimedOut: projection.awaitingTimedOut,
    awaitingTurnKey: projection.awaitingTurnKey,
    connection: projection.connection,
    conversation: conversation
      ? {
          client_platform: conversation.clientPlatform,
          created_at: conversation.createdAt,
          group_id: conversation.groupId,
          id: conversation.id,
          kind: conversation.kind,
          labels: conversation.labels,
          messages: [],
          origin: conversation.origin,
          review_version: conversation.reviewVersion,
          status: conversation.status,
          title: conversation.title,
          updated_at: conversation.updatedAt,
        }
      : undefined,
    draft: projection.draft,
    draftAttachments: projection.draftAttachments.map((attachment) => ({
      ...attachment,
      error: attachment.error,
      path: attachment.path,
    })),
    questionAttachments: projection.questionAttachments
      ? Object.fromEntries(
          Object.entries(projection.questionAttachments).map(([id, attachments]) => [
            id,
            attachments.map((attachment) => ({
              ...attachment,
              error: attachment.error,
              path: attachment.path,
            })),
          ])
        )
      : undefined,
    errorKind: projection.errorKind,
    history: projection.history,
    lastBackoffMs: projection.lastBackoffMs,
    locallyAwaitingReply: projection.locallyAwaitingReply === true,
    messages: projection.messages.map(contractMessageToChannelMessage),
    pending: projection.pending.map((pending) => ({
      ...pending,
      error: pending.error,
      skills: pending.skills,
    })),
    participantStatus: projection.participantStatus,
    participantStatuses: projection.participantStatuses,
    boundWorker: projection.boundWorker,
    taskRun: projection.taskRun,
    taskRunBlocked: projection.taskRunBlocked,
    unsupported: projection.unsupported,
    reply: projection.reply,
    serverMessages: projection.serverMessages.map(contractMessageToChannelMessage),
    status: projection.status,
    syncWarning: projection.syncWarning,
    taskActivity: projection.taskActivity,
  };
}

function contractMessageToChannelMessage(
  message: ConversationProjection["messages"][number]
): ConversationChannelState["messages"][number] {
  return {
    ...message,
    attachments: message.attachments.map((attachment) => ({
      ...attachment,
      fileName: attachment.fileName,
      mimeType: attachment.mimeType,
      size: attachment.size,
      title: attachment.title,
    })),
    blocksKey: message.blocksKey,
    clientRequestId: message.clientRequestId,
    createdAt: message.createdAt,
    createdBy: message.createdBy,
    error: message.error,
    // The native snapshot has already passed chatMessageSchema. Preserve the
    // discriminated union verbatim so adding an inline kind cannot create a
    // third, silently lossy registry at this runtime handoff.
    parts: message.parts ?? [{ kind: "markdown", text: message.text }],
    refs: message.refs.map((reference) => ({
      ...reference,
      kind:
        reference.kind === "user_chat" || reference.kind === "agent_task"
          ? reference.kind
          : undefined,
      title: reference.title,
    })),
    status: message.status,
  };
}
