// Ported from systems/connector/salix-connect/main_test.go: connector scope, status and containment (same test names;
// the Windows named-pipe case of TestLocalFileReadScopeRequiresRunNonceAndParentLifeline goes with Windows support).
// A `local-file-read` connector (the desktop app's attachment reader) admits only `read_ref`, advertises minimal
// capabilities, never opens runtime state or probes runtimes, and shares its root with other scoped connectors. The
// app widens and narrows the scope in place over its control pipe, with its exact run nonce; narrowing fences an
// admitted process start, aborts pending write streams and does not wait for a user file's close; the status file
// acknowledges a scope only once metadata carrying it was published. A scoped connector exits when its parent's
// lifeline reaches EOF or the parent asks, with the exact run nonce, for a cooperative shutdown.
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { PassThrough, Readable } from "node:stream";
import { test } from "node:test";
import { Deferred, Effect, Exit, Fiber } from "effect";
import { type ConnectorConfig, SCOPE_LOCAL_FILE_READ, SHUTDOWN_REQUEST_POLL_INTERVAL, makeConnector, validateConfig, watchParentLifeline, watchShutdownRequest } from "../../src/connector/connector.ts";
import { settle } from "./support/memory-net.ts";
import { tempDir } from "./support/temp.ts";

const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect);

/** A connector as the desktop app starts it for attachments: read-only scope, run nonce, lifeline and shutdown file. */
function scopedConnector(runNonce: string, cfg: Partial<ConnectorConfig> = {}) {
  return makeConnector({
    name: "comma-desktop",
    parentLifelineFd: 3,
    root: tempDir(),
    runNonce,
    shutdownRequestPath: join(tempDir(), "shutdown-request.json"),
    localFileIndexRoot: tempDir(),
    scope: SCOPE_LOCAL_FILE_READ,
    ...cfg,
  });
}

const dispatchError = async (c: ReturnType<typeof makeConnector>, method: string, params: Record<string, unknown> = {}) => {
  const exit = await Effect.runPromiseExit(c.dispatchForTest("req_scope", method, params));
  return Exit.isFailure(exit) ? String(exit.cause) : null;
};

test("TestConnectorStatusAdvertisesLocalFileIndexVersion", async () => {
  const statusPath = join(tempDir(), "connector.status.json");
  const c = makeConnector({ statusPath, root: tempDir() });
  const session = c.claimConnection(() => Effect.void);
  assert.ok(c.setIdentity(session, "run_v2_status", "dev_v2_status", "connector_v2_status", "user_v2_status", 17), "the test connection identity was not bound");
  c.writeStatus("connected", "wss://salix.example.test", null);
  const status = JSON.parse(readFileSync(statusPath, "utf8"));
  assert.deepEqual([status.state, status.local_file_index_version, status.connector_run_id, status.device_id], ["connected", 2, "run_v2_status", "dev_v2_status"]);
  session.close("canceled");
  await run(c.close());
});

test("TestMetadataAdvertisesLocalFileIndexVersion", async () => {
  const c = makeConnector({ name: "local-file-reader", root: tempDir(), localFileIndexRoot: tempDir() });
  const capabilities = c.metadata().capabilities!;
  assert.ok("scope" in capabilities && capabilities.scope === "", "full metadata must carry an explicit empty scope");
  assert.deepEqual([capabilities.local_file_import_v1, capabilities.local_file_index_version], [true, 2]);
  await run(c.close());
});

test("TestLocalFileReadScopeRefusesEveryMethodExceptReadRef", async () => {
  const c = scopedConnector("0123456789abcdef0123456789abcdef", { name: "attachment-reader" });
  for (const method of [
    "exec", "read", "write", "delete", "stat", "list", "glob", "grep", "computer_use", "read_stream", "write_stream", "process_start", "process_list",
    "process_write", "process_tail", "process_stop", "http_request", "agent_runtime_input", "runtime_probe", "meeting_join", "meeting_send_chat", "meeting_artifact_read",
  ]) {
    assert.match((await dispatchError(c, method)) ?? "", /not permitted/, `method ${method} was not refused by the scope`);
  }
  // read_ref passes the scope and fails on its own parameter validation.
  const readRef = await dispatchError(c, "read_ref");
  assert.ok(readRef && !readRef.includes("not permitted"), `read_ref: ${readRef}`);
  await run(c.close());
});

