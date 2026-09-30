import type { ChatMessage } from "@comma/chat-contract";

export type MessageGroupPosition = {
  first: boolean;
  last: boolean;
  avatarMessageId: string;
};

export type MessageReply = {
  messageId: string;
  targetId: string;
  sourceAnchorId: string;
  targetAnchorId: string;
  presentation: "line" | "preview";
};

export type ReplyChainState = "active" | "muted" | undefined;

/** One row's place among its neighbours, as values that memo can compare. */
export type RowRelationshipProps = {
  bubbleTail: boolean;
  groupFirst?: boolean | undefined;
  groupLast?: boolean | undefined;
  replyPreviewTarget?: ChatMessage | undefined;
  replyPreviewTargetId?: string | undefined;
};

/** Thread identity comes from the owner, even when the root or parent is not loaded. */
export function messageThreadRoots(messages: readonly ChatMessage[]) {
  return new Map(
    messages.map((message) => [
      message.messageId,
      message.threadRootMessageId ?? message.messageId,
    ])
  );
}

export function sameMessageSender(a: ChatMessage, b: ChatMessage) {
  return (
    a.role === b.role &&
    a.actorRole === b.actorRole &&
    a.actorId === b.actorId &&
    a.createdBy === b.createdBy
  );
}

/** One pass over the mounted transcript; no history reads or per-message work queues. */
export function messageRelationships(
  messages: readonly ChatMessage[],
  breaks: ReadonlySet<string> = new Set()
) {
  const positions = new Map<string, MessageGroupPosition>();
  const roots = messageThreadRoots(messages);
  const indexes = new Map(messages.map((message, index) => [message.messageId, index]));
  const groups: ChatMessage[][] = [];
  for (const message of messages) {
    const group = groups.at(-1);
    const previous = group?.at(-1);
    if (
      group &&
      previous &&
      !breaks.has(message.messageId) &&
      sameMessageSender(previous, message) &&
      roots.get(previous.messageId) === roots.get(message.messageId)
    ) {
      group.push(message);
    } else {
      groups.push([message]);
    }
  }
  for (const group of groups) {
    const avatarMessageId = group.at(-1)!.messageId;
    group.forEach((message, index) => {
      positions.set(message.messageId, {
        first: index === 0,
        last: index === group.length - 1,
        avatarMessageId: message.role === "user" ? message.messageId : avatarMessageId,
      });
    });
  }

  const replies = new Map<string, MessageReply>();
  const lastThreadAnchor = new Map<string, string>();
  let occupiedThrough = -1;
  for (const group of groups) {
    const first = group[0]!;
    const last = group.at(-1)!;
    const root = roots.get(first.messageId)!;
    const previousAnchor = lastThreadAnchor.get(root);
    lastThreadAnchor.set(root, last.messageId);
    if (first.role === "user" || (!previousAnchor && root === first.messageId))
      continue;
    const targetIndex =
      previousAnchor === undefined ? undefined : indexes.get(previousAnchor);
    // Extend this thread from its last avatar, not from each direct parent.
    // Only another thread's intervening connector occupies this interval.
    const presentation =
      targetIndex === undefined || targetIndex < occupiedThrough ? "preview" : "line";
    occupiedThrough = indexes.get(last.messageId)!;
    replies.set(first.messageId, {
      messageId: first.messageId,
      targetId: presentation === "preview" ? root : previousAnchor!,
      sourceAnchorId: last.messageId,
      targetAnchorId: previousAnchor ?? root,
      presentation,
    });
  }
  return { positions, replies };
}
