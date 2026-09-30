import type {
  ChatMessage,
  ConversationChannelState,
} from "../../../components/chat/model/conversationChannel";
import {
  jsonDataEqual,
  sameChannelMessage,
  sameDraftAttachment,
  samePendingSend,
} from "./channelEquality";

/**
 * Rebuilds a projected channel state on top of the previous one, reusing the
 * previous object identities for every value-equal field. Returns the previous
 * state itself when nothing changed so the caller can skip the emit.
 */
export function reconcileChannelState(
  previous: ConversationChannelState,
  next: ConversationChannelState
): ConversationChannelState {
  const nextMessages = reconcileMessages(previous.messages, next.messages);
  const nextServerMessages = reconcileMessages(
    previous.serverMessages,
    next.serverMessages
  );
  const reconciled: ConversationChannelState = {
    ...next,
    activity: jsonDataEqual(previous.activity, next.activity)
      ? previous.activity
      : next.activity,
    assistantDraft: jsonDataEqual(previous.assistantDraft, next.assistantDraft)
      ? previous.assistantDraft
      : next.assistantDraft,
    participantStatuses: jsonDataEqual(
      previous.participantStatuses,
      next.participantStatuses
    )
      ? previous.participantStatuses
      : next.participantStatuses,
    participantStatus: jsonDataEqual(previous.participantStatus, next.participantStatus)
      ? previous.participantStatus
      : next.participantStatus,
    boundWorker: jsonDataEqual(previous.boundWorker, next.boundWorker)
      ? previous.boundWorker
      : next.boundWorker,
    conversation: jsonDataEqual(previous.conversation, next.conversation)
      ? previous.conversation
      : next.conversation,
    draftAttachments: reconcileItems(
      previous.draftAttachments,
      next.draftAttachments,
      (attachment) => attachment.id,
      sameDraftAttachment
    ),
    messages: nextMessages,
    pending: reconcileItems(
      previous.pending,
      next.pending,
      (item) => item.clientRequestId,
      samePendingSend
    ),
    serverMessages: nextServerMessages,
  };

  const changed = (Object.keys(reconciled) as (keyof ConversationChannelState)[]).some(
    (key) => reconciled[key] !== previous[key]
  );
  return changed ? reconciled : previous;
}

function reconcileMessages(
  previous: ChatMessage[],
  next: ChatMessage[]
): ChatMessage[] {
  if (previous === next) {
    return next;
  }
  const previousById = new Map(previous.map((message) => [message.messageId, message]));
  let reusedInPlace = previous.length === next.length;
  const reconciled = next.map((message, index) => {
    const candidate = previousById.get(message.messageId);
    if (candidate && sameChannelMessage(candidate, message)) {
      if (previous[index] !== candidate) {
        reusedInPlace = false;
      }
      return candidate;
    }
    reusedInPlace = false;
    return message;
  });
  return reusedInPlace ? previous : reconciled;
}

function reconcileItems<Item>(
  previous: Item[],
  next: Item[],
  keyOf: (item: Item) => string,
  equals: (previous: Item, next: Item) => boolean
): Item[] {
  if (previous === next) {
    return next;
  }
  const previousByKey = new Map(previous.map((item) => [keyOf(item), item]));
  let reusedInPlace = previous.length === next.length;
  const reconciled = next.map((item, index) => {
    const candidate = previousByKey.get(keyOf(item));
    if (candidate && equals(candidate, item)) {
      if (previous[index] !== candidate) {
        reusedInPlace = false;
      }
      return candidate;
    }
    reusedInPlace = false;
    return item;
  });
  return reusedInPlace ? previous : reconciled;
}
