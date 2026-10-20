// The connector as a part of the station: configured like the Go connector (its flags after `--` on the station's
// command line, its environment, the desktop app's config file), it connects out to Salix for as long as the station
// runs, with a device's token or a Compute Workload's credential. Salix's Tasks have the station's Sessions take part
// through it (src/tasks/tasks.ts). Without a server and a credential, or a config file, the station runs without it.
import { type FSWatcher, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, watch } from "node:fs";
import { tmpdir } from "node:os";
import { DatabaseSync } from "node:sqlite";
import { join } from "node:path";
import { Duration, Effect, Exit, Layer, Queue, Scope } from "effect";
import { log } from "../ops/log.ts";
import { Agents } from "../sessions/agents.ts";
import { SalixRelay } from "../mesh/salix-relay.ts";
import { Paths, Store } from "../services.ts";
import type { Store as StationStore } from "../store/store.ts";
import { placedState } from "../cli.ts";
import { loadKey } from "../cloud/key.ts";
import { readState, writeState } from "../cloud/state.ts";
import { version } from "../ops/version.ts";
import { type ConnectorConfig, applyConfigFile, normalizeConfig, parseArgs, validateConfig } from "./config.ts";
import { type StationProfiles, makeConnector } from "./connector.ts";
import { type ArchiveState, archiveName } from "./durable-archive.ts";
import type { StationTaskIndex } from "./task-index.ts";
import { runtimeDir } from "../ops/files.ts";
import { computerAccess } from "../device/access.ts";

/** The host the profiles Salix lends are borrowed from, and the Station its Tasks are kept on (an instance's Salix is
 * `salix:<id>`). */
export const SALIX_HOST = "salix";

/** The connector's configuration from the station's arguments after `--` and the environment; null when unused. */
export function connectorConfig(argv: string[], env: Record<string, string | undefined>): Effect.Effect<ConnectorConfig | null, Error> {
  return Effect.gen(function* () {
    const at = argv.indexOf("--");
    const flags = at < 0 ? [] : argv.slice(at + 1);
    const { cfg, explicit } = yield* Effect.try({ try: () => parseArgs(flags, env), catch: (e) => e as Error });
    if (!cfg.configPath && !(cfg.server && (cfg.token || cfg.workloadCredential))) return null;
    if (cfg.configPath) yield* applyConfigFile(cfg, explicit);
    normalizeConfig(cfg);
    validateConfig(cfg);
    return cfg;
  });
}

/** Whether the station's agents are idle, as it tells Salix: no Session runs a turn, and none has messages waiting. */
export function stationIdle(store: Pick<StationStore, "listSessions" | "sessionsWithPending">): boolean {
  return !store.listSessions().some((s) => s.running) && store.sessionsWithPending().length === 0;
}

/**
 * Where Salix, the control plane, placed this Workload's station: its key's id, and cloud.json written from the place
 * (the running station follows the file: cloud/state.ts). A place for another key is refused.
 */
export function stationPlace(data: string) {
  return {
    identity: () => ({ station: loadKey(data).id, version: version() }),
    placed: (place: Record<string, unknown>) => {
      const id = loadKey(data).id;
      if (place.station !== id) throw new Error("the place names another station");
      if (typeof place.origin !== "string" || !place.origin || typeof place.workspace !== "string" || !place.workspace) throw new Error("the place names no workspace");
      const next = placedState(place.origin, id, place, "comma");
      const now = readState(data);
      if (now && now.origin === next.origin && now.workspace === next.workspace && now.station === id && !now.removed_at) return;
      writeState(data, next);
      log.info("connector", "placed in its workspace by Salix", { workspace: next.workspace, station: id.slice(0, 12) });
    },
  };
}

/** The desktop app's connections, one per signed-in Workspace: a desktop config file each, named `<id>.json`. */
export const INSTANCES_DIR = join("connector", "instances");
const INSTANCE_ID = /^[A-Za-z0-9_-]{1,128}$/;
const INSTANCE_RESCAN = Duration.seconds(2);

/** An instance's configuration from its file; null when the file is gone or unusable (logged). */
export function instanceConfig(path: string, env: Record<string, string | undefined>): Effect.Effect<ConnectorConfig | null> {
  return Effect.gen(function* () {
    const { cfg, explicit } = parseArgs([], env);
    cfg.configPath = path;
    yield* applyConfigFile(cfg, explicit);
    normalizeConfig(cfg);
    // The app owns an instance by its file: no lifeline, nonce or shutdown file (validateConfig's) applies.
    return cfg.server && cfg.token ? cfg : null;
  }).pipe(
    Effect.catch((error: Error) =>
      Effect.sync(() => {
        log.warn("connector", "an instance's config is unusable", { path, error: error.message });
        return null;
      }),
    ),
  );
}

/**
 * The station's Task index as each of its connections sends it to its Salix. A tombstone goes once every Salix it was
 * sent to holds it: the least of what each connection's Salix holds.
 */
