import type { SessionHistoryRecord } from "@comma/native-bridge";

/** Keeps each unchanged record object from `previous`, and `previous` itself
 * when no record changed. Stream frames are parsed again on every heartbeat
 * and every host delivery is a structured clone, so unchanged records arrive
 * as new objects. Identity is the cheap signal that publishers and memoized
 * projections use to skip work for records that did not change. */
export function reuseSessionHistoryRecords(
  previous: SessionHistoryRecord[],
  next: SessionHistoryRecord[]
): SessionHistoryRecord[] {
  if (previous === next) return previous;
  const byId = new Map(previous.map((record) => [record.id, record]));
  let changed = previous.length !== next.length;
  const records = next.map((record, index) => {
    const prior = byId.get(record.id);
    const kept = prior && sameSessionHistoryValue(prior, record) ? prior : record;
    if (kept !== previous[index]) changed = true;
    return kept;
  });
  return changed ? records : previous;
}

/** Structural equality for JSON-like history values: records and the plain
 * items projected from them. */
export function sameSessionHistoryValue(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null)
    return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const left = a as Record<string, unknown>;
  const right = b as Record<string, unknown>;
  const keys = Object.keys(left);
  return (
    keys.length === Object.keys(right).length &&
    keys.every(
      (key) =>
        Object.hasOwn(right, key) && sameSessionHistoryValue(left[key], right[key])
    )
  );
}
