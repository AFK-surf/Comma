import { useSyncExternalStore } from "react";

/**
 * Settled tasks the user has acknowledged out of the chat task panel. A
 * running task always shows; once it settles, "Reveal in Chat" records the task
 * here while jumping to its announcing turn, and "Dismiss" records the same
 * acknowledgement without revealing. The mark is removed again the moment the
 * task is observed running, so a re-opened task re-docks in the panel and its
 * next settle needs a fresh acknowledgement.
 *
 * Stored in localStorage like the review-seen marks: shared across this
 * origin's windows, safe to lose (a row merely re-appears).
 */
const DISMISSED_STORAGE_KEY = "comma.chatTaskPanelDismissed";
const DISMISSED_CHANGED_EVENT = "comma:chat-task-panel-dismissed-changed";
/** Oldest acknowledgements are evicted past this; a row just re-appears. */
const MAX_DISMISSED = 300;

export type DismissedPanelTasks = ReadonlySet<string>;

let cache: { dismissed: DismissedPanelTasks; raw: string | null } | undefined;

function readRaw(): string | null {
  try {
    return globalThis.localStorage?.getItem(DISMISSED_STORAGE_KEY) ?? null;
  } catch {
    return null;
  }
}

export function readDismissedPanelTasks(): DismissedPanelTasks {
  const raw = readRaw();
  if (cache && cache.raw === raw) return cache.dismissed;
  const dismissed = new Set<string>();
  if (raw !== null) {
    try {
      const parsed: unknown = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        for (const conversationId of parsed) {
          if (typeof conversationId === "string") dismissed.add(conversationId);
        }
      }
    } catch {
      // A corrupted payload reads as no marks and is replaced on next write.
    }
  }
  cache = { dismissed, raw };
  return dismissed;
}

export function dismissPanelTask(conversationId: string) {
  const current = readDismissedPanelTasks();
  if (current.has(conversationId)) return;
  // Insertion order is recency, so eviction drops the oldest acknowledgement.
  const next = [...current, conversationId].slice(-MAX_DISMISSED);
  write(new Set(next));
}

export function restorePanelTask(conversationId: string) {
  const current = readDismissedPanelTasks();
  if (!current.has(conversationId)) return;
  const next = new Set(current);
  next.delete(conversationId);
  write(next);
}

function write(next: ReadonlySet<string>) {
  const raw = JSON.stringify([...next]);
  try {
    globalThis.localStorage?.setItem(DISMISSED_STORAGE_KEY, raw);
  } catch {
    // A blocked write still applies for this session via the cache.
  }
  cache = { dismissed: next, raw };
  globalThis.window?.dispatchEvent(new CustomEvent(DISMISSED_CHANGED_EVENT));
}

export function subscribeDismissedPanelTasks(listener: () => void) {
  if (!globalThis.window) {
    return () => undefined;
  }

  const handleStorage = (event: StorageEvent) => {
    if (event.key === DISMISSED_STORAGE_KEY) listener();
  };
  window.addEventListener(DISMISSED_CHANGED_EVENT, listener);
  window.addEventListener("storage", handleStorage);
  return () => {
    window.removeEventListener(DISMISSED_CHANGED_EVENT, listener);
    window.removeEventListener("storage", handleStorage);
  };
}

export function useDismissedPanelTasks(): DismissedPanelTasks {
  return useSyncExternalStore(
    subscribeDismissedPanelTasks,
    readDismissedPanelTasks,
    readDismissedPanelTasks
  );
}
