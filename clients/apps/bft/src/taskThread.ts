import type { BftTaskMessage } from "./api";

/*
 * The messages task detail holds in memory. Polls add newer messages after
 * the last one the server returned (`tailId`); scrolling up pages in older
 * ones. At most `threadCap` messages stay loaded: an append drops the oldest,
 * and paging far back drops the newest, after which new arrivals are only
 * counted (`unseen`) until the reader returns to the latest messages.
 */

export const threadCap = 300;

export interface Thread {
  /** Shown messages, oldest first, each id once. */
  messages: BftTaskMessage[];
  /** Older messages exist before the first shown one. */
  hasOlder: boolean;
  /** The newest message id the server returned: where the next poll starts. */
  tailId: string | null;
  /** The newest messages were dropped while paging back. */
  detached: boolean;
  /** Messages that arrived while detached. */
  unseen: number;
}

export function startThread(messages: BftTaskMessage[], hasOlder: boolean): Thread {
  const ordered = mergeMessages([], messages);
  return {
    messages: ordered,
    hasOlder,
    tailId: ordered.at(-1)?.id ?? null,
    detached: false,
    unseen: 0,
  };
}

/**
 * The messages of both lists, each id once (the later copy wins) and in
 * server order: by `seq` where both messages have one, otherwise as given.
 */
export function mergeMessages(
  first: readonly BftTaskMessage[],
  second: readonly BftTaskMessage[]
): BftTaskMessage[] {
  const byId = new Map<string, BftTaskMessage>();
  for (const message of [...first, ...second]) byId.set(message.id, message);
  return [...byId.values()].toSorted((a, b) =>
    a.seq !== null && b.seq !== null ? a.seq - b.seq : 0
  );
}

/** A poll's newer messages, oldest first. */
export function appendNewer(
  thread: Thread,
  page: readonly BftTaskMessage[],
  cap = threadCap
): Thread {
  const last = page.at(-1);
  if (!last) return thread;
  // The cursor message itself, or one already shown, is not new.
  const known = new Set(thread.messages.map((message) => message.id));
  if (thread.tailId) known.add(thread.tailId);
  const fresh = page.filter((message) => !known.has(message.id));
  if (thread.detached) {
    return { ...thread, tailId: last.id, unseen: thread.unseen + fresh.length };
  }
  if (fresh.length === 0) return { ...thread, tailId: last.id };
  const merged = mergeMessages(thread.messages, fresh);
  const trimmed = merged.length > cap;
  return {
    ...thread,
    messages: trimmed ? merged.slice(-cap) : merged,
    hasOlder: thread.hasOlder || trimmed,
    tailId: last.id,
  };
}

/** A page of older messages, oldest first; `hasMore` says older ones remain. */
export function prependOlder(
  thread: Thread,
  page: readonly BftTaskMessage[],
  hasMore: boolean,
  cap = threadCap
): Thread {
  const merged = mergeMessages(page, thread.messages);
  const trimmed = merged.length > cap;
  return {
    ...thread,
    messages: trimmed ? merged.slice(0, cap) : merged,
    hasOlder: hasMore,
    detached: thread.detached || trimmed,
  };
}