test("TestScopedConnectorNeverProbesAgentRuntimes", async () => {
  const c = scopedConnector("33333333333333333333333333333333", { name: "attachment-reader" });
  let probes = 0;
  c.runtimeInventory.setProbeForTest(() => (probes++, {}));
  const sent: Array<Record<string, any>> = [];
  await run(c.probeAndPublish("connect", (m) => Effect.sync(() => void sent.push(m))));
  // Probing can start runtime processes (a Codex app-server); a read_ref-only connector publishes its metadata as is.
  assert.equal(probes, 0, `a scoped connector probed ${probes} runtime targets`);
  assert.equal(sent.length, 1);
  assert.deepEqual([sent[0].type, sent[0].capabilities?.scope], ["metadata", SCOPE_LOCAL_FILE_READ]);
  await run(c.close());
});

test("TestLocalFileReadScopeAdvertisesMinimalCapabilities", async () => {
  const c = scopedConnector("44444444444444444444444444444444", { name: "attachment-reader" });
  const capabilities = c.metadata().capabilities!;
  assert.deepEqual([capabilities.scope, capabilities.local_file_import_v1, capabilities.local_file_index_version], [SCOPE_LOCAL_FILE_READ, true, 2]);
  for (const forbidden of ["persistent_processes", "computer_use_tool", "runtime_probe", "meeting_runtime"]) assert.equal(capabilities[forbidden], false, forbidden);
  assert.ok(!("agent_runtimes" in capabilities), "a scoped connector advertised agent_runtimes");
  assert.equal(capabilities.execution_boundary, "local-file-read-only");
  await run(c.close());
});

test("TestCommaDesktopScopeChangesInPlaceWithoutProbingRuntimes", async () => {
  const c = scopedConnector("55555555555555555555555555555555");
  assert.equal(c.currentScope(), SCOPE_LOCAL_FILE_READ);
  await run(c.setCurrentScope(""));
  assert.equal(c.currentScope(), "");
  const capabilities = c.metadata().capabilities!;
  assert.deepEqual([capabilities.persistent_processes, capabilities.runtime_probe], [true, false]);
  assert.ok(!("agent_runtimes" in capabilities), "a widened desktop connector advertised agent runtimes");
  assert.equal(await dispatchError(c, "process_list"), null, "full scope refused process_list");
  await run(c.setCurrentScope(SCOPE_LOCAL_FILE_READ));
  assert.match((await dispatchError(c, "process_list")) ?? "", /not permitted/);
  await run(c.close());
});

test("TestScopeControlRequiresExactRunNonceAndPublishesMetadata", async () => {
  const nonce = "66666666666666666666666666666666";
  const c = scopedConnector(nonce);
  const sent: Array<Record<string, any>> = [];
  const session = c.claimConnection((m) => Effect.sync(() => void sent.push(m)));
  const commands = [
    { type: "set_scope", run_nonce: "wrong", scope: "" },
    { type: "set_scope", run_nonce: nonce },
    { type: "set_scope", run_nonce: nonce, scope: "" },
  ];
  await run(c.watchScopeControl(Readable.from(commands.map((command) => `${JSON.stringify(command)}\n`))));
  assert.equal(c.currentScope(), "", "the exact-nonce command did not widen the scope");
  assert.equal(sent.length, 1, `published ${JSON.stringify(sent)}; want one metadata replacement`);
  assert.equal(sent[0].type, "metadata");
  session.close("canceled");
  await run(c.close());
});

