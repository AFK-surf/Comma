// scripts/native.ts from a checkout whose path is not ASCII. A URL's pathname keeps such a path percent-encoded, a
// directory that does not exist, so every key, fetch and build failed (`spawnSync git ENOENT`). And `ensure` with a part
// at hand, when R2 cannot be reached.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
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

/// A loopback port nothing listens on: a connection to it is refused.
async function closedPort(): Promise<number> {
  const server = createServer();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as { port: number };
  await new Promise((resolve) => server.close(resolve));
  return port;
}

test("native.ts ensure takes a part at hand without asking R2", async () => {
  const script = join(station, "scripts/native.ts");
  const dir = mkdtempSync(join(tmpdir(), "native-ensure-"));
  try {
    // The runner for linux-x64 in the inbox, as a branch's natives job leaves it: nothing to build on any machine.
    const k = execFileSync(process.execPath, [script, "key", "runner", "linux-x64"], { encoding: "utf8" }).trim();
    const part = join(dir, "part");
    const inbox = join(dir, "inbox");
    mkdirSync(part);
    mkdirSync(inbox);
    writeFileSync(join(part, "stillfail-runner"), "");
    execFileSync("tar", ["-czf", join(inbox, `runner-linux-x64-${k}.tar.gz`), "-C", part, "."]);
    const { STILLFAIL_NATIVE: _policy, ...env } = process.env;
    execFileSync(process.execPath, [script, "ensure", "runner:linux-x64"], {
      env: { ...env, STILLFAIL_NATIVE_CACHE: join(dir, "cache"), STILLFAIL_NATIVE_INBOX: inbox, STILLFAIL_NATIVE_URL: `http://127.0.0.1:${await closedPort()}` },
      stdio: "pipe",
    });
    assert.ok(existsSync(join(dir, "cache/runner", `linux-x64-${k}`, "stillfail-runner")));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
