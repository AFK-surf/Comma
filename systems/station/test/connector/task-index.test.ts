// The pages a station sends Salix of its Task index (src/connector/task-index.ts): all of it again for another epoch,
// what Salix lacks otherwise, bounded, and rows as Salix reads them.

import assert from "node:assert/strict";
import { test } from "node:test";
import type { TaskIndexRow } from "../../src/store/rows.ts";
import { PAGE_ROWS, nextPage, probePage, type StationTaskIndex } from "../../src/connector/task-index.ts";

function index(rows: TaskIndexRow[], epoch = "e1"): StationTaskIndex & { pruned: number[] } {
  const pruned: number[] = [];
  return {
    pruned,
    epoch: () => epoch,
    rev: () => rows.reduce((top, r) => Math.max(top, r.rev), 0),
    since: (since, limit) => rows.filter((r) => r.rev > since).sort((a, b) => a.rev - b.rev).slice(0, limit),
    prune: (through) => void pruned.push(through),
    listen: () => () => {},
  };
}

const task = (thread: number, rev: number, fields: Record<string, unknown> = {}): TaskIndexRow => ({
  thread,
  rev,
  removed: false,
  json: JSON.stringify({ task: `C1/${thread}.0`, thread, title: `Task ${thread}`, status: "in_progress", created_by: "U1", created_at: 1000, last_activity_at: 2000, runtime: "codex", model: "gpt-5.5", rev, ...fields }),
});

test("Salix holding another epoch, or none, gets all of the index again with reset", () => {
  const ix = index([task(1, 1), { thread: 2, rev: 2, removed: true, json: "{}" }, task(3, 3)]);
  for (const held of [{ epoch: null, through: 0 }, { epoch: "e0", through: 9 }]) {
    const page = nextPage(ix, held)!;
    assert.deepEqual({ ...page, rows: page.rows.map((r) => [r.thread, r.rev, r.removed ?? false]) }, {
      epoch: "e1",
      reset: true,
      since: 0,
      through: 3,
      rows: [["1", 1, false], ["2", 2, true], ["3", 3, false]],
    });
  }
});

test("Salix holding the epoch gets only what it lacks, and nothing once it holds all", () => {
  const ix = index([task(1, 1), task(2, 2), task(3, 3)]);
  const page = nextPage(ix, { epoch: "e1", through: 1 })!;
  assert.deepEqual([page.reset, page.since, page.through, page.rows.map((r) => r.thread)], [false, 1, 3, ["2", "3"]]);
  assert.equal(nextPage(ix, { epoch: "e1", through: 3 }), null);
  // The probe asks what Salix holds and changes nothing there: no rows, through what it continues from.
  assert.deepEqual(probePage(ix), { epoch: "e1", reset: false, since: 3, through: 3, rows: [] });
});

test("a long index goes in pages of at most 200 rows, each bringing Salix to its last row", () => {
  const ix = index(Array.from({ length: 450 }, (_, i) => task(i + 1, i + 1)));
  const first = nextPage(ix, { epoch: null, through: 0 })!;
  assert.deepEqual([first.reset, first.rows.length, first.through], [true, PAGE_ROWS, 200]);
  const second = nextPage(ix, { epoch: "e1", through: first.through })!;
  assert.deepEqual([second.reset, second.since, second.rows.length, second.through], [false, 200, 200, 400]);
  const last = nextPage(ix, { epoch: "e1", through: second.through })!;
  assert.deepEqual([last.rows.length, last.through], [50, 450]);
});

test("rows carry what Salix accepts: thread as text, a title always, a model Salix keeps whole, at most 20 labels", () => {
  const ix = index([
    task(7, 1, {
      title: null,
      created_by: null,
      model: "m".repeat(130),
      labels: ["lbl_a", 3, "", ...Array.from({ length: 25 }, (_, i) => `l${i}`)],
    }),
  ]);
  const [row] = nextPage(ix, { epoch: null, through: 0 })!.rows;
  assert.deepEqual(row, {
    thread: "7",
    rev: 1,
    task: "C1/7.0",
    title: "",
    status: "in_progress",
    created_by: null,
    created_at: 1000,
    last_activity_at: 2000,
    runtime: "codex",
    model: "m".repeat(120),
    labels: ["lbl_a", ...Array.from({ length: 19 }, (_, i) => `l${i}`)],
  });
});
