// Ported from systems/connector/salix-connect/device_access_test.go (same test names where the behavior stayed).
// A device's access is the computer's one value (off | read | full), kept by the station (src/device/access.ts) and
// shared by every device connection and the device tools: an access request sets it without asking Main, the old
// 2-level request maps onto it, off refuses even the device's file reads, a station from before takes its device
// connection's access once, and the value survives restarts. A read-only device discovers runtimes without running
// them and refuses writes.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { Effect, Exit } from "effect";
import { SCOPE_LOCAL_FILE_READ, makeConnector } from "../../src/connector/connector.ts";
import { computerAccess } from "../../src/device/access.ts";
import { accessOf } from "../../src/device/tools.ts";
import { ConfigFile } from "../../src/ops/config.ts";
import { platform } from "../../src/platform/index.ts";
import { bind, claim } from "./support/connector.ts";
import { eventually } from "./support/eventually.ts";
import { tempDir } from "./support/temp.ts";

const stationConfig = () => new ConfigFile(tempDir());
const desktop = (config: ConfigFile, scope: string, root = tempDir()) =>
  makeConnector({ root, deviceMode: true, configPath: join(root, "instance.json"), deviceWorkspaceId: "wsp_owned", scope, env: { HOME: tempDir() } }, undefined, { access: computerAccess(config) });

test("TestDesktopDeviceAccessSetsTheComputersOneValue", async () => {
  const config = stationConfig();
  const files = tempDir();
  writeFileSync(join(files, "hello.txt"), "hello", { mode: 0o600 });
  const asked = desktop(config, "", files);
  const other = desktop(config, SCOPE_LOCAL_FILE_READ);
  assert.equal(other.currentScope(), "", "the other connection kept its own file's scope");
  const ask = async (params: Record<string, unknown>) => (await Effect.runPromise(asked.dispatchForTest("a", "device_access", params))) as Record<string, unknown>;

  // Off: no operations and no file reads, on every device connection of the station; access stays manageable.
  assert.deepEqual(await ask({ access: "off", workspaceId: "wsp_other" }), { access: "off", allows_operations: false });
  assert.equal(accessOf(config.raw()), "off", "the device tools do not share the value");
  assert.deepEqual([asked.currentScope(), asked.metadata().capabilities!.access, asked.metadata().capabilities!.scope], [SCOPE_LOCAL_FILE_READ, "off", SCOPE_LOCAL_FILE_READ]);
  await eventually(() => other.currentScope() === SCOPE_LOCAL_FILE_READ, "the other connection following off");
  assert.ok(Exit.isFailure(await Effect.runPromiseExit(asked.dispatchForTest("r", "read", { path: "hello.txt" }))), "off read a file");
  // The 2-level request of before: false keeps an off computer off, true is full, false then is read.
  assert.equal((await ask({ allow_operations: false })).access, "off");
  assert.deepEqual(await ask({ allow_operations: true }), { access: "full", allows_operations: true });
  assert.equal(asked.currentScope(), "");
  await eventually(() => other.currentScope() === "", "the other connection following full");
  assert.deepEqual(await ask({ allow_operations: false }), { access: "read", allows_operations: false });
  assert.ok(Exit.isSuccess(await Effect.runPromiseExit(asked.dispatchForTest("r", "read", { path: "hello.txt" }))), "read refused a file read");
  assert.ok(Exit.isFailure(await Effect.runPromiseExit(asked.dispatchForTest("e", "exec", { command: "true" }))), "read ran a command");
  assert.ok(Exit.isFailure(await Effect.runPromiseExit(asked.dispatchForTest("a", "device_access", { access: "all" }))), "an unknown level was taken");
  assert.equal(accessOf(config.raw()), "read");
  await Promise.all([asked, other].map((c) => Effect.runPromise(c.close())));
});

test("TestStationFromBeforeTakesItsDeviceConnectionsAccessOnce", async () => {
  // The device tools were off (the Stations tab's default); the app's connection is read-only: the computer is read.
  const config = stationConfig();
  config.update((raw) => void (raw.tools = { access: "off" }));
  const first = desktop(config, SCOPE_LOCAL_FILE_READ);
  assert.deepEqual([config.raw().tools, first.currentScope()], [{ access: "read", computer: true }, SCOPE_LOCAL_FILE_READ]);
  // Taken once: another connection's file does not change it.
  const second = desktop(config, "");
  assert.deepEqual([accessOf(config.raw()), second.currentScope()], ["read", SCOPE_LOCAL_FILE_READ]);
  await Promise.all([first, second].map((c) => Effect.runPromise(c.close())));

  // A standalone device's device-access.json from before gives it too.
  const root = tempDir();
  writeFileSync(join(root, "device-access.json"), JSON.stringify({ scope: "" }));
  const standalone = stationConfig();
  const device = makeConnector({ root, deviceMode: true, scope: SCOPE_LOCAL_FILE_READ, env: { HOME: tempDir() } }, undefined, { access: computerAccess(standalone) });
  assert.deepEqual([accessOf(standalone.raw()), device.currentScope()], ["full", ""]);
  await Effect.runPromise(device.close());
});