export function stationTaskIndex(store: StationStore): (host: string) => StationTaskIndex {
  const held = new Map<string, number>();
  return (host) => ({
    epoch: () => store.taskIndexEpoch(),
    rev: () => store.taskIndexRev(),
    since: (since, limit) => store.taskIndexSince(since, limit),
    prune: (through) => {
      held.set(host, through);
      store.pruneTaskIndexTombstones(Math.min(...held.values()));
    },
    listen: (changed) => store.subscribe(() => changed()),
  });
}

export const ConnectorLive = (argv: string[]) =>
  Layer.effectDiscard(
    Effect.gen(function* () {
      const { data } = yield* Paths;
      const store = yield* Store;
      const agents = yield* Agents;
      const relay = yield* SalixRelay;
      mkdirSync(join(data, "connector"), { recursive: true, mode: 0o700 });
      // The computer's one access value, which every device connection of the station follows.
      const access = computerAccess(agents.config);
      const index = stationTaskIndex(store);
      /** One connector to Salix, the Station `host` here, running until `scope` closes. */
      const start = (cfg: ConnectorConfig, host: string, profiles?: StationProfiles) =>
        Effect.gen(function* () {
          const tasks = {
            handle: (method: string, params: Record<string, unknown>) => agents.tasks.handle(host, { ...params, method }),
            models: () => agents.tasks.models(),
            listen: (changed: () => void) => agents.config.listen(changed),
            attach: (ask: ((request: Record<string, unknown>) => Promise<unknown>) | null) => agents.tasks.attachHost(host, ask),
          };
          yield* Effect.addFinalizer(() => Effect.sync(() => agents.tasks.attachHost(host, null)));
          const connector = yield* Effect.acquireRelease(
            Effect.sync(() =>
              makeConnector(cfg, undefined, {
                tasks,
                agentsIdle: () => stationIdle(store),
                archive: stationArchiveState(cfg.root, data, () => store.listSessions().length),
                relay,
                profiles,
                place: profiles ? stationPlace(data) : undefined,
                access,
                index: index(host),
              }),
            ),
            (c) => c.close().pipe(Effect.andThen(c.shutdownComputerUseDaemon)),
          );
          yield* Effect.forkScoped(
            connector.runRemote.pipe(Effect.catch((error: Error) => Effect.sync(() => log.error("connector", "the connection to Salix ended", { server: cfg.server, error: error.message })))),
          );
          log.info("connector", "connecting to Salix", { server: cfg.server, name: cfg.name });
          return connector;
        });

      // The station's own connection, from its arguments (a VM, a Workload, a headless machine).
      const cfg = yield* connectorConfig(argv, process.env as Record<string, string | undefined>);
      // A Workload's station uses the workspace's accounts Salix lends, as another station's shares.
      if (cfg !== null)
        yield* start(cfg, SALIX_HOST, {
          received: (profiles) => agents.sharing.hostProfiles(SALIX_HOST, profiles),
          attach: (ask) => agents.sharing.attachHost(SALIX_HOST, ask),
        });

      // The desktop app's: an instance per file, started, changed and stopped as the files are. Its station runs what
      // the machine is signed in to, as no workspace lends a device accounts.
      yield* connectorInstances(join(data, INSTANCES_DIR), process.env as Record<string, string | undefined>, (next, id) =>
        Effect.sync(() => agents.accounts.useMachineLogins()).pipe(
          // While it runs, the station is in a workspace: its Sessions' turns go on.
          Effect.andThen(Effect.acquireRelease(Effect.sync(() => agents.joined()), (leave) => Effect.sync(leave))),
          Effect.andThen(start(next, `${SALIX_HOST}:${id}`)),
        ),
      );
    }),
  );

/** What an instance runner needs of a connector: its scope or a device's access, changed in place, and the metadata that says so. */
export type InstanceConnector = Pick<Connector, "currentScope" | "setCurrentScope" | "deviceAccess" | "publishCachedMetadata" | "writeStatusMetadataSent">;

/**
 * Runs a connector for each `<id>.json` in `dir` (until the caller's scope closes): started when its file appears,
 * changed in place when only its scope changed, started again when anything else did, stopped when it goes. A device
 * connection's file whose scope alone changed is the app setting the computer's access the 2-level way (scope "" is
 * full, local_file_read is read): every device connection then follows it. Its scope otherwise says nothing once the
 * computer has a value.
 */
