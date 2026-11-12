// The station's Stats index (src/stats): its own rows and those an adapter brings in from Comma on the same
// machine, in one structure, numbered as they change and sent a page at a time as the Task index is.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { Store, newMessage } from "../src/store/store.ts";
import { writeState } from "../src/cloud/state.ts";
import { StatsIndex } from "../src/stats/index.ts";
import type { UsageRow } from "../src/stats/rows.ts";
import { selfRows } from "../src/stats/self.ts";
import { nextPage, probePage, statsWireRow } from "../src/connector/task-index.ts";

const dirs: string[] = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
// Short: a Unix socket's path has at most 104 bytes on macOS.
const tempdir = () => {
  const d = mkdtempSync(join(tmpdir(), "st-"));
  dirs.push(d);
  return d;
};

const DAY = 24 * 60 * 60_000;
const NOW = Date.UTC(2026, 9, 29, 12);
const usage = (day: string, calls: number, model = "claude-opus-5-5"): UsageRow => ({
  day, session: "s1", thread: 1, person: "ann@x", account: "cc", runtime: "claude", model, calls, input: calls * 100, cacheRead: 0, cacheWrite: 0, output: calls, cost: calls * 0.01,
});
const task = (thread: number, title: string) => ({ thread, surface: "page", title, state: "all_done", creator: "ann@x", createdAt: 1, lastActiveAt: NOW, archived: false, agents: [] });

function storeAt(dir: string) {
  const store = Store.open(join(dir, "station.db"), null);
  after(() => store.close());
  return store;
}

test("rows are numbered as they change; a usage row of the days built no longer given goes; tasks stay", () => {
  const store = storeAt(tempdir());
  const index = new StatsIndex(store.db);
  let told = 0;
  index.listen(() => told++);
  const from = NOW - 2 * DAY;
  assert.equal(index.apply("self", { usage: [usage("2026-10-28", 1), usage("2026-10-29", 2)], tasks: [task(1, "Fix")] }, from), 3);
  assert.equal(index.rev(), 3);
  assert.equal(told, 1);
  // the same rows again: nothing changes
  assert.equal(index.apply("self", { usage: [usage("2026-10-28", 1), usage("2026-10-29", 2)], tasks: [task(1, "Fix")] }, from), 0);
  assert.equal(told, 1);
  // one grew, one is gone (its calls were another day's), the task not given again stays
  assert.equal(index.apply("self", { usage: [usage("2026-10-29", 5)], tasks: [] }, from), 2);
  const rows = index.since(3, 10);
  assert.deepEqual(rows.map((r) => [r.kind, r.removed, JSON.parse(r.json).calls ?? null]), [["usage", false, 5], ["usage", true, 1]]);
  assert.equal(index.since(0, 10).filter((r) => r.kind === "task" && !r.removed).length, 1);
  // another source's rows are its own
  assert.equal(index.apply("stillfail", { usage: [usage("2026-10-29", 7)], tasks: [] }, from), 1);
  assert.equal(index.since(0, 10).filter((r) => !r.removed).length, 3);
  // rows before the days built stay as they were
  assert.equal(index.apply("self", { usage: [], tasks: [] }, NOW), 1, "only 2026-10-29's row goes");
  // tombstones Salix holds go
  index.prune(index.rev());
  assert.ok(index.since(0, 100).every((r) => !r.removed));
});

test("pages carry each row's source, kind and key, as the Task index's pages do", () => {
  const store = storeAt(tempdir());
  const index = new StatsIndex(store.db);
  index.apply("stillfail", { usage: [usage("2026-10-29", 3)], tasks: [task(9, "Theirs")] }, NOW - DAY);
  const paged = { epoch: () => index.epoch(), rev: () => index.rev(), since: (s: number, l: number) => index.since(s, l), prune: () => {}, listen: () => () => {} };
  assert.deepEqual(probePage(paged), { epoch: index.epoch(), reset: false, since: 2, through: 2, rows: [] });
  const page = nextPage(paged, { epoch: null, through: 0 }, statsWireRow)!;
  assert.equal(page.reset, true);
  assert.deepEqual(page.rows.map((r: any) => [r.source, r.kind, r.row.calls ?? r.row.title]), [["stillfail", "usage", 3], ["stillfail", "task", "Theirs"]]);
  assert.equal(nextPage(paged, { epoch: index.epoch(), through: 2 }, statsWireRow), null);
});

test("the station's own rows: its usage by day and its chats", () => {
  const dir = tempdir();
  const store = storeAt(dir);
  store.insertSession({ key: "a", connect: "ember", runtime: "claude", profile: "cc", workspace: "/w/a", token: "a", createdAt: 1, lastActiveAt: 1, createdBy: "ann@x" } as never);
  const thread = store.openThreadOf("ember", "EMBER", "300.1", "Fix the build", "ann@x", "a");
  store.joinThread(thread.id, "a", "ember");
  store.insertMessage(newMessage(thread.id, "300.2", "person", "ann@x", "it fails"));
  store.startTurnFor("t1", "a", "input", { profile: "cc", person: "ann@x", thread: thread.id });
  store.endTurn("t1", "done", null, "all_done", null);
  const call = { id: "c1", at: NOW, model: "claude-opus-5-5", subagent: false, fast: false, input: 100, cacheRead: 40, cacheWrite: 10, cacheWriteLong: 0, output: 5 };
  store.recordUsage("/a.jsonl", { session: "a", offset: 1, model: null }, "claude", [[call, { turn: "t1", person: "ann@x", thread: thread.id, profile: "cc" }]] as never);
  const rows = selfRows(store.db, dir, NOW - DAY);
  assert.deepEqual(rows.usage!.map((u) => [u.day, u.person, u.account, u.calls, u.input, u.cacheWrite]), [["2026-10-29", "ann@x", "cc", 1, 100, 10]]);
  assert.ok((rows.usage![0]!.cost ?? 0) > 0);
  assert.deepEqual(rows.tasks!.map((t) => [t.thread, t.title, t.state, t.surface]), [[thread.id, "Fix the build", "all_done", "page"]]);
});

test("a build takes every source; one that fails keeps what it gave before", async () => {
  const store = storeAt(tempdir());
  const index = new StatsIndex(store.db);
  const failed: string[] = [];
  const changed = await index.build(
    [
      { id: "self", rows: async () => ({ usage: [usage("2026-10-29", 1)], tasks: [] }) },
      { id: "stillfail", rows: async () => { throw new Error("down"); } },
      { id: "none", rows: async () => null },
    ],
    NOW,
    (s) => failed.push(s),
  );
  assert.equal(changed, 1);
  assert.deepEqual(failed, ["stillfail"]);
});

test("an outside source's standing is a row of its own; a source giving only that keeps its usage", () => {
  const store = storeAt(tempdir());
  const index = new StatsIndex(store.db);
  const from = NOW - DAY;
  index.apply("stillfail", { usage: [usage("2026-10-29", 2)], tasks: [], status: { state: "granted", at: 1, scopes: ["usage"] } }, from);
  index.apply("stillfail", { status: { state: "revoked", at: 2 } }, from);
  const live = index.since(0, 10).filter((r) => !r.removed);
  assert.deepEqual(live.map((r) => [r.kind, JSON.parse(r.json).state ?? JSON.parse(r.json).calls]).sort(), [["source", "revoked"], ["usage", 2]]);
});
