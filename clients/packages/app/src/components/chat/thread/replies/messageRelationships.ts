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
  /** A member's reply: the line turns from under its target into the reply's bubble. */
  fromMember?: true;
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

/**
 * Thread identity comes from the owner, even when the root or parent is not
 * loaded. Only a reply still being sent, which has no root yet, joins its
 * parent's.
 */
export function messageThreadRoots(messages: readonly ChatMessage[]) {
  const roots = new Map<string, string>();
  for (const message of messages) {
    // Committed messages keep exactly what the owner said, missing or not.
    const parent = message.source === "pending" ? message.replyToMessageId : undefined;
    roots.set(
      message.messageId,
      message.threadRootMessageId ??
        (parent ? (roots.get(parent) ?? parent) : message.messageId)
    );
  }
  return roots;
}

export function sameMessageSender(a: ChatMessage, b: ChatMessage) {
  return (
    a.role === b.role &&
    a.platformSource === b.platformSource &&
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
  // Each member reply's hook, by the reply's last message: the reply, what it
  // answers, and the interval occupied before it, so an Agent answering it
  // can take its place.
  const memberReplies = new Map<
    string,
    { messageId: string; target: string; occupied: number }
  >();
  for (const group of groups) {
    const first = group[0]!;
    const last = group.at(-1)!;
    const root = roots.get(first.messageId)!;
    const previousAnchor = lastThreadAnchor.get(root);
    lastThreadAnchor.set(root, last.messageId);
    // A member's own message starts its thread unless it replies into one.
    if (root === first.messageId || (first.role === "user" && !previousAnchor))
      continue;
    let anchor = previousAnchor;
    let occupied = occupiedThrough;
    // An Agent answering a member's reply continues the line from the message
    // that reply answered, and the reply's own hook gives way to it.
    const member =
      first.role !== "user" && previousAnchor
        ? memberReplies.get(previousAnchor)
        : undefined;
    if (member) {
      replies.delete(member.messageId);
      anchor = member.target;
      occupied = member.occupied;
    }
    const targetIndex = anchor === undefined ? undefined : indexes.get(anchor);
    // Extend this thread from its last avatar, not from each direct parent.
    // Only another thread's intervening connector occupies this interval.
    const presentation =
      targetIndex === undefined || targetIndex < occupied ? "preview" : "line";
    // A member's reply has no preview slot: it connects only when the line is clear.
    if (first.role === "user" && presentation === "preview") continue;
    if (first.role === "user" && anchor)
      memberReplies.set(last.messageId, {
        messageId: first.messageId,
        target: anchor,
        occupied: occupiedThrough,
      });
    occupiedThrough = indexes.get(last.messageId)!;
    replies.set(first.messageId, {
      messageId: first.messageId,
      targetId: presentation === "preview" ? root : anchor!,
      sourceAnchorId: last.messageId,
      targetAnchorId: anchor ?? root,
      presentation,
      ...(first.role === "user" ? { fromMember: true as const } : {}),
    });
  }
  return { positions, replies };
}
