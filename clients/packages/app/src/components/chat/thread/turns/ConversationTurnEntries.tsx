import { Fragment, memo, useState, type ReactNode } from "react";
import type { ConversationEntry, ConversationTurn } from "../layout/conversationLayout";
import { reconcileTurnResponseIdentity } from "../layout/turnResponseIdentity";

export type ResponseFeedback = (presentation: { hasResponse: boolean }) => ReactNode;

/**
 * Visual identity belongs to the mounted turn, just like its rendered rows.
 * A second reply cannot revoke a completed reply's draft-to-Message alias.
 * The existing turn window releases this state when it unmounts that turn.
 *
 * Memoized: a draft revision rebuilds only the turn that owns the draft, so
 * every other turn receives the same turn and renderEntry and skips the render.
 */
export const ConversationTurnEntries = memo(function ConversationTurnEntries({
  responseFeedback,
  renderEntry,
  turn,
}: {
  responseFeedback: ResponseFeedback | undefined;
  renderEntry: (entry: ConversationEntry, turn: ConversationTurn) => ReactNode[];
  turn: ConversationTurn;
}) {
  const entries = turn.entries;
  const [storedIdentity, setIdentity] = useState(() =>
    reconcileTurnResponseIdentity(undefined, entries)
  );
  let identity = storedIdentity;
  if (storedIdentity.entries !== entries) {
    identity = reconcileTurnResponseIdentity(storedIdentity, entries);
    setIdentity(identity);
  }
  const rows: ReactNode[] = [];
  let hasResponse = false;
  for (const entry of entries) {
    if (
      entry.kind === "assistant-response" &&
      !entry.message &&
      !entry.draft?.text.trim()
    ) {
      continue;
    }
    hasResponse ||=
      entry.kind === "assistant-response" &&
      Boolean(entry.message || entry.draft?.text.trim());
    const visualKey =
      entry.kind === "assistant-response"
        ? entry.message
          ? identity.canonicalKeys.get(entry.message.messageId)
          : identity.draft?.key
        : undefined;
    rows.push(...renderEntry(visualKey ? { ...entry, key: visualKey } : entry, turn));
  }
  // Before the first body this is the reply's waiting position. Once content
  // exists, notices and Side Chat's current tool activity follow the body.
  rows.push(
    <Fragment key="response-status">{responseFeedback?.({ hasResponse })}</Fragment>
  );
  return rows;
});
