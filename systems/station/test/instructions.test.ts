// The agent's instructions and the migration notes (src/agents/instructions.ts, migrations.ts: their source).
import assert from "node:assert/strict";
import { test } from "node:test";
import * as ts from "../src/agents/instructions.ts";
import { NOTES, latest, untold } from "../src/agents/migrations.ts";

test("the session instructions name the session's places, and a project only when it has one", () => {
  const plain = ts.sessionInstructions("/w/s/workspace", null, "/w/repos", "/w/agent/MEMORY.md");
  for (const place of ["/w/s/workspace", "/w/repos", "/w/agent/MEMORY.md"]) assert.ok(plain.includes(place), place);
  assert.ok(!plain.includes("Project directory"));
  const project = ts.sessionInstructions("/w/s/workspace", "/p", "/w/repos", "/w/agent/MEMORY.md");
  assert.ok(project.includes("- Project directory: /p. This session began outside still.fail"));
  assert.equal(project.replace(/- Project directory: [^\n]*\n/, ""), plain);
});

test("the fixed prompts", () => {
  for (const name of ["NUDGE", "RESUME_AFTER_RESTART", "GO_ON_AFTER_AUTH", "GO_ON_AFTER_SPENT", "RESUME_LOST"] as const) assert.ok(ts[name].length > 20, name);
  assert.ok(ts.waitOver(90).includes("(90 seconds)"));
  assert.ok(ts.continuedHere("X").endsWith("<stillfail-instructions>\nX\n</stillfail-instructions>"));
});

test("the migration notes are numbered 1, 2, 3…, and told once", () => {
  assert.deepEqual(NOTES.map(([n]) => n), NOTES.map((_, i) => i + 1));
  assert.ok(NOTES.every(([, note]) => note.length > 0 && !note.includes("\n")));
  assert.equal(untold(latest(), "/w/i.md"), "");
  const all = untold(0, "/w/i.md");
  assert.ok(all.startsWith("[still.fail changed how you work") && all.includes("need_human") && all.includes("/w/i.md"));
  assert.ok(!untold(latest() - 1, "/w/i.md").includes(NOTES[0]![1]));
});

test("thread addresses as the agent writes them", () => {
  assert.deepEqual(ts.parseThreadAddress(" C123/1790000000.000100 "), ["C123", "1790000000.000100"]);
  for (const bad of ["c123/1.2", "C123/1", "C123/.2", "/1.2", "C123-1.2"]) assert.equal(ts.parseThreadAddress(bad), null, bad);
});
