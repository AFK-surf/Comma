// The machine's own sessions as the pages list them (src/read/machine.ts), where a transcript's lines are huge: a Codex
// rollout keeps screenshots and tools' outputs in a line each (seen at 16 MB, its first 400 lines at 51 MB), which a
// reader's bounded heap (read/pool.ts) cannot hold. Such a line is passed over; what a listing wants is around it.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { find } from "../src/read/machine.ts";

const dirs: string[] = [];
after(() => dirs.forEach((d) => rmSync(d, { recursive: true, force: true })));

test("a huge line in a rollout's head is passed over: the session is still found, with what was said around it", () => {
  const root = mkdtempSync(join(tmpdir(), "machine-"));
  dirs.push(root);
  const roots = { claude: join(root, ".claude", "projects"), codex: join(root, ".codex", "sessions") };
  const day = join(roots.codex, "2026", "09", "02");
  mkdirSync(day, { recursive: true });
  const id = "33333333-aaaa-bbbb-cccc-000000000001";
  const huge = { type: "response_item", payload: { type: "message", role: "user", content: [{ type: "input_image", image_url: `data:image/png;base64,${"A".repeat(2 << 20)}` }] } };
  const records = [
    { type: "session_meta", payload: { id, cwd: root } },
    huge,
    { type: "response_item", timestamp: "2026-09-02T00:00:01.000Z", payload: { type: "message", role: "user", content: [{ type: "input_text", text: "after the picture" }] } },
    { type: "turn_context", payload: { model: "gpt-5.5" } },
  ];
  writeFileSync(join(day, `rollout-2026-09-02T00-00-00-${id}.jsonl`), records.map((r) => `${JSON.stringify(r)}\n`).join(""));
  const found = find(roots, "codex", id);
  assert.ok(found, "found");
  assert.equal(found.first, "after the picture");
  assert.equal(found.cwd, root);
  assert.equal(found.model, "gpt-5.5");
});
