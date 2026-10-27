// The connector as a part of the station: configured from the flags after `--` and the environment (unused without
// a server and a credential, or a config file), the station's databases in a Workload archive, and a Workload's station
// placed in its workspace by Salix.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect, Exit } from "effect";
import { loadKey } from "../../src/cloud/key.ts";
import { readState } from "../../src/cloud/state.ts";
import { makeConnector } from "../../src/connector/connector.ts";
import { connectorConfig, stationIdle, stationPlace } from "../../src/connector/service.ts";
import { Store, newMessage } from "../../src/store/store.ts";
import { tempDir } from "./support/temp.ts";

const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect);

test("the connector is configured from the flags after -- and the environment, and unused without them", async () => {
  assert.equal(await run(connectorConfig(["run", "--app", "/app"], {})), null);
  const cfg = await run(connectorConfig(["run", "--app", "/app", "--", "--server", "https://salix.test", "--name", "laptop"], { SALIX_CONNECTOR_TOKEN: "tok", SALIX_CONNECTOR_ROOT: tempDir() }));
  assert.deepEqual([cfg?.server, cfg?.token, cfg?.name], ["https://salix.test", "tok", "laptop"]);
  const workload = await run(connectorConfig(["run", "--", "--server", "https://salix.test"], { SALIX_WORKLOAD_CREDENTIAL: "connect-credential", SALIX_CONNECTOR_ROOT: tempDir() }));
  assert.equal(workload?.workloadCredential, "connect-credential");
  // The station takes a Workload's credential out of its environment (main.ts): the connector has it, the
  // environment its `exec` commands inherit does not.
  const taken = await run(connectorConfig(["run", "--", "--server", "https://salix.test"], { SALIX_CONNECTOR_ROOT: tempDir() }, "connect-credential"));
  assert.deepEqual([taken?.workloadCredential, taken?.env.SALIX_WORKLOAD_CREDENTIAL], ["connect-credential", undefined]);
});

test("the station's databases travel as snapshots, whole, made while the live ones stay open", async () => {
  const { DatabaseSync } = await import("node:sqlite");
  const { mkdirSync } = await import("node:fs");
  const { join } = await import("node:path");
  const { stationArchiveState } = await import("../../src/connector/service.ts");
  const root = tempDir();
  const data = join(root, ".station");
  mkdirSync(data, { recursive: true });
  const live = new DatabaseSync(join(data, "stillfail.db"));
  live.exec("PRAGMA journal_mode=WAL; CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('kept')");
  const state = stationArchiveState(root, data, () => 1);
  assert.ok(state.live().includes(join(data, "stillfail.db-wal")));
  const snapshots = await state.snapshots();
  assert.deepEqual(snapshots.entries.map((e) => e.name), [".station/stillfail.db"]);
  // The snapshot is a whole database, written while the live one stays open.
  const copy = new DatabaseSync(snapshots.entries[0].file, { readOnly: true });
  assert.deepEqual(copy.prepare("SELECT v FROM t").all().map((r: any) => r.v), ["kept"]);
  copy.close();
  live.close();
  snapshots.done();
});

