import type { SessionHistoryRecord } from "../useSessionHistory";
import {
  argumentSummary,
  sessionDataObject,
  sessionRecordData,
  sessionToolCalls,
  sessionOperationSummary,
  sessionOperationDestination,
  type SessionItemPresentation,
} from "./sessionHistoryPresentation";

export type SessionHistoryEntry = {
  id: string;
  index: number;
  record: SessionHistoryRecord;
  item: SessionItemPresentation;
  recordIds: string[];
  debugRecords: SessionHistoryRecord[];
  tool: boolean;
};

/** The ledger clock and ordering must use the same timestamp. */
export function sessionRecordStartTime(record: SessionHistoryRecord): number | null {
  const measured = record.execution?.started_at_ms ?? record.timestamp_ms;
  if (measured != null) return measured;
  const created = record.created_at;
  if (created == null) return null;
  const time = new Date(
    typeof created === "number" && created < 1e12 ? created * 1000 : created
  ).getTime();
  return Number.isNaN(time) ? null : time;
}

/** Entries are rebuilt whenever the loaded window changes. An entry with the
 * same records and the same projected item renders the same row. */
export function sameSessionHistoryEntry(
  a: SessionHistoryEntry,
  b: SessionHistoryEntry
) {
  return (
    a === b ||
    (a.id === b.id &&
      a.index === b.index &&
      a.tool === b.tool &&
      a.record === b.record &&
      a.recordIds.length === b.recordIds.length &&
      a.recordIds.every((id, index) => id === b.recordIds[index]) &&
      a.debugRecords.length === b.debugRecords.length &&
      a.debugRecords.every((record, index) => record === b.debugRecords[index]) &&
      sameSessionHistoryValue(a.item, b.item))
  );
}

const entryOrderKey = (id: string) =>
  /^\d{1,20}$/.test(id) ? id.padStart(32, "0") : id;

// The ledger and its timeline project the same window, and the timeline does
// so again on every clock tick. Entries are read-only, so they share one result.
let lastEntries:
  | {
      records: readonly SessionHistoryRecord[];
      items: readonly SessionItemPresentation[];
      entries: readonly SessionHistoryEntry[];
    }
  | undefined;

/** A loaded-window projection. Only explicit call ids join lifecycle records;
 * names and adjacency never join concurrent calls or unrelated runtime notices. */
export function sessionHistoryEntries(
  records: readonly SessionHistoryRecord[],
  items: readonly SessionItemPresentation[]
): readonly SessionHistoryEntry[] {
  if (lastEntries?.records === records && lastEntries.items === items)
    return lastEntries.entries;
  const entries = projectSessionHistoryEntries(records, items);
  lastEntries = { records, items, entries };
  return entries;
}

function projectSessionHistoryEntries(
  records: readonly SessionHistoryRecord[],
  items: readonly SessionItemPresentation[]
): SessionHistoryEntry[] {
  const entries: SessionHistoryEntry[] = [];
  const tools = new Map<string, SessionHistoryEntry>();
  records.forEach((record, index) => {
    const item = items[index]!;
    if (record.kind === "assistant") {
      const content = sessionDataObject(record.content);
      const calls = sessionToolCalls(content.tool_calls);
      entries.push({
        id: record.id,
        index,
        record,
        item: calls.length ? { ...item, tools: [], summary: "" } : item,
        recordIds: [record.id],
        debugRecords: [record],
        tool: false,
      });
      for (const call of calls) {
        if (!call.id) continue;
        const existing = tools.get(call.id);
        if (existing) {
          existing.debugRecords.unshift(record);
          continue;
        }
        const entry: SessionHistoryEntry = {
          id: `tool:${call.id}`,
          index,
          record,
          item: {
            ...item,
            kind: "call",
            tools: [call.name],
            summary:
              call.name === "im_api.internal.send_message"
                ? ""
                : argumentSummary(call.args),
            operation: sessionOperationSummary(call.args),
            ...sessionOperationDestination(call.args),
            ...(call.name === "env.exec" && typeof call.args.description === "string"
              ? { action: call.args.description }
              : {}),
            duration: undefined,
          },
          recordIds: [],
          debugRecords: [record],
          tool: true,
        };
        tools.set(call.id, entry);
        entries.push(entry);
      }
      return;
    }
    const data = sessionRecordData(record);
    const result = sessionDataObject(data.result);
    const isTool =
      record.kind === "tool" ||
      record.kind.startsWith("session.async_tool_call_") ||
      record.execution?.lane === "tool" ||
      (typeof data.type === "string" && data.type.startsWith("tool_call_"));
    const callId = isTool
      ? (data.tool_call_id ?? result.id ?? record.execution?.id)
      : undefined;
    if (typeof callId !== "string" || !callId) {
      entries.push({
        id: record.id,
        index,
        record,
        item,
        recordIds: [record.id],
        debugRecords: [record],
        tool: false,
      });
      return;
    }
    const existing = tools.get(callId);
    if (!existing) {
      const entry = {
        id: `tool:${callId}`,
        index,
        record,
        item,
        recordIds: [record.id],
        debugRecords: [record],
        tool: true,
      };
      tools.set(callId, entry);
      entries.push(entry);
      return;
    }
    existing.recordIds.push(record.id);
    existing.debugRecords.push(record);
    // A delayed receipt cannot replace a result already observed in this window.
    if (
      existing.record.kind !== "assistant" &&
      !["running", "call"].includes(existing.item.kind) &&
      item.kind === "running"
    )
      return;
    existing.record = record;
    existing.index = index;
    existing.item = {
      ...item,
      tools: item.tools.length ? item.tools : existing.item.tools,
      ...(item.destination || existing.item.destination
        ? { destination: item.destination || existing.item.destination }
        : {}),
      ...(item.operation || existing.item.operation
        ? { operation: item.operation || existing.item.operation }
        : {}),
      ...(item.action || existing.item.action
        ? { action: item.action || existing.item.action }
        : {}),
    };
  });
  // Sort after folding: the result supplies the tool's measured start, which
  // can precede records committed earlier. Undated rows precede timed rows.
  // Canonical records and their pagination/SSE cursors retain append order.
  return entries.toSorted((a, b) => {
    const time =
      (sessionRecordStartTime(a.record) ?? -Infinity) -
      (sessionRecordStartTime(b.record) ?? -Infinity);
    const aId = entryOrderKey(a.id);
    const bId = entryOrderKey(b.id);
    return time || (aId < bId ? -1 : aId > bId ? 1 : 0);
  });
}

/** Structural equality for JSON-like history values: records and the plain items projected from them. */
export function sameSessionHistoryValue(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null)
    return false;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    for (let index = 0; index < a.length; index++)
      if (!sameSessionHistoryValue(a[index], b[index])) return false;
    return true;
  }
  const left = a as Record<string, unknown>;
  const right = b as Record<string, unknown>;
  let keys = 0;
  for (const key in left) {
    if (!Object.hasOwn(left, key)) continue;
    keys++;
    if (!Object.hasOwn(right, key) || !sameSessionHistoryValue(left[key], right[key]))
      return false;
  }
  for (const key in right) if (Object.hasOwn(right, key)) keys--;
  return keys === 0;
}