test("TestScopeDowngradeFencesAnAlreadyAdmittedProcessStart", () =>
  run(
    Effect.gen(function* () {
      const c = scopedConnector("88888888888888888888888888888888");
      yield* c.setCurrentScope("");
      const insideFence = yield* Deferred.make<void>();
      const releaseFence = yield* Deferred.make<void>();
      c.setHooksForTest({ beforeManagedProcessStart: Deferred.succeed(insideFence, undefined).pipe(Effect.andThen(Deferred.await(releaseFence))) });
      const marker = join(tempDir(), "escaped");
      const start = yield* Effect.forkChild(Effect.exit(c.dispatchForTest("req_start_race", "process_start", { process_name: "race", command: "/bin/sh", args: ["-c", `touch '${marker}'`] })));
      yield* Deferred.await(insideFence);
      const downgrade = yield* Effect.forkChild(c.setCurrentScope(SCOPE_LOCAL_FILE_READ));
      yield* settle;
      assert.equal(c.currentScope(), SCOPE_LOCAL_FILE_READ);
      assert.equal(downgrade.pollUnsafe(), undefined, "the downgrade was acknowledged before the admitted process fence drained");
      yield* Deferred.succeed(releaseFence, undefined);
      assert.ok(Exit.isFailure(yield* Fiber.join(start)), "an admitted process start succeeded across the downgrade");
      yield* Fiber.join(downgrade);
      assert.ok(!existsSync(marker), "a process escaped the restricted transition");
      assert.ok(!c.processRunningForTest("race"), "a running process survived the restricted acknowledgement");
      yield* c.close();
    }),
  ));