test("the desktop app's connections run as instances: started, changed or renewed in place, started again and stopped with their files", async () => {
  const { writeFileSync, rmSync } = await import("node:fs");
  const { join } = await import("node:path");
  const { Scope, Exit } = await import("effect");
  const { connectorInstances } = await import("../../src/connector/service.ts");
  const dir = tempDir();
  const root = tempDir();
  const index = tempDir();
  const events: string[] = [];
  const instanceFile = (scope: string, token = "tok", name = "laptop") =>
    JSON.stringify({ connector: { server: "https://salix.test", connector_token: token, name, root, scope }, electron: { local_file_index_root: index } });
  const scope = await Effect.runPromise(Scope.make());
  let started = 0;
  try {
    await Effect.runPromise(
      Scope.provide(scope)(
        connectorInstances(dir, { HOME: tempDir() }, (cfg) =>
          Effect.gen(function* () {
            const n = ++started;
            let current = cfg.scope;
            events.push(`start ${n} ${cfg.token} ${cfg.scope || "full"}`);
            yield* Effect.addFinalizer(() => Effect.sync(() => void events.push(`stop ${n}`)));
            return {
              currentScope: () => current,
              setCurrentScope: (next: string) => Effect.sync(() => void ((current = next), events.push(`scope ${n} ${next || "full"}`))),
              renewCredential: (token: string) => Effect.sync(() => void events.push(`renew ${n} ${token}`)),
              publishCachedMetadata: () => Effect.void,
              writeStatusMetadataSent: () => {},
            } as never;
          }),
        ),
      ),
    );
    const settled = async (count: number) => {
      for (let i = 0; i < 2000 && events.length < count; i++) await new Promise((r) => setImmediate(r));
      for (let i = 0; i < 2000 && events.length < count; i++) await new Promise((r) => setTimeout(r, 5));
      assert.equal(events.length, count, events.join(", "));
    };
    writeFileSync(join(dir, "wsp_1.json"), instanceFile(""));
    await settled(1);
    writeFileSync(join(dir, "wsp_1.json"), instanceFile("local_file_read"));
    await settled(2);
    // The app's renewed credential: the running connection presents it and keeps its requests and processes.
    writeFileSync(join(dir, "wsp_1.json"), instanceFile("local_file_read", "renewed"));
    await settled(3);
    writeFileSync(join(dir, "wsp_1.json"), instanceFile("local_file_read", "renewed", "desk"));
    await settled(5);
    rmSync(join(dir, "wsp_1.json"));
    await settled(6);
    assert.deepEqual(events, ["start 1 tok full", "scope 1 local_file_read", "renew 1 renewed", "stop 1", "start 2 renewed local_file_read", "stop 2"]);
  } finally {
    await Effect.runPromise(Scope.close(scope, Exit.void));
  }
});

test("a desktop device connection's file whose scope alone changed sets the computer's access the 2-level way", async () => {
  const { writeFileSync } = await import("node:fs");
  const { join } = await import("node:path");
  const { Scope, Exit } = await import("effect");
  const { connectorInstances } = await import("../../src/connector/service.ts");
  const dir = tempDir();
  const root = tempDir();
  const asked: unknown[] = [];
  let started = 0;
  // Each start and each access set is the event the test waits for.
  let happened = () => {};
  const next = () => new Promise<void>((resolve) => void (happened = resolve));
  const instanceFile = (scope: string) => JSON.stringify({ connector: { server: "https://salix.test", connector_token: "tok", name: "laptop", root, scope, device: true } });
  const scope = await Effect.runPromise(Scope.make());
  try {
    await Effect.runPromise(
      Scope.provide(scope)(
        connectorInstances(dir, { HOME: tempDir() }, () =>
          Effect.sync(() => void (started++, happened())).pipe(Effect.as({
            // The computer's value is read: the file's scope says nothing until it changes.
            currentScope: () => "local_file_read",
            setCurrentScope: () => Effect.die("a device connection's scope was set from its file"),
            deviceAccess: (params: Record<string, unknown>) => Effect.sync(() => void (asked.push(params), happened())),
            publishCachedMetadata: () => Effect.void,
            writeStatusMetadataSent: () => {},
          } as never)),
        ),
      ),
    );
    const written = async (scope: string) => {
      const event = next();
      writeFileSync(join(dir, "wsp_1.json"), instanceFile(scope));
      await event;
    };
    await written("");
    await written("local_file_read");
    await written("");
    assert.deepEqual([started, asked], [1, [{ allow_operations: false }, { allow_operations: true }]]);
  } finally {
    await Effect.runPromise(Scope.close(scope, Exit.void));
  }
});

