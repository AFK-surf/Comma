// exec: a command run by a POSIX shell on every machine (Git's sh on Windows), or by PowerShell when it is asked for.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect, Exit } from "effect";
import { makeConnector } from "../../src/connector/connector.ts";
import { platform } from "../../src/platform/index.ts";
import { tempDir } from "./support/temp.ts";

const exec = async (params: Record<string, unknown>) => {
  const c = makeConnector({ root: tempDir() });
  try {
    return await Effect.runPromiseExit(c.dispatchForTest("req_exec", "exec", params));
  } finally {
    await Effect.runPromise(c.close());
  }
};

test("a command runs under sh unless another shell is asked for", async () => {
  const exit = await exec({ command: 'x=ok; printf "%s" "$x"' });
  assert.ok(Exit.isSuccess(exit), String(exit));
  assert.deepEqual([(exit.value as any).exit_code, (exit.value as any).stdout], [0, "ok"]);
});

test("PowerShell runs a command when asked for, its output UTF-8", { skip: platform.powerShell("", process.env) === null && "no PowerShell here" }, async () => {
  const exit = await exec({ command: '$x = "交大"; Write-Output "$x ok"; exit 3', shell: "powershell" });
  assert.ok(Exit.isSuccess(exit), String(exit));
  assert.deepEqual([(exit.value as any).exit_code, (exit.value as any).stdout.trim()], [3, "交大 ok"]);
});

test("a shell other than sh or powershell is refused", async () => {
  const exit = await exec({ command: "echo x", shell: "cmd" });
  assert.ok(Exit.isFailure(exit));
  assert.match(String(exit.cause), /'shell' is sh or powershell/);
});
