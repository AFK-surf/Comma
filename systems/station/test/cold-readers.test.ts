// Packed transcripts as the readers read them (the Rust station's transcript/tests.rs
// `compressed_transcript_stays_discoverable_and_continues_after_restore`, usage/tests.rs
// `compressed_history_keeps_usage_offsets_and_subagent_discovery`).
import assert from "node:assert/strict";
import { appendFileSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { transcriptPath } from "../src/read/transcript.ts";
import { packFile, restoreFile } from "../src/sessions/archive.ts";
import { TranscriptTail } from "../src/sessions/live.ts";
import { claudeFiles, readFrom } from "../src/usage/counter.ts";

const temp = () => realpathSync(mkdtempSync(join(tmpdir(), "cold-readers-")));

test("a compressed transcript stays discoverable and continues after restore", async () => {
  const home = temp();
  const path = join(home, "projects/x/archive-test.jsonl");
  mkdirSync(dirname(path), { recursive: true });
  const line = (text: string) => `${JSON.stringify({ type: "user", message: { content: text } })}\n`;
  writeFileSync(path, line("before"));
  await packFile(path);
  assert.equal(transcriptPath("claude", home, "archive-test"), path);
  const tail = new TranscriptTail("claude", path);
  assert.equal(tail.read()[1][0]!.text, "before");
  assert.deepEqual(tail.read()[1], []);
  await restoreFile(path);
  writeFileSync(path, line("before") + line("after"));
  assert.equal(tail.read()[1][0]!.text, "after");
  assert.equal(tail.entries.length, 2);
  rmSync(home, { recursive: true });
});

test("compressed history keeps usage offsets and subagent discovery", async () => {
  const root = temp();
  const main = join(root, "session.jsonl");
  const sub = join(root, "session/subagents/agent.jsonl");
  mkdirSync(dirname(sub), { recursive: true });
  writeFileSync(main, "first\nsecond\n");
  writeFileSync(sub, "child\n");
  await packFile(main);
  await packFile(sub);
  const parts = async (path: string, offset: number) => {
    const out = [];
    for await (const part of readFrom(path, offset)) out.push(part);
    return out;
  };
  assert.deepEqual(await parts(main, 6), [{ text: "second\n", offset: 13 }]);
  assert.deepEqual(await parts(main, 13), []);
  const files = await claudeFiles(root, "session");
  assert.ok(files.some(([p, s]) => p === main && !s));
  assert.ok(files.some(([p, s]) => p === sub && s));
  await restoreFile(main);
  appendFileSync(main, "third\n");
  assert.deepEqual(await parts(main, 13), [{ text: "third\n", offset: 19 }]);
  rmSync(root, { recursive: true });
});
