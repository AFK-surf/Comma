// GET /events as admin/events.rs has it: sidebar rows told by what changed, one `session` event per burst, `read`
// only to its viewer, job logs as they grow; and each event with its sequence number.
import type { Clock } from "effect";
import assert from "node:assert/strict";
import { appendFileSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Events } from "../src/api/events.ts";
import type { StoreChange } from "../src/store/rows.ts";
import { settle, testClock } from "./hub-fakes.ts";

const viewer = (email: string) => ({ sub: email, email, name: email, role: "member", workspace: "w", device: "d" });

function setup(clock?: Clock.Clock) {
  let listener: (c: StoreChange) => void = () => {};
  const rows: Record<string, any[]> = { "a@x": [{ id: "1", title: "one" }], "b@x": [] };
  const reads: string[] = [];
  const readers: any = {
    read: async (op: string, args: any) => {
      reads.push(op);
      if (op === "chats") return JSON.stringify(rows[args.viewer.email] ?? []);
      if (op === "summary") return JSON.stringify({ key: args.key });
      if (op === "entries") return JSON.stringify({ entries: [{ n: 1, text: "hi" }] });
      throw new Error(op);
    },
  };
  const dir = mkdtempSync(join(tmpdir(), "events-"));
  const events = new Events({
    readers,
    subscribe: (l) => ((listener = l), () => {}),
    host: async () => ({ cpu: 1 }),
    jobLog: (id) => (id === "j" ? join(dir, "j.log") : null),
    tail: (path) => require("node:fs").readFileSync(path, "utf8"),
    outputAt: () => 7,
    sessionExists: (key) => key !== "gone",
    clock,
  });
  return { events, rows, reads, change: (c: StoreChange) => listener(c), dir };
}

/// Reads a stream's events as they come.
function reader(body: AsyncIterable<Buffer>) {
  const it = body[Symbol.asyncIterator]();
  const got: { id?: string; event?: string; data?: any; raw: string }[] = [];
  let pump: Promise<void> | null = null;
  const more = () =>
    (pump ??= (async () => {
      for (;;) {
        const next = await it.next();
        if (next.done) return;
        const raw = next.value.toString();
        const m = /^(?:id: (\d+)\n)?event: (.+)\ndata: (.*)\n\n$/.exec(raw);
        got.push(m ? { id: m[1], event: m[2], data: JSON.parse(m[3]!), raw } : { raw });
      }
    })());
  more();
  return { got, close: () => it.return?.() };
}
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);

test("changes are told as events, rows by what changed, read only to its viewer", async () => {
  const { events, rows, change, reads } = setup(testClock().clock);
  const a = reader((await events.open(viewer("a@x"), "zh", false, [], [])).body as AsyncIterable<Buffer>);
  const b = reader((await events.open(viewer("b@x"), "zh", false, [], [])).body as AsyncIterable<Buffer>);
  await settle();
  assert.equal(a.got[0]!.raw, "retry: 3000\n\n");
  rows["a@x"] = [{ id: "1", title: "one" }, { id: "2", title: "two" }];
  reads.length = 0;
  // A burst: one `session` event, one round of rows.
  change({ type: "session", key: "s" });
  change({ type: "session", key: "s" });
  change({ type: "session", key: "gone" });
  change({ type: "read", viewer: "b@x", thread: 3, n: 9 });
  await settle();
  const ofA = a.got.filter((e) => e.event).map((e) => [e.event, e.data]);
  assert.deepEqual(ofA, [["session", { key: "s" }], ["chat", { id: "2", title: "two" }]]);
  const ofB = b.got.filter((e) => e.event).map((e) => [e.event, e.data]);
  assert.deepEqual(ofB, [["read", { viewer: "b@x", thread: 3, n: 9 }], ["session", { key: "s" }]]);
  assert.equal(reads.filter((r) => r === "summary").length, 1);
  // Sequence numbers go up across the station.
  const ids = [...a.got, ...b.got].filter((e) => e.id).map((e) => Number(e.id)).sort((x, y) => x - y);
  assert.equal(new Set(ids).size, ids.length);
  rows["a@x"] = [{ id: "2", title: "two" }];
  change({ type: "threadRemoved", id: 1 });
  await settle();
  assert.deepEqual(a.got.slice(-2).map((e) => [e.event, e.data]), [["thread-removed", { id: 1 }], ["chat-removed", { id: "1" }]]);
  change({ type: "thread", id: 4, entries: [{ n: 1 } as any] });
  await settle();
  assert.deepEqual(b.got.filter((e) => e.event === "thread").map((e) => e.data), [{ id: 4, entries: [{ n: 1, text: "hi" }] }]);
  await a.close();
  await b.close();
  assert.equal(events.inUse(), false);
});

test("a job's log is told now and as it grows", async () => {
  const time = testClock();
  const { events, dir } = setup(time.clock);
  writeFileSync(join(dir, "j.log"), "one\n");
  const s = reader((await events.open(viewer("a@x"), "zh", false, [], [["j", 50], ["nothing", 5]])).body as AsyncIterable<Buffer>);
  await settle();
  appendFileSync(join(dir, "j.log"), "two\n");
  // Looked at again within 5 s, its watch or not (what the watch tells is side/events.test.ts's), once.
  await time.adjust(5_000);
  await settle();
  const logs = s.got.filter((e) => e.event === "job-log").map((e) => e.data);
  assert.deepEqual(logs, [
    { id: "j", lines: 50, text: "one\n", outputAt: 7 },
    { id: "j", lines: 50, text: "one\ntwo\n", outputAt: 7 },
  ]);
  await s.close();
});
