import { useCall, useTopic, useTopicSelect } from "@comma/core-client";
import type { MarkKind } from "@comma/core/contract";
import { useCallback, useEffect, useMemo, useRef } from "react";

/**
 * The reader's marks on this device, as the core keeps them for the account: id → the projection revision
 * (`updatedAt`) at which something happened. The needs-review "seen" marks and the Inbox "deleted" / "unread" marks
 * are all one of these. Seen and deleted marks outgrow themselves on a newer revision; unread marks stay until
 * unmarked.
 */
export type RevisionMarks = ReadonlyMap<string, number>;

const EMPTY: RevisionMarks = new Map();

/**
 * Marks this window kept in localStorage before the core kept them: handed to the core once, then dropped.
 */
function useLegacyMarks(kind: MarkKind, legacyKey: string) {
  const call = useCall();
  useEffect(() => {
    let raw: string | null = null;
    try {
      raw = globalThis.localStorage?.getItem(legacyKey) ?? null;
    } catch {
      return;
    }
    if (raw === null) return;
    let entries: [string, number][] = [];
    try {
      const parsed: unknown = JSON.parse(raw);
      if (parsed !== null && typeof parsed === "object")
        entries = Object.entries(parsed).filter(
          (entry): entry is [string, number] =>
            typeof entry[1] === "number" && Number.isFinite(entry[1])
        );
    } catch {
      // A corrupted payload carries no marks.
    }
    void call("marks.mark", { kind, entries: entries.slice(0, 1000) }).then(
      () => {
        try {
          globalThis.localStorage?.removeItem(legacyKey);
        } catch {
          // Blocked storage: handed over again next time, which changes nothing.
        }
      },
      () => undefined
    );
  }, [call, kind, legacyKey]);
}

/** Subscribes a component to one kind of marks. */
export function useRevisionMarks(kind: MarkKind, legacyKey: string): RevisionMarks {
  useLegacyMarks(kind, legacyKey);
  const { value } = useTopic({ topic: "marks", kind });
  const marks = value?.marks;
  return useMemo(() => (marks ? new Map(Object.entries(marks)) : EMPTY), [marks]);
}

/**
 * One kind of marks, of `ids` alone: a component that shows a few rows renders again only when one of their marks
 * moves, not for the account's other marks. The map stays the same object while theirs hold.
 */
export function useRevisionMarksOf(
  kind: MarkKind,
  legacyKey: string,
  ids: readonly string[]
): RevisionMarks {
  useLegacyMarks(kind, legacyKey);
  return useMarksOf(kind, ids);
}

/** The marks of `ids` alone (`useRevisionMarksOf`), for a kind whose earlier marks its own hook hands over. */
export function useMarksOf(kind: MarkKind, ids: readonly string[]): RevisionMarks {
  const last = useRef(EMPTY);
  return useTopicSelect({ topic: "marks", kind }, (value) => {
    const marks = value?.marks;
    const previous = last.current;
    const next = new Map<string, number>();
    let same = true;
    for (const id of ids) {
      const at = marks && Object.hasOwn(marks, id) ? marks[id] : undefined;
      if (at === undefined) continue;
      next.set(id, at);
      if (previous.get(id) !== at) same = false;
    }
    if (same && next.size === previous.size) return previous;
    last.current = next.size === 0 ? EMPTY : next;
    return last.current;
  });
}

/** Records marks (a mark never moves backwards) and drops them. */
export function useRevisionMarkWriter(kind: MarkKind) {
  const call = useCall();
  const mark = useCallback(
    (entries: Iterable<readonly [id: string, revision: number]>) =>
      void call("marks.mark", {
        kind,
        entries: [...entries].map(
          ([id, revision]) => [id, revision] as [string, number]
        ),
      }).catch(() => undefined),
    [call, kind]
  );
  const unmark = useCallback(
    (ids: Iterable<string>) =>
      void call("marks.unmark", { kind, ids: [...ids] }).catch(() => undefined),
    [call, kind]
  );
  return useMemo(() => ({ mark, unmark }), [mark, unmark]);
}
