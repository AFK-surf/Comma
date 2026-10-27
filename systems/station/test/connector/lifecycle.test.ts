// A Workload's station is parked before Salix archives or stops it: quiesce holds only while nothing is busy, under
// one token and for a bounded time; while parked every other request is refused; resume ends it and release makes it
// final. A device's station has no managed lifecycle.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Duration, Effect, Exit } from "effect";
import { makeConnector } from "../../src/connector/connector.ts";
import { tempDir } from "./support/temp.ts";

const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect);
const fails = async (effect: Effect.Effect<unknown, unknown>, pattern: RegExp) => {
  const exit = await Effect.runPromiseExit(effect);
  assert.ok(Exit.isFailure(exit) && pattern.test(String(exit.cause)), String(exit));
};

test("a Workload's station parks, refuses work while parked, resumes and releases", async () => {
  let idle = true;
  const c = makeConnector({ root: tempDir(), env: { HOME: tempDir() }, workloadCredential: "bootstrap", testClock: true }, undefined, { agentsIdle: () => idle });
  const call = (method: string, params: Record<string, unknown> = {}) => c.dispatchForTest(method, method, params);

  idle = false;
  await fails(call("cloud_runtime_quiesce", { token: "t1" }), /runtime is not quiet/);
  idle = true;
  assert.deepEqual(await run(call("cloud_runtime_quiesce", { token: "t1" })), { quiet: true, continued: false });
  await fails(call("process_list"), /cloud runtime is idle/);
  await fails(call("cloud_runtime_quiesce", { token: "t2" }), /runtime is not quiet/);
  assert.deepEqual(await run(call("cloud_runtime_quiesce", { token: "t1" })), { quiet: true, continued: true });
  assert.deepEqual(await run(call("cloud_runtime_resume", { token: "t1" })), { resumed: true });
  assert.ok(Exit.isSuccess(await Effect.runPromiseExit(call("process_list"))));

  // A park runs out by itself.
  await run(call("cloud_runtime_quiesce", { token: "t3", timeout_ms: 1000 }));
  await run(c.advanceClockForTest(Duration.seconds(2)));
  assert.ok(Exit.isSuccess(await Effect.runPromiseExit(call("process_list"))), "an expired park still refused work");

  // Released: final.
  await run(call("cloud_runtime_quiesce", { token: "t4" }));
  assert.deepEqual(await run(call("cloud_runtime_release", { token: "t4" })), { released: true });
  await run(c.advanceClockForTest(Duration.hours(2)));
  await fails(call("process_list"), /cloud runtime is idle/);
  await fails(call("cloud_runtime_resume", { token: "t4" }), /runtime is not quiet/);
  assert.deepEqual(await run(call("cloud_runtime_quiesce", { token: "t5" })), { quiet: true, continued: false });
  await run(c.close());
});

test("a device's station has no managed lifecycle", async () => {
  const c = makeConnector({ root: tempDir(), env: { HOME: tempDir() } });
  await fails(c.dispatchForTest("q", "cloud_runtime_quiesce", { token: "t" }), /not a managed runtime connector/);
  await run(c.close());
});

test("a Workload's station and a desktop app's connection take the profiles Salix lends; another device's takes none", async () => {
  const received: unknown[] = [];
  const profiles = { received: (p: unknown) => void received.push(p), attach: () => {} };
  const c = makeConnector({ root: tempDir(), env: { HOME: tempDir() }, workloadCredential: "bootstrap", testClock: true }, undefined, { profiles });
  assert.deepEqual(await run(c.dispatchForTest("p", "station_profiles", { profiles: [{ id: "sh-0123456789" }] })), { received: true });
  assert.deepEqual(received, [[{ id: "sh-0123456789" }]]);
  await run(c.close());
  const device = makeConnector({ root: tempDir(), env: { HOME: tempDir() } }, undefined, { profiles });
  await fails(device.dispatchForTest("p", "station_profiles", { profiles: [] }), /not a managed runtime connector/);
  await run(device.close());
  // A desktop instance: its Workspace's accounts, an empty list included.
  const desktop = makeConnector({ root: tempDir(), env: { HOME: tempDir() } }, undefined, { profiles: { ...profiles, device: true } });
  assert.deepEqual(await run(desktop.dispatchForTest("p", "station_profiles", { profiles: [] })), { received: true });
  assert.deepEqual(received.at(-1), []);
  await run(desktop.close());
});
