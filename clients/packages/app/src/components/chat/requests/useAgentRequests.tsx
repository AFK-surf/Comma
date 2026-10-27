import type { AgentRequest } from "@comma/core-client";
import { useTopic } from "@comma/core-client";
import { createContext, memo, useContext, useMemo } from "react";
import type { AnchoredTail } from "../thread/turns/useAnchoredTails";
import { AgentRequestCard } from "./AgentRequestCard";
import { groupAgentRequestsByAnchor } from "./agentRequestAnchor";

/** The conversation's request cards by the reply that owns them, for that reply's row. */
type AgentRequestCards = {
  groupId: string;
  conversationId: string;
  byReply: ReadonlyMap<string, readonly AgentRequest[]>;
};

export const AgentRequestCardsContext = createContext<AgentRequestCards | undefined>(
  undefined
);

/**
 * The conversation's request cards. A card whose reply has come sits in that reply's row, after its text
 * (`AgentRequestCardsContext`), so the Agent's later messages in the same turn do not move it; one whose reply has not
 * come (the Agent waits on the request) is the newest turn's (`tails`). Read only while the conversation is live: a
 * preview or a share shows no requests.
 */
export function useAgentRequests({
  live,
  groupId,
  conversationId,
  messages,
}: {
  live: boolean;
  groupId: string;
  conversationId: string | undefined;
  messages: readonly { messageId: string; role: string }[];
}): { cards: AgentRequestCards | undefined; tails: AnchoredTail[] } {
  // A live stream of the server's: let go as soon as no view shows the conversation, so none is kept open for one the
  // window left (or for another account's conversation once the account changes).
  const { value } = useTopic(
    live && groupId && conversationId
      ? { topic: "agentRequests", group: groupId, conversation: conversationId }
      : null,
    { lingerMs: 0 }
  );
  const requests = value?.requests;
  return useMemo(() => {
    if (!requests?.length || !conversationId) return { cards: undefined, tails: [] };
    const byReply = new Map<string, readonly AgentRequest[]>();
    const tails: AnchoredTail[] = [];
    for (const group of groupAgentRequestsByAnchor(requests, messages)) {
      if (group.messageId !== undefined) {
        byReply.set(group.messageId, group.requests);
        continue;
      }
      tails.push({
        key: "request:tail",
        messageId: undefined,
        node: (
          <AgentRequestList
            conversationId={conversationId}
            groupId={groupId}
            requests={group.requests}
          />
        ),
      });
    }
    return { cards: { groupId, conversationId, byReply }, tails };
  }, [requests, messages, conversationId, groupId]);
}

/** The request cards a reply owns, after its text. */
export const MessageAgentRequestCards = memo(function MessageAgentRequestCards({
  messageId,
}: {
  messageId: string | undefined;
}) {
  const cards = useContext(AgentRequestCardsContext);
  const requests = messageId === undefined ? undefined : cards?.byReply.get(messageId);
  if (!cards || !requests) return null;
  return (
    <AgentRequestList
      conversationId={cards.conversationId}
      groupId={cards.groupId}
      requests={requests}
    />
  );
});

function AgentRequestList({
  requests,
  groupId,
  conversationId,
}: {
  requests: readonly AgentRequest[];
  groupId: string;
  conversationId: string;
}) {
  return (
    <>
      {requests.map((request) => (
        <AgentRequestCard
          conversationId={conversationId}
          groupId={groupId}
          key={request.id}
          request={request}
        />
      ))}
    </>
  );
}
