import type { ConversationProjection } from "@comma/chat-contract";
import type { ConversationChannelState } from "../../../components/chat/model/conversationChannel";

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
          schedule: conversation.schedule,
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
    errorKind: projection.errorKind,
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
    serverMessages: projection.serverMessages.map(contractMessageToChannelMessage),
    status: projection.status,
    syncWarning: projection.syncWarning,
  };
}

/**
 * The seeded transcript and conversation metadata kept beneath a projection
 * that is not ready yet, overlaid with that projection's current pending rows.
 */
export function overlaySeededTranscript(
  next: ConversationChannelState,
  seeded: ConversationChannelState
): ConversationChannelState {
  const pendingRows = next.messages.filter((item) => item.source === "pending");
  const showError = next.status === "error" || seeded.status === "error";
  return {
    ...next,
    conversation: next.conversation ?? seeded.conversation,
    errorKind: showError ? (next.errorKind ?? seeded.errorKind) : next.errorKind,
    messages: [...seeded.serverMessages, ...pendingRows],
    serverMessages: seeded.serverMessages,
    status: showError ? ("error" as const) : ("ready" as const),
    syncWarning: "stale",
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
