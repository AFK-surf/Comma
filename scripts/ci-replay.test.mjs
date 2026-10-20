import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = join(import.meta.dirname, "ci-replay.mjs");

const record = (dir, env, ...argv) =>
  spawnSync(process.execPath, [script, "record", "unit", "--", ...argv], {
    cwd: join(import.meta.dirname, "..", "clients"),
    env: { PATH: process.env.PATH, CI_REPLAY_DIR: dir, ...env },
    encoding: "utf8",
  });

test("a recorded command keeps its status, output and the inputs that decide its result", () => {
  const dir = mkdtempSync(join(tmpdir(), "ci-replay-test-"));
  const run = record(
    dir,
    { GITHUB_SHA: "abc123", TZ: "UTC", MIX_ENV: "test", API_TOKEN: "secret" },
    process.execPath,
    "-e",
    "console.log('ran'); process.exit(3)"
  );

  assert.equal(run.status, 3);
  assert.equal(run.stdout, "ran\n");
  assert.equal(readFileSync(join(dir, "unit", "output.log"), "utf8"), "ran\n");
  const entry = JSON.parse(readFileSync(join(dir, "unit", "replay.json"), "utf8"));
  assert.equal(entry.sha, "abc123");
  assert.equal(entry.cwd, "clients");
  assert.deepEqual(entry.argv.slice(1), ["-e", "console.log('ran'); process.exit(3)"]);
  assert.deepEqual(entry.env, { MIX_ENV: "test", TZ: "UTC" });
});
