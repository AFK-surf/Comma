import type {
  ChatMessage,
  DraftAttachment,
  PendingSend,
} from "../../../components/chat/model/conversationChannel";
import { sameMessageParts } from "../../../components/chat/model/inlineElementContract";

export function sameChannelMessage(previous: ChatMessage, next: ChatMessage) {
  return (
    previous.actorId === next.actorId &&
    previous.actorRole === next.actorRole &&
    previous.blocksKey === next.blocksKey &&
    previous.clientRequestId === next.clientRequestId &&
    previous.createdAt === next.createdAt &&
    previous.createdBy === next.createdBy &&
    previous.delivery === next.delivery &&
    previous.error === next.error &&
    previous.messageId === next.messageId &&
    previous.role === next.role &&
    previous.source === next.source &&
    previous.status === next.status &&
    previous.text === next.text &&
    jsonDataEqual(previous.refs, next.refs) &&
    jsonDataEqual(previous.attachments, next.attachments) &&
    sameOptionalMessageParts(previous.parts, next.parts)
  );
}

function sameOptionalMessageParts(
  previous: ChatMessage["parts"],
  next: ChatMessage["parts"]
) {
  if (previous === undefined || next === undefined) {
    return previous === next;
  }
  return sameMessageParts(previous, next);
}

export function samePendingSend(previous: PendingSend, next: PendingSend) {
  return (
    previous.clientRequestId === next.clientRequestId &&
    previous.createdAt === next.createdAt &&
    previous.error === next.error &&
    previous.status === next.status &&
    previous.text === next.text &&
    jsonDataEqual(previous.skills, next.skills)
  );
}

export function sameDraftAttachment(previous: DraftAttachment, next: DraftAttachment) {
  return (
    previous.error === next.error &&
    previous.id === next.id &&
    previous.isImage === next.isImage &&
    previous.name === next.name &&
    previous.path === next.path &&
    previous.size === next.size &&
    previous.status === next.status
  );
}

/** Deep equality over JSON-shaped data (the projection is schema-parsed). */
export function jsonDataEqual(previous: unknown, next: unknown): boolean {
  if (Object.is(previous, next)) {
    return true;
  }
  if (
    typeof previous !== "object" ||
    typeof next !== "object" ||
    previous === null ||
    next === null
  ) {
    return false;
  }
  if (Array.isArray(previous) || Array.isArray(next)) {
    if (
      !Array.isArray(previous) ||
      !Array.isArray(next) ||
      previous.length !== next.length
    ) {
      return false;
    }
    return previous.every((value, index) => jsonDataEqual(value, next[index]));
  }
  const previousRecord = previous as Record<string, unknown>;
  const nextRecord = next as Record<string, unknown>;
  // A missing key and an explicit undefined are equivalent here: the
  // projection writes optional fields as explicit undefined.
  const keys = new Set([...Object.keys(previousRecord), ...Object.keys(nextRecord)]);
  for (const key of keys) {
    if (!jsonDataEqual(previousRecord[key], nextRecord[key])) {
      return false;
    }
  }
  return true;
}