test("TestScopeDowngradeAbortsPendingWriteStreamAndRejectsLaterFrames", () =>
  run(
    Effect.gen(function* () {
      const c = scopedConnector("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
      yield* c.setCurrentScope("");
      const terminal = yield* Deferred.make<Record<string, any>>();
      const session = c.claimConnection((frame) => (frame.id === "write-after-downgrade" && frame.type === "stream" ? Deferred.succeed(terminal, frame).pipe(Effect.asVoid) : Effect.void));
      yield* c.dispatchSession(session, "write-after-downgrade", "write_stream", { path: "bounded.txt" });
      assert.ok(session.pendingWrite("write-after-downgrade"), "the write_stream was not reserved");
      yield* c.setCurrentScope(SCOPE_LOCAL_FILE_READ);
      yield* session.handleStream({ id: "write-after-downgrade", type: "stream", stream: { channel: "data", data: Buffer.from("must-not-land").toString("base64"), eof: true, seq: 1 } });
      assert.equal(session.pendingWrite("write-after-downgrade"), null, "the restricted transition kept the pending write_stream");
      const frame = yield* Deferred.await(terminal);
      assert.ok(frame.stream?.channel === "done" && frame.stream?.eof && String(frame.error).includes("scope restricted"), `scope cancellation frame ${JSON.stringify(frame)}`);
      assert.equal(readFileSync(join(c.root(), "bounded.txt"), "utf8"), "", "a restricted stream frame altered the file");
      session.close("canceled");
      yield* c.close();
    }),
  ));

test("TestScopeDowngradeDoesNotWaitForUserFileClose", () =>
  run(
    Effect.gen(function* () {
      const c = scopedConnector("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      yield* c.setCurrentScope("");
      const session = c.claimConnection(() => Effect.void);
      const closeStarted = yield* Deferred.make<void>();
      const releaseClose = yield* Deferred.make<void>();
      // A user file whose close never returns until released.
      const file = { write: () => Effect.void, close: Deferred.succeed(closeStarted, undefined).pipe(Effect.andThen(Deferred.await(releaseClose))) };
      const pending = session.reservePendingWrite("blocking-close");
      assert.ok(session.activatePendingWrite("blocking-close", pending, file), "the pending write was not activated");
      yield* c.setCurrentScope(SCOPE_LOCAL_FILE_READ);
      // The downgrade returned; the file's cleanup goes on asynchronously.
      yield* Deferred.await(closeStarted);
      yield* Deferred.succeed(releaseClose, undefined);
      session.close("canceled");
      yield* c.close();
    }),
  ));

test("TestScopeStatusAcknowledgesOnlyAfterMetadataPublishAndPeriodicRetry", async () => {
  const nonce = "99999999999999999999999999999999";
  const statusPath = join(tempDir(), "connector.status.json");
  const c = scopedConnector(nonce, { statusPath });
  const scope = () => JSON.parse(readFileSync(statusPath, "utf8")).scope;
  c.writeStatus("connected", "", null);
  const session = c.claimConnection(() => Effect.fail(new Error("transport blocked")));
  await run(c.watchScopeControl(Readable.from([`${JSON.stringify({ type: "set_scope", run_nonce: nonce, scope: "" })}\n`])));
  assert.equal(scope(), SCOPE_LOCAL_FILE_READ, "the scope acknowledgement advanced after a failed publish");
  // Unrelated request status does not acknowledge the unpublished scope.
  c.writeStatusLocalRequestError(new Error("request failed while scope publish is pending"));
  assert.equal(scope(), SCOPE_LOCAL_FILE_READ, "a request error advanced the unpublished scope acknowledgement");
  await run(c.publishPeriodicSystemInfo(() => Effect.void));
  c.writeStatusMetadataSent("");
  assert.equal(scope(), "", "the periodic retry did not acknowledge the full scope");
  session.close("canceled");
  await run(c.close());
});

test("TestConnectURLCarriesCurrentScopeIncludingFull", async () => {
  const c = scopedConnector("77777777777777777777777777777777");
  assert.equal(new URL(c.connectUrl("https://salix.test")).searchParams.get("scope"), SCOPE_LOCAL_FILE_READ);
  await run(c.setCurrentScope(""));
  assert.deepEqual(new URL(c.connectUrl("https://salix.test")).searchParams.getAll("scope"), [""], "the full scope must be an explicit empty value");
  await run(c.close());
});

test("TestLocalFileReadScopeRequiresRunNonceAndParentLifeline", () => {
  const base: Partial<ConnectorConfig> = { localFileIndexRoot: tempDir(), scope: SCOPE_LOCAL_FILE_READ };
  assert.throws(() => validateConfig(base), /run nonce/);
  base.runNonce = "0123456789abcdef0123456789abcdef";
  assert.throws(() => validateConfig(base), /parent lifeline/);
  base.parentLifelineFd = 3;
  assert.throws(() => validateConfig(base), /shutdown request/);
  base.shutdownRequestPath = join(tempDir(), "shutdown-request.json");
  validateConfig(base);
});

test("TestParentLifelineCancelsConnectorContextOnEOF", () =>
  run(
    Effect.gen(function* () {
      const lifeline = new PassThrough();
      const watcher = yield* Effect.forkChild(watchParentLifeline(lifeline));
      lifeline.write("still-alive");
      yield* settle;
      assert.equal(watcher.pollUnsafe(), undefined, "a lifeline payload ended the connector before EOF");
      lifeline.end();
      yield* Fiber.join(watcher);
    }),
  ));

test("TestCooperativeShutdownRequiresExactRunNonce", () =>
  run(
    Effect.gen(function* () {
      const c = makeConnector({ root: tempDir(), testClock: true });
      const requestPath = join(tempDir(), "shutdown-request.json");
      const runNonce = "0123456789abcdef0123456789abcdef";
      const watcher = yield* Effect.forkChild(c.provideClockForTest(watchShutdownRequest(requestPath, runNonce)));
      writeFileSync(requestPath, JSON.stringify({ runNonce: "ffffffffffffffffffffffffffffffff" }), { mode: 0o600 });
      for (let tick = 0; tick < 3; tick++) {
        yield* settle;
        yield* c.advanceClockForTest(SHUTDOWN_REQUEST_POLL_INTERVAL);
      }
      yield* settle;
      assert.equal(watcher.pollUnsafe(), undefined, "a shutdown request for another run ended this connector");
      writeFileSync(requestPath, JSON.stringify({ runNonce }), { mode: 0o600 });
      yield* c.advanceClockForTest(SHUTDOWN_REQUEST_POLL_INTERVAL);
      yield* Fiber.join(watcher);
    }),
  ));
