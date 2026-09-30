import { expect, it } from "vitest";
import type { SessionHistoryRecord } from "../../../../runtime-chat/sessionHistoryBridge";
import { sessionHistoryEntries } from "../model/sessionHistoryEntries";
import type { SessionItemPresentation } from "../model/sessionHistoryPresentation";

const epoch = 1_788_564_963_000;
const item = (kind: SessionItemPresentation["kind"]): SessionItemPresentation => ({
  kind,
  label: kind,
  summary: "",
  tools: [],
  duration: undefined,
});
const record = (id: string, time: number): SessionHistoryRecord => ({
  id,
  kind: "user",
  content: {},
  timestamp_ms: epoch + time,
});

it("orders merged parallel tools by execution start, retaining source indices and lifecycle debug", () => {
  const records: SessionHistoryRecord[] = [
    {
      ...record("1", 0),
      kind: "assistant",
      content: { tool_calls: [{ id: "slow", name: "read", args: {} }] },
    },
    record("2", 100),
    {
      ...record("3", 1000),
      kind: "tool",
      execution: {
        id: "fast",
        lane: "tool",
        started_at_ms: epoch + 300,
        observed_at_ms: epoch + 1000,
        completed_at_ms: epoch + 1000,
        duration_ms: 700,
      },
    },
    {
      ...record("4", 2000),
      kind: "session.async_tool_call_completed",
      content: { tool_call_id: "slow" },
      execution: {
        id: "slow",
        lane: "tool",
        started_at_ms: epoch + 200,
        observed_at_ms: epoch + 2000,
        completed_at_ms: epoch + 2000,
        duration_ms: 1800,
      },
    },
  ];
  const entries = sessionHistoryEntries(records, [
    item("model"),
    item("input"),
    item("success"),
    item("success"),
  ]);
  expect(entries.map((entry) => entry.id)).toEqual([
    "1",
    "2",
    "tool:slow",
    "tool:fast",
  ]);
  expect(entries.map((entry) => entry.index)).toEqual([0, 1, 3, 2]);
  expect(entries[2]!.debugRecords.map((row) => row.id)).toEqual(["1", "4"]);
  expect(records.map((row) => row.id)).toEqual(["1", "2", "3", "4"]);
});

it("uses the displayed timestamp fallback and stable numeric IDs, keeping undated records first", () => {
  const records: SessionHistoryRecord[] = [
    record("10", 1000),
    {
      id: "3",
      kind: "runtime",
      content: {},
      created_at: new Date(epoch).toISOString(),
    },
    { id: "1", kind: "runtime", content: {} },
    record("2", 1000),
    { id: "4", kind: "runtime", content: {}, created_at: (epoch + 500) / 1000 },
  ];
  const project = (rows: SessionHistoryRecord[]) =>
    sessionHistoryEntries(
      rows,
      rows.map(() => item("input"))
    ).map((entry) => entry.id);
  expect(project(records)).toEqual(["1", "3", "4", "2", "10"]);
  expect(project(records.toReversed())).toEqual(project(records));
});
