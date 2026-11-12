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
 *
 * A proposal filed before the oldest loaded message has no owner here: the
 * reply that filed it is not loaded, and the nearest loaded reply is unrelated.
 */
export function labelProposalAnchorMessageId(
  messages: readonly AnchorableMessage[],
  proposedAt: number | undefined,
  { awaitsDecision = false }: { awaitsDecision?: boolean } = {}
): string | undefined {
  const anchor = normalizeUnixTimestampMs(proposedAt);
  if (
    anchor === undefined ||
    filedBeforeLoadedMessages(messages, proposedAt, awaitsDecision)
  ) {
    return undefined;
  }
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

/**
 * Whether a proposal was filed earlier than every dated loaded message, and the
 * oldest of them is not a reply. A reply can carry a time later than the
 * proposals it filed while it was written, so one at the head of the loaded
 * history may own a settled proposal older than itself; a person's message
 * cannot. A proposal that awaits a decision takes no such guess: its card
 * holds its reply's turn mounted, and at the head of the page that is every
 * loaded turn. It waits on the newest turn instead.
 */
function filedBeforeLoadedMessages(
  messages: readonly AnchorableMessage[],
  proposedAt: number | undefined,
  awaitsDecision: boolean
): boolean {
  const filedAt = normalizeUnixTimestampMs(proposedAt);
  if (filedAt === undefined) return false;
  let oldest: { createdAt: number; role: string } | undefined;
  for (const message of messages) {
    const createdAt = normalizeUnixTimestampMs(message.createdAt);
    if (
      createdAt !== undefined &&
      (oldest === undefined || createdAt < oldest.createdAt)
    )
      oldest = { createdAt, role: message.role };
  }
  return (
    oldest !== undefined &&
    filedAt < oldest.createdAt &&
    (awaitsDecision || oldest.role !== "assistant")
  );
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
 * proposal with no dated reply keeps the tail. A settled proposal filed before
 * the loaded history shows nowhere: its receipt belongs to a reply that is not
 * loaded, not to the newest turn.
 */
export function groupLabelProposalsByAnchor<
  T extends { created_at?: number | undefined; status: string },
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
    const awaitsDecision = proposal.status === "pending";
    if (
      !awaitsDecision &&
      filedBeforeLoadedMessages(messages, proposal.created_at, false)
    )
      continue;
    const anchor = labelProposalAnchorMessageId(messages, proposal.created_at, {
      awaitsDecision,
    });
    const group = byAnchor.get(anchor);
    if (group) group.push(proposal);
    else byAnchor.set(anchor, [proposal]);
  }
  return [...byAnchor]
    .map(([messageId, items]) => ({ messageId, proposals: items }))
    .toSorted((a, b) => positionOf(a.messageId) - positionOf(b.messageId));
}
