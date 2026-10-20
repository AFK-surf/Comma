// GET /events following a job's log by its real watch (fs.watch): the OS tells of the growth, on real time, so it runs
// beside the checks (`pnpm test:side`). test/events.test.ts covers the rest, on a TestClock.
import assert from "node:assert/strict";
import { appendFileSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Events } from "../src/api/events.ts";

const viewer = { sub: "a@x", email: "a@x", name: "a@x", role: "member", workspace: "w", device: "d" };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

test("a job's log is told as it grows, by its watch (before the 5 s look)", async () => {
  const dir = mkdtempSync(join(tmpdir(), "events-"));
  const events = new Events({
    readers: { read: async () => "[]" } as any,
    subscribe: () => () => {},
    host: async () => ({}),
    jobLog: (id) => (id === "j" ? join(dir, "j.log") : null),
    tail: (path) => readFileSync(path, "utf8"),
    outputAt: () => 7,
    sessionExists: () => true,
  });
  writeFileSync(join(dir, "j.log"), "one\n");
  const it = ((await events.open(viewer, "zh", false, [], [["j", 50]])).body as AsyncIterableIterator<Buffer>)[Symbol.asyncIterator]();
  const texts: string[] = [];
  const pump = (async () => {
    for (;;) {
      const next = await it.next();
      if (next.done) return;
      const m = /event: job-log\ndata: (.*)\n/.exec(next.value.toString());
      if (m) texts.push(JSON.parse(m[1]!).text);
    }
  })();
  while (texts.length < 1) await sleep(20);
  appendFileSync(join(dir, "j.log"), "two\n");
  const started = Date.now();
  while (texts.length < 2) await sleep(20);
  assert.ok(Date.now() - started < 4_000, "told by the watch, not the 5 s look");
  assert.deepEqual(texts, ["one\n", "one\ntwo\n"]);
  await it.return?.();
  await pump;
});
