import { useSyncExternalStore } from "react";

/**
 * A renderer-local map of id → projection revision, persisted in localStorage
 * so it is shared across this origin's windows and safe to lose. The
 * needs-review "seen" marks and the Inbox "deleted" / "unread" marks are all
 * one of these: a mark records the projection `updatedAt` at which something
 * happened. Seen and deleted marks outgrow themselves on a newer revision.
 * Unread marks stay until `unmark`.
 */
export type RevisionMarks = ReadonlyMap<string, number>;

export interface RevisionMarksStore {
  /** Records marks; a mark never moves backwards. */
  mark(entries: Iterable<readonly [id: string, revision: number]>): void;
  read(): RevisionMarks;
  subscribe(listener: () => void): () => void;
  /** Drops marks. A missing id is a no-op. */
  unmark(ids: Iterable<string>): void;
}

export function createRevisionMarksStore({
  changedEvent,
  maxMarks,
  persist,
  storageKey,
}: {
  /** Window event that fans a write out to this window's subscribers. */
  changedEvent: string;
  /** Oldest marks are evicted past this; a stale mark only re-shows a row. */
  maxMarks: number;
  /**
   * Writes the serialized marks under `storageKey`. The caller owns this call
   * so the foundation check can audit every localStorage write against a
   * literal key; a throw (blocked storage) is absorbed here.
   */
  persist: (raw: string) => void;
  storageKey: string;
}): RevisionMarksStore {
  let cache: { marks: RevisionMarks; raw: string | null } | undefined;

  const readRaw = (): string | null => {
    try {
      return globalThis.localStorage?.getItem(storageKey) ?? null;
    } catch {
      return null;
    }
  };

  const read = (): RevisionMarks => {
    const raw = readRaw();
    if (cache && cache.raw === raw) return cache.marks;
    const marks = new Map<string, number>();
    if (raw !== null) {
      try {
        const parsed: unknown = JSON.parse(raw);
        if (parsed !== null && typeof parsed === "object") {
          for (const [id, revision] of Object.entries(parsed)) {
            if (typeof revision === "number" && Number.isFinite(revision)) {
              marks.set(id, revision);
            }
          }
        }
      } catch {
        // A corrupted payload reads as no marks and is replaced on next write.
      }
    }
    cache = { marks, raw };
    return marks;
  };

  const commit = (next: Map<string, number>) => {
    const raw = JSON.stringify(Object.fromEntries(next));
    try {
      persist(raw);
    } catch {
      // A blocked write still applies for this session via the cache.
    }
    cache = { marks: next, raw };
    globalThis.window?.dispatchEvent(new CustomEvent(changedEvent));
  };

  const mark = (entries: Iterable<readonly [string, number]>) => {
    const current = read();
    let next: Map<string, number> | undefined;
    for (const [id, revision] of entries) {
      const existing = (next ?? current).get(id);
      if (existing !== undefined && existing >= revision) continue;
      next ??= new Map(current);
      next.set(id, revision);
    }
    if (!next) return;
    if (next.size > maxMarks) {
      const evictions = [...next.entries()]
        .toSorted(([, left], [, right]) => left - right)
        .slice(0, next.size - maxMarks);
      for (const [evictedId] of evictions) next.delete(evictedId);
    }
    commit(next);
  };

  const unmark = (ids: Iterable<string>) => {
    const current = read();
    let next: Map<string, number> | undefined;
    for (const id of ids) {
      if (!(next ?? current).has(id)) continue;
      next ??= new Map(current);
      next.delete(id);
    }
    if (!next) return;
    commit(next);
  };

  const subscribe = (listener: () => void) => {
    if (!globalThis.window) {
      return () => undefined;
    }

    const handleStorage = (event: StorageEvent) => {
      if (event.key === storageKey) listener();
    };
    window.addEventListener(changedEvent, listener);
    window.addEventListener("storage", handleStorage);
    return () => {
      window.removeEventListener(changedEvent, listener);
      window.removeEventListener("storage", handleStorage);
    };
  };

  return { mark, read, subscribe, unmark };
}

/** Subscribes a component to a store's marks. */
export function useRevisionMarks(store: RevisionMarksStore): RevisionMarks {
  return useSyncExternalStore(store.subscribe, store.read, store.read);
}
