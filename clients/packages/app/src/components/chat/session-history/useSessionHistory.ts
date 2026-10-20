import { useCall, useTopic } from "@comma/core-client";
import { useCallback, useEffect, useState } from "react";
export type { SessionHistoryRecord, SessionHistoryValue } from "@comma/core-client";

/** A participant's session history in a conversation. */
export interface SessionHistoryInput {
  groupId: string;
  conversationId: string;
  participantId: string;
}

/**
 * Shows a session history the client core keeps: subscribing keeps its live stream open, and `mode` names the page
 * it reads first. Pages, paging and the stream are the core's; the caller only shows them.
 */
export function useSessionHistory(
  input: SessionHistoryInput,
  mode: "preview" | "latest"
) {
  const { groupId, conversationId, participantId } = input;
  // The live stream ends soon after the last view of the history goes.
  const { value, error } = useTopic(
    {
      topic: "history",
      group: groupId,
      conversation: conversationId,
      participant: participantId,
    },
    { lingerMs: 0 }
  );
  const call = useCall();
  const [transportError, setTransportError] = useState(false);
  const load = useCallback(
    (nextMode: "latest" | "older" | "preview") => {
      setTransportError(false);
      call("history.load", {
        group: groupId,
        conversation: conversationId,
        participant: participantId,
        mode: nextMode,
      }).catch(() => setTransportError(true));
    },
    [call, groupId, conversationId, participantId]
  );
  useEffect(() => load(mode), [load, mode]);
  return {
    snapshot: value,
    // A failed page shows in the history itself (its `status`); a core that cannot be reached shows here.
    transportError: transportError || Boolean(error),
    load,
  };
}