test("TestDeviceReadOnlyDiscoversWithoutExecutingAndReadsFiles", async () => {
  const home = tempDir();
  const bin = tempDir();
  const marker = join(home, "executed");
  const codex = platform.makeCommand(join(bin, "codex"), `#!/bin/sh\ntouch '${marker}'\n`);
  const root = tempDir();
  writeFileSync(join(root, "hello.txt"), "hello", { mode: 0o600 });
  const c = makeConnector({ root, deviceMode: true, scope: SCOPE_LOCAL_FILE_READ, env: { HOME: home, PATH: bin } });
  const entries = c.metadata().capabilities!.agent_runtimes as Array<Record<string, unknown>>;
  assert.deepEqual(entries.map((entry) => [entry.provider, entry.command, entry.readiness_issue]), [["codex", codex, "permission_required"]]);
  assert.ok(!existsSync(marker), "discovery executed the provider");
  assert.ok(Exit.isSuccess(await Effect.runPromiseExit(c.dispatchForTest("read", "read", { path: "hello.txt" }))));
  for (const method of ["exec", "write", "agent_runtime_input"]) {
    const exit = await Effect.runPromiseExit(c.dispatchForTest("write", method, { path: "hello.txt", content: "changed", command: "touch touched" }));
    assert.ok(Exit.isFailure(exit), `read-only accepted ${method}`);
  }
  assert.equal(readFileSync(join(root, "hello.txt"), "utf8"), "hello", "read-only modified the file");
  await Effect.runPromise(c.close());
});

test("TestStandaloneDeviceAccessSurvivesRestart", async () => {
  const config = stationConfig();
  const cfg = { root: tempDir(), deviceMode: true, scope: SCOPE_LOCAL_FILE_READ, env: { HOME: tempDir() } };
  const start = () => makeConnector(cfg, undefined, { access: computerAccess(config) });
  let c = start();
  await Effect.runPromise(c.deviceAccess({ access: "full" }));
  await Effect.runPromise(c.close());
  c = start();
  assert.equal(c.currentScope(), "", "lost granted permission");
  await Effect.runPromise(c.deviceAccess({ access: "off" }));
  await Effect.runPromise(c.close());
  c = start();
  assert.deepEqual([c.currentScope(), c.metadata().capabilities!.access], [SCOPE_LOCAL_FILE_READ, "off"], "lost revoked permission");
  await Effect.runPromise(c.close());
});

test("TestDeviceConnectionNamesTheComputersOwner", async () => {
  const config = stationConfig();
  const c = desktop(config, "");
  assert.ok(bind(c, claim(c)));
  assert.equal(config.raw().tools.owner, "user_exact");
  await Effect.runPromise(c.close());
});

test("TestRuntimeProbeAnswersSalixReadinessCheck", async () => {
  const home = tempDir();
  const c = makeConnector({ root: tempDir(), deviceMode: true, env: { HOME: home, PATH: tempDir() } });
  assert.equal(c.metadata().capabilities!.runtime_probe, true);
  const probed = await Effect.runPromiseExit(c.dispatchForTest("probe", "runtime_probe", {}));
  assert.ok(Exit.isSuccess(probed), "runtime_probe is not served");
  if (Exit.isSuccess(probed)) assert.deepEqual((probed.value as { runtimes: unknown[] }).runtimes, []);
  const unsupported = await Effect.runPromiseExit(c.dispatchForTest("probe", "runtime_probe", { provider: "gemini", identity_material: "x" }));
  assert.ok(Exit.isFailure(unsupported), "an unknown provider was probed");
});

test("TestRuntimeProbeReportsThePathRuntimeAndItsSignIn", async () => {
  const home = tempDir();
  const bin = tempDir();
  const fake = (path: string, version: string, status: string, code: number) =>
    platform.makeCommand(path, `#!/bin/sh\nif [ "$1" = "--version" ]; then echo '${version}'; exit 0; fi\necho '${status}'\nexit ${code}\n`);
  const claude = fake(join(bin, "claude"), "2.1.276 (Claude Code)", '{"loggedIn":true,"authMethod":"claude.ai"}', 0);
  const codex = fake(join(bin, "codex"), "codex-cli 0.162.1", "Not logged in", 1);
  // Another Claude Code off the PATH, where an installer leaves one: the station never runs it.
  mkdirSync(join(home, ".local", "bin"), { recursive: true });
  fake(join(home, ".local", "bin", "claude"), "1.0.33 (Claude Code)", '{"loggedIn":false}', 1);
  const c = makeConnector({ root: tempDir(), deviceMode: true, env: { HOME: home, PATH: bin } });
  const probed = await Effect.runPromise(c.dispatchForTest("probe", "runtime_probe", {}));
  const runtimes = (probed as { runtimes: Array<Record<string, any>> }).runtimes;
  assert.deepEqual(
    runtimes.map((r) => [r.provider, r.identity_material, r.version, r.ready, r.auth_ready, r.native_server_startable, r.auth.status, r.readiness_issue]),
    [
      ["claude", claude, "2.1.276 (Claude Code)", true, true, true, "authenticated", undefined],
      ["codex", codex, "codex-cli 0.162.1", false, false, true, "unauthenticated", "authentication_required"],
    ],
  );
  await Effect.runPromise(c.close());
});
