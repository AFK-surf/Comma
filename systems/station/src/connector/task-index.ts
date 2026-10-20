// The station's Task index as Salix keeps a copy of it (SalixStore.StationTaskIndex): the connector sends it in
// `task.index` pages on its connection once Salix has the station's endpoint id (`relay_register`), and Salix answers
// what it holds, `{epoch, through}`. A page continues from what Salix holds; another epoch is sent all again with
// `reset`. Tombstones go once Salix holds them.

import type { TaskIndexRow } from "../store/rows.ts";

/** What the connector reads of the station's Task index (Store::taskIndex*). */
export type StationTaskIndex = {
  epoch(): string;
  rev(): number;
  since(since: number, limit: number): TaskIndexRow[];
  prune(through: number): void;
  /// Called after the station's writes, which may have changed the index.
  listen(changed: () => void): () => void;
};

/** What Salix holds of the index. */
export type HeldIndex = { epoch: string | null; through: number };

/** A `task.index` page. */
export type IndexPage = { epoch: string; reset: boolean; since: number; through: number; rows: Record<string, unknown>[] };

/** Salix's bounds on a page: rows, and bytes of its rows as JSON. */
export const PAGE_ROWS = 200;
export const PAGE_BYTES = 60 * 1024;
// Salix keeps at most this many characters of each.
const MAX_TEXT = 200;
const MAX_RUNTIME = 40;
const MAX_MODEL = 120;
/// A Task's labels: the Group's label ids, at most this many, each at most MAX_LABEL bytes.
const MAX_LABELS = 20;
const MAX_LABEL = 128;

/** The page that asks only what Salix holds: applying it changes nothing. */
export function probePage(index: StationTaskIndex): IndexPage {
  const rev = index.rev();
  return { epoch: index.epoch(), reset: false, since: rev, through: rev, rows: [] };
}

/** The next page to send after Salix answered `held`; null once Salix holds all of it. */
export function nextPage(index: StationTaskIndex, held: HeldIndex): IndexPage | null {
  const epoch = index.epoch();
  const rev = index.rev();
  const reset = held.epoch !== epoch;
  const since = reset ? 0 : held.through;
  if (!reset && since >= rev) return null;
  const changed = index.since(since, PAGE_ROWS + 1);
  const rows: Record<string, unknown>[] = [];
  let bytes = 2;
  let taken = 0;
  let last = since;
  for (const row of changed.slice(0, PAGE_ROWS)) {
    const wire = wireRow(row);
    const size = wire === null ? 0 : Buffer.byteLength(JSON.stringify(wire)) + 1;
    if (rows.length > 0 && bytes + size > PAGE_BYTES) break;
    if (wire !== null) rows.push(wire);
    bytes += size;
    taken += 1;
    last = row.rev;
  }
  // A page short of the end brings Salix to its last row; the last page to the index's rev, past pruned tombstones.
  const through = taken < changed.length ? last : rev;
  return { epoch, reset, since, through, rows };
}

/** A row as `task.index` carries it: the Task's facts, never its text; a tombstone for a deleted Task. */
export function wireRow(row: TaskIndexRow): Record<string, unknown> | null {
  const thread = String(row.thread);
  if (row.removed) return { thread, rev: row.rev, removed: true };
  let task: Record<string, any>;
  try {
    task = JSON.parse(row.json);
  } catch {
    return null;
  }
  return {
    thread,
    rev: row.rev,
    task: cut(task.task, MAX_TEXT) ?? thread,
    title: typeof task.title === "string" ? task.title : "",
    status: task.status,
    created_by: cut(task.created_by, MAX_TEXT),
    created_at: whole(task.created_at),
    last_activity_at: whole(task.last_activity_at ?? task.created_at),
    runtime: cut(task.runtime, MAX_RUNTIME),
    model: cut(task.model, MAX_MODEL),
    labels: Array.isArray(task.labels)
      ? task.labels.filter((id: unknown): id is string => typeof id === "string" && id !== "" && Buffer.byteLength(id) <= MAX_LABEL).slice(0, MAX_LABELS)
      : [],
  };
}

const cut = (value: unknown, max: number): string | null => {
  if (typeof value !== "string" || value === "") return null;
  let out = value;
  while (Buffer.byteLength(out) > max) out = out.slice(0, -1);
  return out;
};

const whole = (value: unknown): number => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? Math.floor(value) : 0);

/** Salix's answer to a page, or null when it is not one. */
export function heldFrom(result: unknown): HeldIndex | null {
  if (typeof result !== "object" || result === null) return null;
  const { epoch, through } = result as Record<string, unknown>;
  if (epoch !== null && typeof epoch !== "string") return null;
  return { epoch: epoch ?? null, through: typeof through === "number" && through >= 0 ? through : 0 };
}
