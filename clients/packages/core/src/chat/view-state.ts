// A window's view of one conversation (`chatView`): the coordinator's projection for that window, as the state a
// conversation view renders.
import type { ConversationProjection } from "@comma/chat-contract";
import { madeOnce, mapKept } from "@comma/core-kernel";
import type { ConversationChannelState } from "./model/conversationChannel.ts";

/** `last`: the projection the view showed before and its state, whose messages are kept where they still stand. */
export function projectionToChannelState(
  projection: ConversationProjection,
  last?: { projection: ConversationProjection; state: ConversationChannelState }
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
    draftAttachments: projection.draftAttachments.map(draftAttachment),
    questionAttachments: projection.questionAttachments
      ? Object.fromEntries(
          Object.entries(projection.questionAttachments).map(([id, attachments]) => [
            id,
            attachments.map(draftAttachment),
          ])
        )
      : undefined,
    errorKind: projection.errorKind,
    history: projection.history,
    lastBackoffMs: projection.lastBackoffMs,
    locallyAwaitingReply: projection.locallyAwaitingReply === true,
    messages: mapKept(
      projection.messages,
      last && { from: last.projection.messages, made: last.state.messages },
      channelMessage
    ),
    pending: projection.pending.map(pendingSend),
    participantStatus: projection.participantStatus,
    participantStatuses: projection.participantStatuses,
    boundWorker: projection.boundWorker,
    taskRun: projection.taskRun,
    taskRunBlocked: projection.taskRunBlocked,
    unsupported: projection.unsupported,
    reply: projection.reply,
    serverMessages: mapKept(
      projection.serverMessages,
      last && { from: last.projection.serverMessages, made: last.state.serverMessages },
      channelMessage
    ),
    status: projection.status,
    syncWarning: projection.syncWarning,
    taskActivity: projection.taskActivity,
  };
}

// Each part as the view shows it, made once per projection object: an unchanged message keeps its object from one
// value of the view to the next, so the topic's delta passes over it without comparing it field by field.
const channelMessage = madeOnce(contractMessageToChannelMessage);

const draftAttachment = madeOnce(
  (attachment: ConversationProjection["draftAttachments"][number]) => ({
    ...attachment,
    error: attachment.error,
    path: attachment.path,
  })
);

const pendingSend = madeOnce((pending: ConversationProjection["pending"][number]) => ({
  ...pending,
  error: pending.error,
  skills: pending.skills,
}));

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