export function connectorInstances(
  dir: string,
  env: Record<string, string | undefined>,
  start: (cfg: ConnectorConfig, id: string) => Effect.Effect<InstanceConnector, never, Scope.Scope>,
): Effect.Effect<void, never, Scope.Scope> {
  return Effect.gen(function* () {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const running = new Map<string, { raw: string; cfg: ConnectorConfig; scope: Scope.Closeable; connector: InstanceConnector }>();
    const stop = (id: string) =>
      Effect.gen(function* () {
        const instance = running.get(id);
        if (!instance) return;
        running.delete(id);
        yield* Scope.close(instance.scope, Exit.void);
        log.info("connector", "an instance stopped", { id });
      });
    const reconcile = Effect.gen(function* () {
      const files = new Map<string, string>();
      for (const name of readdirSync(dir)) {
        const id = name.endsWith(".json") ? name.slice(0, -".json".length) : "";
        if (!INSTANCE_ID.test(id)) continue;
        try {
          files.set(id, readFileSync(join(dir, name), "utf8"));
        } catch {}
      }
      for (const id of [...running.keys()]) if (!files.has(id)) yield* stop(id);
      for (const [id, raw] of files) {
        const current = running.get(id);
        if (current?.raw === raw) continue;
        const next = yield* instanceConfig(join(dir, `${id}.json`), env);
        if (next === null) {
          yield* stop(id);
          continue;
        }
        // Only the access changed: the running connection changes its scope in place, as the app's switch did.
        if (current && sameButScope(current.cfg, next)) {
          current.raw = raw;
          if (next.deviceMode && current.cfg.scope !== next.scope) {
            yield* current.connector.deviceAccess({ allow_operations: next.scope === "" }).pipe(
              Effect.tap(() => Effect.sync(() => current.connector.writeStatusMetadataSent(""))),
              Effect.catch((error: Error) => Effect.sync(() => log.warn("connector", "an instance's access did not change", { id, error: error.message }))),
            );
          } else if (!next.deviceMode && current.connector.currentScope() !== next.scope) {
            yield* current.connector.setCurrentScope(next.scope).pipe(
              Effect.andThen(Effect.exit(current.connector.publishCachedMetadata())),
              Effect.tap(() => Effect.sync(() => current.connector.writeStatusMetadataSent(""))),
              Effect.catch((error: Error) => Effect.sync(() => log.warn("connector", "an instance's scope did not change", { id, error: error.message }))),
            );
          }
          current.cfg = next;
          continue;
        }
        yield* stop(id);
        const scope = yield* Scope.make();
        const connector = yield* start(next, id).pipe(Scope.provide(scope));
        running.set(id, { raw, cfg: next, scope, connector });
      }
    });
    const watcher = yield* Effect.acquireRelease(
      Effect.sync(() => {
        const wake = Effect.runSync(Queue.sliding<void>(1));
        let watching: FSWatcher | null = null;
        try {
          watching = watch(dir, () => void Queue.offerUnsafe(wake, undefined));
        } catch {}
        return { wake, watching };
      }),
      ({ watching }) => Effect.sync(() => watching?.close()),
    );
    yield* Effect.forkScoped(
      Effect.forever(
        reconcile.pipe(
          Effect.catch((error: unknown) => Effect.sync(() => log.warn("connector", "the instances were not read", { error: String(error) }))),
          Effect.andThen(Effect.raceFirst(Queue.take(watcher.wake), Effect.sleep(INSTANCE_RESCAN))),
        ),
      ),
    );
    yield* Effect.addFinalizer(() => Effect.forEach([...running.keys()], stop, { discard: true }));
  });
}

/** Two configurations that differ in their scope alone. */
function sameButScope(a: ConnectorConfig, b: ConnectorConfig): boolean {
  const strip = (cfg: ConnectorConfig) => JSON.stringify({ ...cfg, scope: "", env: undefined, systemInfoInterval: undefined, workspaceArchiveIdle: undefined, workspaceArchiveRestoreTimeout: undefined });
  return strip(a) === strip(b);
}

type Connector = ReturnType<typeof makeConnector>;

/**
 * Each runtime home's `.tmp`: what the runtime keeps there it makes again (Codex's plugin marketplace cache, about
 * 100 MB per home, from before the station turned that feature off), so it does not travel in an archive.
 */
function homeTemps(data: string): string[] {
  const homes = join(data, "homes");
  return existsSync(homes) ? readdirSync(homes).map((home) => join(homes, home, ".tmp")) : [];
}

/** The station's databases, relative to its data directory: never archived live, snapshotted instead. */
const DATABASES = ["stillfail.db"];

/**
 * The station's own state in a Workload archive (its data directory must lie under the root to travel): the
 * databases leave out their live files and travel as snapshots in their places, and its runtime state (ops/files.ts
 * `runtimeDir`) and its runtime homes' `.tmp` do not travel. A restore unpacks the snapshots there before the station starts
 * (connector/durable-archive.ts `restoreBeforeStart`).
 */
export function stationArchiveState(root: string, data: string, sessions: () => number): ArchiveState {
  const inRoot = (path: string) => archiveName(root, path);
  return {
    live: () => DATABASES.flatMap((db) => ["", "-wal", "-shm"].map((suffix) => join(data, db + suffix))),
    runtime: () => [runtimeDir(data), ...homeTemps(data)],
    snapshots: async () => {
      const dir = mkdtempSync(join(tmpdir(), "station-snapshot-"));
      const entries: Array<{ name: string; file: string }> = [];
      for (const db of DATABASES) {
        const source = join(data, db);
        const name = inRoot(source);
        if (name === null || !existsSync(source)) continue;
        const file = join(dir, db.replaceAll("/", "_"));
        const handle = new DatabaseSync(source, { readOnly: true });
        try {
          handle.exec(`VACUUM INTO '${file.replaceAll("'", "''")}'`);
        } finally {
          handle.close();
        }
        entries.push({ name, file });
      }
      return { entries, done: () => rmSync(dir, { recursive: true, force: true }) };
    },
    sessions,
  };
}
