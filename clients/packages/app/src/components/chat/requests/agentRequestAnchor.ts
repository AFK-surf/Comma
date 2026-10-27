import type { AgentRequest } from "@comma/core-client";

type AnchorableMessage = { messageId: string; role: string };

/**
 * Splits a conversation's requests by the reply that owns each card: the Agent's first reply after the person's
 * message the request's turn served. A pending request whose reply has not come (the Agent waits on it) is the newest
 * turn's, under `undefined`. A finished one with no reply among the messages (its turn is not loaded) shows nowhere:
 * its receipt belongs to that turn, not the newest. Groups come oldest reply first, the newest turn's last.
 */
export function groupAgentRequestsByAnchor(
  requests: readonly AgentRequest[],
  messages: readonly AnchorableMessage[]
): { messageId: string | undefined; requests: AgentRequest[] }[] {
  const index = new Map<string, number>();
  messages.forEach((message, i) => index.set(message.messageId, i));
  const replyAfter = (sourceMessageId: string | null): string | undefined => {
    const start = sourceMessageId === null ? undefined : index.get(sourceMessageId);
    if (start === undefined) return undefined;
    for (let i = start + 1; i < messages.length; i++)
      if (messages[i]!.role === "assistant") return messages[i]!.messageId;
    return undefined;
  };
  const byAnchor = new Map<string | undefined, AgentRequest[]>();
  // Oldest request first within a reply.
  for (const request of requests.toSorted(
    (a, b) => (a.createdAt ?? 0) - (b.createdAt ?? 0)
  )) {
    const anchor = replyAfter(request.sourceMessageId);
    if (anchor === undefined && request.status !== "pending") continue;
    const group = byAnchor.get(anchor);
    if (group) group.push(request);
    else byAnchor.set(anchor, [request]);
  }
  const position = (messageId: string | undefined) =>
    messageId === undefined
      ? Number.POSITIVE_INFINITY
      : (index.get(messageId) ?? Number.POSITIVE_INFINITY);
  return [...byAnchor]
    .map(([messageId, items]) => ({ messageId, requests: items }))
    .toSorted((a, b) => position(a.messageId) - position(b.messageId));
}
