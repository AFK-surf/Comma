// scripts/native.ts from a checkout whose path is not ASCII. A URL's pathname keeps such a path percent-encoded, a
// directory that does not exist, so every key, fetch and build failed (`spawnSync git ENOENT`).
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const station = fileURLToPath(new URL("..", import.meta.url));

/// The mesh part's key, by native.ts run from `checkout` as given (a symlinked path stays the path it sees).
function meshKey(checkout: string): string {
  const script = join(checkout, "systems/station/scripts/native.ts");
  return execFileSync(process.execPath, ["--preserve-symlinks-main", script, "key", "mesh"], {
    encoding: "utf8",
  }).trim();
}

test("native.ts keys a part from a checkout path that is not ASCII", () => {
  const repo = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: station, encoding: "utf8" }).trim();
  const dir = mkdtempSync(join(tmpdir(), "native-path-"));
  try {
    const checkout = join(dir, "ü 🪄 checkout");
    symlinkSync(repo, checkout);
    assert.equal(meshKey(checkout), meshKey(repo));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
