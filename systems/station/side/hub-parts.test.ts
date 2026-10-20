// The live view following a transcript by its real watch (fs.watch): the OS tells of the file's growth, on real time,
// so it runs beside the checks (`pnpm test:side`). test/hub-parts.test.ts covers what the watch then does, on a
// TestClock.
import assert from "node:assert/strict";
import { appendFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { type LiveMessage, LiveHub } from "../src/sessions/live.ts";

const temp = () => mkdtempSync(join(tmpdir(), "hub-parts-"));

const line = (text: string, id: string) => `${JSON.stringify({ type: "assistant", timestamp: "2026-09-26T00:00:00Z", message: { id, content: [{ type: "text", text }], usage: { input_tokens: 10, output_tokens: 2 } } })}\n`;

test("a watcher gets what it lacks, the steps in flight, then new entries as the file grows", async () => {
  const dir = temp();
  const path = join(dir, "t.jsonl");
  writeFileSync(path, line("one", "m1") + line("two", "m2"));
  const hub = new LiveHub(() => ({ runtime: "claude", paths: [path] }));
  hub.event("s", { kind: "start", id: "x", step: "text" });
  hub.event("s", { kind: "delta", id: "x", field: "text", text: "wri" });
  const got: LiveMessage[] = [];
  const id = hub.subscribe("s", 1, null, (m) => void got.push(m));
  assert.equal(got[0]!.type, "timeline");
  assert.deepEqual((got[0] as any).entries.map((e: any) => e.text), ["two"]);
  assert.equal((got[0] as any).usage.modelCalls, 2);
  assert.equal(got[1]!.type, "steps");
  assert.equal((got[1] as any).steps[0].step, "text", "what a step is, not what it wrote");
  got.length = 0;
  hub.event("s", { kind: "delta", id: "x", field: "text", text: "ting" });
  assert.equal(got.length, 0, "a delta sends nothing");
  hub.event("s", { kind: "end", id: "x" });
  appendFileSync(path, line("writing", "m3"));
  // Told by the file's change, not looked at on a clock.
  for (let i = 0; i < 100 && !got.some((m) => m.type === "timeline" && m.entries.length > 0); i++) await new Promise((r) => setTimeout(r, 20));
  const timeline = got.filter((m): m is Extract<LiveMessage, { type: "timeline" }> => m.type === "timeline").at(-1)!;
  assert.deepEqual([timeline.start, timeline.entries.map((e) => e.text)], [2, ["writing"]]);
  hub.turnEnded("s");
  assert.ok(got.some((m) => m.type === "clear"));
  hub.unsubscribe("s", id);
  hub.close();
  rmSync(dir, { recursive: true, force: true });
});

test("a session gone on in a new runtime session: its history reads on from the transcript it left into the new one", async () => {
  const dir = temp();
  const left = join(dir, "a.jsonl");
  const now = join(dir, "b.jsonl");
  writeFileSync(left, line("one", "m1"));
  let paths = [left];
  const hub = new LiveHub(() => ({ runtime: "claude", paths }));
  const got: LiveMessage[] = [];
  hub.subscribe("s", 0, null, (m) => void got.push(m));
  // The one left gets its last words, then the session moves on.
  appendFileSync(left, line("two", "m2"));
  writeFileSync(now, line("three", "m3"));
  paths = [left, now];
  hub.moved("s");
  appendFileSync(now, line("four", "m4"));
  const told = () => got.flatMap((m) => (m.type === "timeline" ? m.entries.map((e, i) => `${m.start + i}:${e.text}`) : []));
  for (let i = 0; i < 100 && !told().includes("3:four"); i++) await new Promise((r) => setTimeout(r, 20));
  assert.deepEqual(told(), ["0:one", "1:two", "2:three", "3:four"]);
  const last = got.filter((m): m is Extract<LiveMessage, { type: "timeline" }> => m.type === "timeline").at(-1)!;
  assert.equal(last.usage.modelCalls, 4, "the usage of both");
  assert.deepEqual(hub.before("s", 10, 10)![1].map((e) => e.text), ["one", "two", "three", "four"]);
  hub.close();
  rmSync(dir, { recursive: true, force: true });
});
