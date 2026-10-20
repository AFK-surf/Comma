// Ported from systems/connector/salix-connect/cache_cleanup_test.go (same test names).
// Generated caches under a Cloud VM home are removed; project data and anything behind a symlinked parent are not.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { Effect, Exit } from "effect";
import { cleanupGeneratedHomeCaches } from "../../src/connector/cache-cleanup.ts";
import { tempDir } from "./support/temp.ts";

function put(path: string, value: string) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, value);
}

test("TestCleanupGeneratedHomeCaches", async () => {
  const home = tempDir();
  const cache = join(home, ".npm", "_cacache", "content");
  const keep = join(home, "projects", "my-project", ".git", "config");
  put(cache, "retained");
  put(keep, "retained");
  await Effect.runPromise(cleanupGeneratedHomeCaches(home));
  assert.ok(!existsSync(cache), "generated cache remains");
  assert.ok(existsSync(keep), "project data was removed");
});

test("TestCleanupGeneratedHomeCachesRejectsSymlinkedParent", async () => {
  const home = tempDir();
  const outside = tempDir();
  const keep = join(outside, "_cacache", "content");
  put(keep, "retain");
  symlinkSync(outside, join(home, ".npm"));
  assert.ok(Exit.isFailure(await Effect.runPromiseExit(cleanupGeneratedHomeCaches(home))), "symlinked cache parent was accepted");
  assert.ok(existsSync(keep), "outside data was removed");
});
