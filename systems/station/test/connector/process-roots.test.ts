// process_start with root grants: a device MCP server starts only inside the roots its binding was granted, the
// working directory resolved through links, and the refusal reads as the gateway's missing root.
import assert from "node:assert/strict";
import { mkdirSync, symlinkSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { Effect, Exit } from "effect";
import { makeConnector } from "../../src/connector/connector.ts";
import { tempDir } from "./support/temp.ts";

const outsideRootGrants = "process working_dir is outside root_grants";

async function withConnector(body: (start: (params: Record<string, unknown>) => Promise<Exit.Exit<unknown, unknown>>, root: string) => Promise<void>) {
  const root = tempDir();
  mkdirSync(join(root, "allowed", "sub"), { recursive: true });
  mkdirSync(join(root, "other"));
  const c = makeConnector({ root });
  let n = 0;
  const start = (params: Record<string, unknown>) =>
    Effect.runPromiseExit(c.dispatchForTest(`req_start_${n++}`, "process_start", { command: "/bin/sh", args: ["-c", "exec cat"], ...params }));
  try {
    await body(start, root);
  } finally {
    await Effect.runPromise(c.close());
  }
}

const failure = (exit: Exit.Exit<unknown, unknown>) => (Exit.isFailure(exit) ? String(exit.cause) : null);

test("a process starts inside a granted root", () =>
  withConnector(async (start) => {
    const exit = await start({ process_name: "inside", working_dir: "allowed/sub", enforce_root: true, root_grants: ["allowed"] });
    assert.ok(Exit.isSuccess(exit), String(exit));
    assert.equal((exit.value as { status: string }).status, "running");
  }));

test("a process outside its granted roots is refused before it starts", () =>
  withConnector(async (start, root) => {
    for (const working_dir of ["../outside", "other", join(root, "allowed", "..", "other")])
      assert.match(failure(await start({ process_name: "outside", working_dir, enforce_root: true, root_grants: ["allowed"] })) ?? "", new RegExp(outsideRootGrants), working_dir);
    // An empty grant grants nothing.
    assert.match(failure(await start({ process_name: "empty", working_dir: "allowed", root_grants: [" "] })) ?? "", new RegExp(outsideRootGrants));
  }));

test("a link inside a granted root does not lead a process out of it", () =>
  withConnector(async (start, root) => {
    symlinkSync(join(root, "other"), join(root, "allowed", "to-other"));
    assert.match(failure(await start({ process_name: "link", working_dir: "allowed/to-other", root_grants: ["allowed"] })) ?? "", new RegExp(outsideRootGrants));
  }));

test("an enforced root without grants keeps a process inside the connector root", () =>
  withConnector(async (start) => {
    assert.match(failure(await start({ process_name: "escape", working_dir: tempDir(), enforce_root: true })) ?? "", /path escapes station root/);
  }));
