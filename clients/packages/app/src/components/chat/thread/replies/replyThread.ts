import type { ChatAssistantDraft, ChatMessage } from "@comma/core/chat";

/**
 * The thread a reader chose to reply in. `targetId` is the message they
 * picked; once their first reply is sent it clears, and later replies answer
 * the newest committed message in the thread.
 */
export type ReplyThreadSelection = {
  rootId: string;
  targetId: string | undefined;
};

export function threadRootOf(message: ChatMessage) {
  return message.threadRootMessageId ?? message.messageId;
}

/**
 * Messages of one thread in transcript order. A pending reply has no root
 * from the owner yet, so it joins through the parent it names.
 */
export function replyThreadMessages(
  messages: readonly ChatMessage[],
  rootId: string
): ChatMessage[] {
  const members = new Set<string>();
  const thread: ChatMessage[] = [];
  for (const message of messages) {
    const joins =
      threadRootOf(message) === rootId ||
      (message.source === "pending" &&
        message.replyToMessageId !== undefined &&
        members.has(message.replyToMessageId));
    if (!joins) continue;
    members.add(message.messageId);
    thread.push(message);
  }
  return thread;
}

/** The streaming reply belongs to the thread when it answers one of its messages. */
export function replyThreadDraft(
  draft: ChatAssistantDraft | undefined,
  thread: readonly ChatMessage[]
): ChatMessage | undefined {
  const parentId = draft?.sourceMessageIds.at(-1);
  if (!draft?.text || !parentId) return undefined;
  const parent = thread.find((message) => message.messageId === parentId);
  if (!parent) return undefined;
  return {
    attachments: [],
    createdAt: 0,
    delivery: "sent",
    messageId: draft.draftId,
    parts: [],
    refs: [],
    replyToMessageId: parentId,
    role: "assistant",
    source: "server",
    status: "streaming",
    text: draft.text,
    threadRootMessageId: threadRootOf(parent),
  };
}

/** The canonical message a send in this thread replies to. */
export function replyThreadSendTarget(
  messages: readonly ChatMessage[],
  selection: ReplyThreadSelection
): string {
  if (selection.targetId) return selection.targetId;
  const committed = replyThreadMessages(messages, selection.rootId).filter(
    (message) => message.source === "server" && message.delivery !== "failed"
  );
  return committed.at(-1)?.messageId ?? selection.rootId;
}

/** Only a committed message has a canonical id the owner accepts as a reply target. */
export function canReplyTo(message: ChatMessage | undefined): message is ChatMessage {
  return Boolean(
    message && message.source === "server" && message.delivery !== "failed"
  );
}
