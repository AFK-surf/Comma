import { normalizeUnixTimestampMs } from "../../../search/normalizeUnixTimestampMs";

type AnchorableMessage = {
  createdAt?: number | undefined;
  messageId: string;
  role: string;
};

/**
 * The reply that owns a label proposal card.
 *
 * A proposal records the conversation and the time it was proposed, not the
 * reply that filed it. The Router files proposals from the reply it is writing,
 * so the assistant reply nearest that time is the reply that owns the card. The
 * card then holds that reply's place in the transcript instead of riding the
 * newest turn down the conversation.
 */
export function labelProposalAnchorMessageId(
  messages: readonly AnchorableMessage[],
  proposedAt: number | undefined
): string | undefined {
  const anchor = normalizeUnixTimestampMs(proposedAt);
  if (anchor === undefined) return undefined;
  let owner: { distance: number; messageId: string } | undefined;
  for (const message of messages) {
    if (message.role !== "assistant") continue;
    const createdAt = normalizeUnixTimestampMs(message.createdAt);
    if (createdAt === undefined) continue;
    const distance = Math.abs(createdAt - anchor);
    if (owner === undefined || distance < owner.distance) {
      owner = { distance, messageId: message.messageId };
    }
  }
  return owner?.messageId;
}

export type AnchoredLabelProposals<T> = {
  /** The reply that owns these proposals; the tail when nothing dates them. */
  messageId: string | undefined;
  proposals: T[];
};

/**
 * Splits a conversation's proposals by the reply that filed each one, oldest
 * reply first. Each group renders as its own card, so a later round neither
 * drags an older card along nor hides the new decision at the bottom; a
 * proposal with no dated reply keeps the tail.
 */
export function groupLabelProposalsByAnchor<
  T extends { created_at?: number | undefined },
>(
  proposals: readonly T[],
  messages: readonly AnchorableMessage[]
): AnchoredLabelProposals<T>[] {
  const positionByMessageId = new Map<string, number>();
  messages.forEach((message, index) =>
    positionByMessageId.set(message.messageId, index)
  );
  const positionOf = (messageId: string | undefined) =>
    messageId === undefined
      ? Number.POSITIVE_INFINITY
      : (positionByMessageId.get(messageId) ?? Number.POSITIVE_INFINITY);
  const byAnchor = new Map<string | undefined, T[]>();
  for (const proposal of proposals) {
    const anchor = labelProposalAnchorMessageId(messages, proposal.created_at);
    const group = byAnchor.get(anchor);
    if (group) group.push(proposal);
    else byAnchor.set(anchor, [proposal]);
  }
  return [...byAnchor]
    .map(([messageId, items]) => ({ messageId, proposals: items }))
    .toSorted((a, b) => positionOf(a.messageId) - positionOf(b.messageId));
}