test("an instance's connection gets the app's commands first on its PATH and the app's environment", async () => {
  const { writeFileSync } = await import("node:fs");
  const { join } = await import("node:path");
  const { instanceConfig } = await import("../../src/connector/service.ts");
  const dir = tempDir();
  const path = join(dir, "wsp_1.json");
  writeFileSync(
    path,
    JSON.stringify({
      connector: { server: "https://salix.test", connector_token: "tok", root: tempDir() },
      electron: { bin_dir: "/app/bin", env: { COMMA_CLIENT_CONTROL_URL: "http://127.0.0.1:9", SYNCH_DATA_DIR: "/synch" } },
    }),
  );
  const cfg = await run(instanceConfig(path, { PATH: "/usr/bin" }));
  assert.equal(cfg?.env.PATH, "/app/bin:/usr/bin");
  assert.equal(cfg?.env.COMMA_CLIENT_CONTROL_URL, "http://127.0.0.1:9");
  assert.equal(cfg?.env.SYNCH_DATA_DIR, "/synch");
});

test("Salix places its Workload's station in the Group's workspace, as an enrollment would", async () => {
  const data = tempDir();
  const place = stationPlace(data);
  const c = makeConnector({ root: tempDir(), env: { HOME: tempDir() }, workloadCredential: "w" }, undefined, { place });
  const call = (method: string, params: Record<string, unknown> = {}) => Effect.runPromise(c.dispatchForTest(method, method, params)) as Promise<Record<string, any>>;
  const { station } = await call("station_identity");
  assert.equal(station, loadKey(data).id);
  const where = { origin: "https://salix.test", provider: "comma", workspace: "ws_group", workspace_name: "Team", name: "Cloud VM", relay_urls: ["https://relay.test"], grant_keys: [], gateway_keys: ["g1"] };

  const elsewhere = await Effect.runPromiseExit(c.dispatchForTest("p", "station_place", { ...where, station: "f".repeat(64) }));
  assert.ok(Exit.isFailure(elsewhere), "a place for another key was taken");
  assert.equal(readState(data), null);

  assert.deepEqual(await call("station_place", { ...where, station }), { placed: true });
  const state = readState(data)!;
  assert.deepEqual([state.provider, state.origin, state.workspace, state.station, state.relay_url, state.gateway_keys], ["comma", "https://salix.test", "ws_group", station, "https://relay.test", ["g1"]]);
  await Effect.runPromise(c.close());

  // A device's connector joins its workspace by enrolling: Salix does not place it.
  const device = makeConnector({ root: tempDir(), env: { HOME: tempDir() }, token: "device" }, undefined, { place });
  assert.ok(Exit.isFailure(await Effect.runPromiseExit(device.dispatchForTest("i", "station_identity", {}))));
  await Effect.runPromise(device.close());
});

test("a station with a message no turn has taken yet is not idle: Salix may not park it", async () => {
  const store = Store.open(":memory:", null);
  const c = makeConnector({ root: tempDir(), env: { HOME: tempDir() }, workloadCredential: "w" }, undefined, { agentsIdle: () => stationIdle(store) });
  const quiesce = (token: string) => Effect.runPromiseExit(c.dispatchForTest(token, "cloud_runtime_quiesce", { token }));
  store.insertSession({ key: "s", connect: "ds", runtime: "claude", profile: "cc", workspace: "/w/s", token: "s", createdAt: 1, lastActiveAt: 1 });
  const thread = store.openThread("task", "C1", "1.1", null, null);
  store.joinThread(thread.id, "s", "ds");
  const [n] = store.insertMessage(newMessage(thread.id, "1.1", "agent", "router", "run uname -a"));
  store.deliver(thread.id, n, ["s"]);
  assert.ok(Exit.isFailure(await quiesce("t1")), "parked with a message waiting");
  store.markDelivered("s", [[thread.id, n]]);
  assert.ok(Exit.isSuccess(await quiesce("t2")), "not parked once the message was taken");
  await Effect.runPromise(c.close());
  store.close();
});
