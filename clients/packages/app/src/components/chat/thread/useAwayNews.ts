import { useMemo, useState } from "react";
import type { ChatMessage } from "@comma/core/chat";
import { useWindowAttended } from "../../useWindowAttended";

type AwayNews = {
  /** Every id this thread has seen arrive, or found when it opened. */
  known: ReadonlySet<string>;
  draftId: string | undefined;
  /** Arrived while the window was not in front. */
  pending: ReadonlySet<string>;
  /** Pending ids the reader has come back to. */
  news: ReadonlySet<string>;
};

const noIds: ReadonlySet<string> = new Set();

function agentIds(messages: readonly ChatMessage[], draftId: string | undefined) {
  const ids = messages.flatMap((message) =>
    message.role === "assistant" ? [message.messageId] : []
  );
  return draftId === undefined ? ids : [...ids, draftId];
}

/**
 * The agent's messages and drafts that arrived while the window was not in
 * front (another app had focus), from the moment it is in front again: Home
 * marks them New then. What arrives while the window is in front, or was there
 * when the thread opened, is not news. A message that lands from a draft keeps
 * the draft's standing.
 */
export function useAwayNews(
  messages: readonly ChatMessage[],
  draftId: string | undefined
): ReadonlySet<string> {
  const attended = useWindowAttended();
  const [state, setState] = useState<AwayNews>(() => ({
    draftId,
    known: new Set(agentIds(messages, draftId)),
    news: noIds,
    pending: noIds,
  }));

  // Streaming re-renders with the same messages; collect their ids once.
  const ids = useMemo(() => agentIds(messages, draftId), [draftId, messages]);
  const arrived = ids.filter((id) => !state.known.has(id));
  const flushes = attended && state.pending.size > 0;
  if (arrived.length === 0 && !flushes && draftId === state.draftId) {
    return state.news;
  }

  const landedDraft =
    state.draftId !== undefined && state.draftId !== draftId
      ? state.draftId
      : undefined;
  const pending = new Set(state.pending);
  const news = new Set(state.news);
  for (const id of arrived) {
    if (landedDraft !== undefined && id !== draftId && news.has(landedDraft)) {
      news.add(id);
    } else if (
      !attended ||
      (landedDraft !== undefined && id !== draftId && pending.has(landedDraft))
    ) {
      pending.add(id);
    }
  }
  if (attended) {
    for (const id of pending) news.add(id);
    pending.clear();
  }
  const next: AwayNews = {
    draftId,
    known: arrived.length > 0 ? new Set([...state.known, ...arrived]) : state.known,
    news: news.size === state.news.size ? state.news : news,
    pending,
  };
  setState(next);
  return next.news;
}
