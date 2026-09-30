import { expect, it } from "vitest";
import type { SessionHistoryRecord } from "../../../../runtime-chat/sessionHistoryBridge";
import { sessionTimeline } from "../timeline/sessionHistoryTimelineModel";
import type { SessionItemPresentation } from "../model/sessionHistoryPresentation";

const epoch = 1_788_564_963_000;
const item = (kind: SessionItemPresentation["kind"]): SessionItemPresentation => ({
  kind,
  tools: [],
  label: kind,
  summary: "",
  duration: undefined,
});
const execution = (
  id: string,
  start: number,
  end: number,
  completed = true
): NonNullable<SessionHistoryRecord["execution"]> => ({
  id,
  lane: "tool",
  started_at_ms: epoch + start,
  observed_at_ms: epoch + end,
  completed_at_ms: completed ? epoch + end : null,
  duration_ms: end - start,
});
const record = (id: string, kind: string, timestamp: number): SessionHistoryRecord => ({
  id,
  kind,
  content: {},
  timestamp_ms: epoch + timestamp,
});

it("clips the mini to a fixed three minutes regardless of record count and advances only known live work", () => {
  const records = Array.from({ length: 200 }, (_, i) =>
    record(String(i), "user", i * 1000)
  );
  const running = {
    ...record("live", "tool", 0),
    execution: { ...execution("live", -20_000, 0, false), live: true },
  };
  const unknown = {
    ...record("unknown", "tool", 0),
    execution: execution("unknown", -20_000, 0, false),
  };
  const all = [...records, running, unknown];
  const items = [...records.map(() => item("input")), item("running"), item("running")];
  const now = epoch + 199_000;
  const model = sessionTimeline(all, items, { start: now - 180_000, end: now }, now);
  expect(model.spans.filter((s) => s.lane === 0)).toHaveLength(181);
  expect(model.spans.find((s) => s.id === "tool:live")?.end).toBe(now);
  expect(model.spans.find((s) => s.id === "tool:unknown")).toBeUndefined();
  const later = sessionTimeline(
    all,
    items,
    { start: now + 60_000 - 180_000, end: now + 60_000 },
    now + 60_000
  );
  expect(later.spans.filter((s) => s.lane === 0)).toHaveLength(121);
  expect(running.execution.observed_at_ms).toBe(epoch);
});

it("preserves real gaps and overlapping tool intervals", () => {
  const model = sessionTimeline(
    [
      { ...record("1", "tool", 1000), execution: execution("a", 0, 1000) },
      { ...record("2", "tool", 800), execution: execution("b", 200, 800) },
      record("3", "user", 8000),
    ],
    [item("success"), item("success"), item("input")]
  );
  const a = model.spans.find((span) => span.id === "tool:a")!,
    b = model.spans.find((span) => span.id === "tool:b")!;
  expect([a.start, a.end, b.start, b.end]).toEqual([
    epoch,
    epoch + 1000,
    epoch + 200,
    epoch + 800,
  ]);
  expect(a.track).not.toBe(b.track);
  expect(model.end - model.start).toBe(8000);
});

it("reuses a track for sequential work and separates only simultaneous events", () => {
  const model = sessionTimeline(
    [
      { ...record("1", "tool", 100), execution: execution("a", 0, 100) },
      { ...record("2", "tool", 101), execution: execution("b", 100, 101) },
      record("3", "user", 0),
      record("4", "runtime", 1),
      record("5", "summary", 1000),
      record("6", "user", 1000),
    ],
    [
      item("success"),
      item("success"),
      item("input"),
      item("runtime"),
      item("context"),
      item("input"),
    ]
  );
  expect(model.spans.slice(0, 5).map((span) => span.track)).toEqual([0, 0, 0, 0, 0]);
  expect(model.spans[5]!.track).toBe(1);
  expect(model.tracks).toEqual([2, 1, 1]);
});

it("folds tool lifecycle events into one interval and never reopens a terminal interval", () => {
  const model = sessionTimeline(
    [
      { ...record("1", "tool", 100), execution: execution("a", 0, 100, false) },
      { ...record("2", "runtime", 500), execution: execution("a", 0, 450) },
      { ...record("3", "tool", 600), execution: execution("a", 0, 100, false) },
      { ...record("4", "tool", 700), execution: execution("b", 650, 700, false) },
    ],
    [item("running"), item("success"), item("running"), item("running")]
  );
  expect(model.spans.find((span) => span.id === "tool:a")).toMatchObject({
    start: epoch,
    end: epoch + 450,
    shape: "interval",
    recordIds: ["tool:a", "1", "2", "3"],
  });
  expect(model.spans).toHaveLength(2);
  expect(model.spans.some((span) => span.id === "record:2")).toBe(false);
  expect(model.spans.find((span) => span.id === "tool:b")).toMatchObject({
    shape: "open",
    end: epoch + 700,
  });
});

it("retains messages, measured model work, migrations, simultaneous events and untimed records", () => {
  const model = sessionTimeline(
    [
      record("1", "user", 0),
      {
        ...record("2", "assistant", 300),
        execution: { ...execution("model", 50, 250), lane: "model" },
      },
      record("3", "runtime", 350),
      record("4", "runtime", 350),
      record("5", "future", 350),
      record("context", "summary", 0),
      {
        id: "6",
        kind: "tool",
        content: { started_at: 123, duration_ms: 99 },
        created_at: 100,
      },
    ],
    [
      item("input"),
      item("model"),
      item("runtime"),
      item("migration"),
      item("unknown"),
      item("context"),
      item("result"),
    ]
  );
  // Inspect the original source correspondence independently of display order.
  const spans = model.spans.toSorted((a, b) => a.index - b.index);
  expect(spans.map((span) => span.lane)).toEqual([0, 1, 0, 0, 0, 0]);
  expect(model.tracks).toHaveLength(3);
  expect(spans[1]).toMatchObject({ start: epoch + 50, end: epoch + 250 });
  expect(new Set(spans.slice(2, 5).map((span) => span.track)).size).toBe(3);
  expect(spans[5]).toMatchObject({ lane: 0, kind: "context" });
  expect(spans[0]).toMatchObject({ lane: 0, kind: "input" });
  expect(model.unknown).toEqual([{ id: "6", index: 6 }]);
});
