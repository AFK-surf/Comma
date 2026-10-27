// The connector: the composition root of the station's Salix-facing half. It owns the connection generation, request
// admission, the method table and the subsystems (files, processes, runtimes, archives, ...). Everything it runs is
// on its clock (live, or a TestClock with `testClock: true`).
import { randomBytes, timingSafeEqual } from "node:crypto";
import { readFileSync } from "node:fs";

import { join as joinPath } from "node:path";
import { readFile as readFileAsync } from "node:fs/promises";
import { Cause, Deferred, Duration, Effect, Exit, Fiber, Layer, Option, Queue, Scope, Semaphore } from "effect";
import { type ConnectorClock, liveClock, testClock } from "./clock.ts";
import { type ArchiveState, archiveStateDir, makeDurableArchive, signedStorageUrl } from "./durable-archive.ts";
import { type DaemonResponse, makeComputerUse } from "./computer-use.ts";
import { MeetHttp, liveMeetHttp, makeMeeting, meetingArtifactRequestTimeoutMs } from "./meeting.ts";
import { type FsMethods, MAX_OUTPUT_BYTES, makeFsMethods, resolvePath } from "./fs-methods.ts";
import { type Closer, toCloser } from "./io.ts";
import { type Message, encodeMessage, intParam, stringParam } from "./message.ts";
import { type ProcessStdin, ManagedProcess, execEnv, makeProcessTable, processStartEnv, signalGroup, spawnManaged } from "./processes.ts";
import { type RequestBinding, makeRequestOperations, recoverableRequest, requestFingerprint } from "./request-operations.ts";
import { Session, type SessionHost, type SessionOptions } from "./session.ts";
import { type Sockets, liveSockets } from "./sockets.ts";
import { Net, liveNet } from "./net.ts";
import { httpRequest, lanHttpRequest, udpRequest } from "./lan-gateway.ts";
import { type ConnectorConfig, MAX_CONCURRENT_REQUESTS, REQUEST_EXECUTION_TIMEOUT, SCOPE_LOCAL_FILE_READ, defaultConfig } from "./config.ts";
import { clientSource, goArch, goOs, systemInfo } from "./system-info.ts";
import { type LocalFileReadRequest, readRefFrames } from "./local-file-index.ts";
import { LAN_TUNNEL_MAX_FRAME, LAN_TUNNEL_WINDOW } from "./lan-tunnel.ts";
import { currentBuildInfo, COMPONENT_NAME } from "./build-info.ts";
import { type FrameSocket, ConnectionWorkersStuck, serveConnection, socketWriter } from "./connection.ts";
import { type RuntimeCarrier, makeRuntimeTransport } from "./runtime-transport.ts";
import { type HeldIndex, type StationTaskIndex, heldFrom, nextPage, probePage } from "./task-index.ts";
import { Refused } from "../jobs/remote.ts";
import { type Access, type AccessStore, memoryAccess, requestedAccess } from "../device/access.ts";
import { startCommand } from "../ops/processes.ts";
import { platform } from "../platform/index.ts";
import { AuthError, WebSocketHandshakeError, makeStatusWriter } from "./status.ts";
import { lanGatewayCapability } from "./lan-gateway.ts";
import { LOCAL_FILE_INDEX_VERSION } from "./local-file-index.ts";
import { makeWebSocketWriter } from "./websocket-writer.ts";
import { Sockets as SocketsService } from "./sockets.ts";
import { RuntimeInventory } from "./runtime-inventory.ts";
import { MAX_RUNTIME_TARGETS, type RuntimeTarget, discoverAgentRuntimeTargets, runtimeObservation } from "./runtime-discovery.ts";
import { COMMA_CLIENT_CONTROL_TOKEN_ENV, COMMA_CLIENT_CONTROL_URL_ENV, ClientControl, liveClientControl } from "./comma-client-cli.ts";

export type { Message } from "./message.ts";
export type { Session } from "./session.ts";
export { MAX_CONCURRENT_STREAM_WRITES, MAX_PENDING_WRITE_STREAMS, CONNECTION_DRAIN_TIMEOUT } from "./session.ts";
export { MAX_FILE_BYTES } from "./fs-methods.ts";
export { recoverableRequest, requestFingerprint } from "./request-operations.ts";
export { ClientControl } from "./comma-client-cli.ts";

export const REQUEST_EXECUTION_SLOP_MS = 5_000;
export const WEBSOCKET_WRITE_TIMEOUT = Duration.seconds(20);
export { CLEANUP_QUEUE_SIZE, MAX_CONCURRENT_REQUESTS, REQUEST_EXECUTION_TIMEOUT, SCOPE_LOCAL_FILE_READ, validateConfig } from "./config.ts";
export type { ConnectorConfig } from "./config.ts";

export class ConnectorFatal extends Error {
  override readonly name = "ConnectorFatal";
  constructor(cause: unknown) {
    super(cause instanceof Error ? cause.message : String(cause), { cause });
  }
}

export const isConnectorFatal = (error: unknown): error is ConnectorFatal => error instanceof ConnectorFatal;

/** Errors after which reconnecting cannot help (a sticky fatal, an auth rejection). */
export function terminalConnectionError(error: unknown): boolean {
  return isConnectorFatal(error) || error instanceof ConnectionWorkersStuck;
}

export { currentBuildInfo } from "./build-info.ts";
export { AuthError } from "./status.ts";
export const MIN_RECONNECT_BACKOFF_MS = 1_000;
export const MAX_RECONNECT_BACKOFF_MS = 30_000;
export const RUNTIME_NOT_QUIET = "runtime is not quiet";
/** What a parked station still serves: the archive of its quiet state. */
const PARKED_METHODS = new Set(["archive_export", "archive_status", "archive_cancel"]);
/** MCP servers the desktop app's Main serves to Salix through `client_mcp`. */
const CLIENT_MCP_SERVERS = new Set(["mac-apps"]);
/** Main answers a Mac apps call within its own deadline (25 seconds); past this, Main is not answering. */
export const CLIENT_MCP_TIMEOUT = Duration.seconds(30);
export const SALIX_REQUEST_TIMEOUT = Duration.seconds(30);
/// A Task post that names files: Salix reads them from here (task.posted_file) before it answers.
export const SALIX_FILE_POST_TIMEOUT = Duration.minutes(30);
/**
 * Salix sends a heartbeat every 15 seconds. A connection that hears nothing for this long is gone, even when its socket
 * has not noticed (the computer slept, its network changed): it is closed and dialed again.
 */
export const WEBSOCKET_READ_TIMEOUT = Duration.seconds(45);
export const CONNECTOR_INSTANCE_HEADER = "X-Salix-Connector-Instance-ID";
/** Says which kind of credential the bearer is: absent for a device's connector token, `workload` for a Workload's. */
export const CREDENTIAL_KIND_HEADER = "X-Salix-Credential-Kind";

/** How long a request may run: method contracts first, then the general deadline. */
export function requestTimeoutMs(msg: Message, generalMs = Duration.toMillis(REQUEST_EXECUTION_TIMEOUT)): number {
  const method = msg.method ?? "";
  if (method === "runtime_probe" || method.startsWith("runtime_auth_")) return 30_000;
  if (method === "meeting_artifact_read") return meetingArtifactRequestTimeoutMs(msg.params, generalMs);
  if (method === "read_ref") return 60_000;
  let seconds = 0;
  if (method === "exec") seconds = intParam(msg.params, "timeout", 0);
  else if (method === "http_request" || method === "lan_http_request") seconds = intParam(msg.params, "timeout_seconds", 0);
  else if (method === "process_tail") seconds = intParam(msg.params, "wait_seconds", 0);
  if (seconds <= 0) return generalMs;
  const requested = seconds * 1000 + REQUEST_EXECUTION_SLOP_MS;
  return Math.min(Math.max(requested, generalMs), Number.MAX_SAFE_INTEGER);
}

/** File methods block in the kernel and ignore their deadline, as they did in Go: they reply when the I/O returns. */
const DEADLINE_EXEMPT = new Set(["read", "write", "delete", "stat", "list", "glob", "grep", "read_stream", "write_stream"]);
export const requestDeadlineApplies = (method: string) => !DEADLINE_EXEMPT.has(method);

export type ConnectionIdentity = { runId: string; deviceId: string; connectorId: string; ownerUserId: string; generation: number };

/**
 * What the station gives its connector: its Tasks, for Salix's, whether its agents are all idle, the computer's one
 * access value a device's connection follows (device/access.ts), and its own Tasks' index (task-index.ts).
 */
export type StationParts = { tasks?: StationTasks; agentsIdle?: () => boolean; archive?: ArchiveState; relay?: StationRelay; profiles?: StationProfiles; place?: StationPlace; access?: AccessStore; index?: StationTaskIndex };

/**
 * A Workload's station is one Salix, its control plane, made: Salix asks which station it is (`station_identity`) and
 * places it in its Group's workspace (`station_place`), as an enrollment would.
 */
export type StationPlace = {
  identity(): { station: string; version: string };
  placed(place: Record<string, unknown>): void;
};

/**
 * Salix as the Station Tasks are kept on (src/tasks/tasks.ts): it sends `task.invite` and `task.put`, and the station
 * asks it, while connected, `task.post` and `task.hello`.
 */
export type StationTasks = {
  /// A request of Salix's (`method`: task.invite or task.put).
  handle(method: string, params: Record<string, unknown>): Promise<unknown>;
  /// The models its Sessions can run, by runtime (what its profiles have enabled): what a Task may choose.
  models(): Record<string, string[]>;
  /// Called when they may have changed (the station's profiles were edited): Salix is told them again.
  listen?(changed: () => void): () => void;
  /// How to ask Salix now; null once the connection is gone.
  attach(ask: ((request: Record<string, unknown>) => Promise<unknown>) | null): void;
};

/**
 * The workspace's accounts Salix lends a Workload's station, or a desktop app's connection to one of its Workspaces
 * (`device`): Salix sends their profiles (`station_profiles`), and the station asks it, while connected, for what it
 * lends of them (`share.*`, as of another station's share).
 */
export type StationProfiles = {
  /// A desktop app's connection takes them too (on a device token).
  device?: boolean;
  received(profiles: unknown): void;
  attach(ask: ((request: Record<string, unknown>) => Promise<unknown>) | null): void;
};

/**
 * The station's side of Salix as the relay of last resort: its iroh endpoint id, a signature by its key (proving the
 * id to Salix), what came through Salix on a connection, and where a connection sends what goes out (null once it no
 * longer carries it). A station has a connection per Workspace it is in, each keyed by its socket.
 */
export type StationRelay = {
  endpointId: string;
  sign(message: Buffer): Buffer;
  incoming(from: string, data: Buffer, via: object): void;
  attach(via: object, send: ((to: string, data: Buffer) => void) | null): void;
};

/** A packet through Salix in a binary frame: kind 1, the peer's 32-byte endpoint id, the packet. */
export const RELAY_FRAME = 1;
export const relayChallengeMessage = (runId: string, challenge: string) => Buffer.from(`comma-salix-relay-v1:${runId}:${challenge}`);

export function makeConnector(input: Partial<ConnectorConfig> = {}, services?: Layer.Layer<any>, station: StationParts = {}) {
  const cfg: ConnectorConfig = { ...defaultConfig(), ...input };
  if (input.env) cfg.env = { ...input.env };

  const clock: ConnectorClock = cfg.testClock ? testClock() : liveClock();
  // Services: the live network and sockets, overridden by whatever the caller (a test) provides.
  const liveServices = Layer.mergeAll(liveNet, liveSockets, liveMeetHttp);
  const provide = <A, E, R = never>(effect: Effect.Effect<A, E, R>): Effect.Effect<A, E> => {
    const withServices = services ? effect.pipe(Effect.provide(services as Layer.Layer<any>)) : effect;
    return clock.provide((withServices as Effect.Effect<A, E, Net | Sockets | MeetHttp>).pipe(Effect.provide(liveServices)));
  };
  const fork = <A, E>(effect: Effect.Effect<A, E>): Fiber.Fiber<A, E> => Effect.runFork(provide(effect));

  // Scope. A device's follows the computer's one access value (device/access.ts): full allows operations; read and off
  // are read-only, and off also refuses the device's file reads. What this connection was configured with (the app's
  // file, its arguments, a standalone device's device-access.json from before) gives the computer its value while it
  // has none.
  let scope = cfg.scope.trim();
  const currentScope = () => scope;
  const runtimeStateRoot = () => (cfg.deviceMode && cfg.deviceStateRoot ? cfg.deviceStateRoot : cfg.externalStateRoot || cfg.root);
  if (cfg.deviceMode && !cfg.configPath) scope = loadDeviceAccess(joinPath(runtimeStateRoot(), "device-access.json")) ?? scope;
  const accessStore: AccessStore | null = cfg.deviceMode ? (station.access ?? memoryAccess()) : null;
  const configuredAccess: Access = scope === SCOPE_LOCAL_FILE_READ ? "read" : "full";
  if (accessStore && accessStore.get() === null) {
    try {
      accessStore.set(configuredAccess);
    } catch {
      // config.json refuses the edit (broken by hand): this connection runs as configured until it is mended.
    }
  }
  const deviceAccessLevel = (): Access => accessStore?.get() ?? configuredAccess;
  const scopeOf = (access: Access) => (access === "full" ? "" : SCOPE_LOCAL_FILE_READ);
  if (accessStore) scope = scopeOf(deviceAccessLevel());

  // Connection generation and identity.
  let activeConnection: Session | null = null;
  let identity: ConnectionIdentity = { runId: "", deviceId: "", connectorId: "", ownerUserId: "", generation: 0 };
  let connectionWatchers = 0;

  // Request admission.
  let requestSlots = 0;
  const operations = makeRequestOperations<Session>(clock.nowMs);
  const hooks: {
    beforeRequestAdmission?: (session: Session, msg: Message) => Effect.Effect<void>;
    afterRequestFinished?: (msg: Message) => Effect.Effect<void>;
    afterConnectionPublished?: (previous: Session) => Effect.Effect<void>;
    beforeManagedProcessStart?: Effect.Effect<void>;
  } = {};

  // Cleanup and fatal errors.
  const cleanupQueue: Closer[] = [];
  /** What could not be queued once the connector went fatal: closed when the connector closes. */
  const abandonedCleanup: Closer[] = [];
  let cleanupRunning = false;
  let cleanupBlocked: Deferred.Deferred<void> | null = null;
  let fatal: ConnectorFatal | null = null;
  const fatalSignal = Deferred.makeUnsafe<ConnectorFatal>();

  const reportFatal = (error: unknown) => {
    if (fatal) return;
    fatal = isConnectorFatal(error) ? error : new ConnectorFatal(error);
    Deferred.doneUnsafe(fatalSignal, Exit.succeed(fatal));
  };

  const drainCleanup = () => {
    if (cleanupRunning) return;
    cleanupRunning = true;
    fork(
      Effect.gen(function* () {
        while (true) {
          if (cleanupBlocked) yield* Deferred.await(cleanupBlocked);
          const next = cleanupQueue.shift();
          if (!next) break;
          yield* next.close.pipe(Effect.ignore);
        }
      }).pipe(Effect.ensuring(Effect.sync(() => (cleanupRunning = false)))),
    );
  };

  const enqueueCleanup = (closer: unknown) => {
    if (!closer) return;
    if (cleanupQueue.length >= cfg.cleanupQueueSize) {
      reportFatal(new Error("connector cleanup queue exhausted"));
      abandonedCleanup.push(toCloser(closer));
      return;
    }
    cleanupQueue.push(toCloser(closer));
    drainCleanup();
  };

  const processes = makeProcessTable();
  const processFence = Semaphore.makeUnsafe(1);
  const fs: FsMethods = makeFsMethods(() => cfg.root);

  const exec = (params: Record<string, unknown>) =>
    Effect.gen(function* () {
      const command = stringParam(params, "command");
      if (!command) return yield* Effect.fail(new Error("'command' is required"));
      const cwd = resolvePath(cfg.root, stringParam(params, "working_dir") || ".");
      let timeoutSeconds = intParam(params, "timeout", 120);
      if (timeoutSeconds <= 0) timeoutSeconds = 120;
      const env = execEnv(cfg.env, params.env);
      // A POSIX shell by default, on every machine (Git's sh on Windows); PowerShell when asked for.
      const shell = stringParam(params, "shell") || "sh";
      if (shell !== "sh" && shell !== "powershell") return yield* Effect.fail(new Error("'shell' is sh or powershell"));
      const how = shell === "powershell" ? platform.powerShell(command, env) : { program: platform.posixShell(env), args: ["-c", command] };
      if (!how) return yield* Effect.fail(new Error("PowerShell is not on this device"));
      const child = startCommand(how.program, how.args, { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
      const out = { stdout: Buffer.alloc(0), stderr: Buffer.alloc(0), full: false };
      const collect = (key: "stdout" | "stderr") => (chunk: Buffer) => {
        const remaining = MAX_OUTPUT_BYTES - out[key].length;
        if (remaining > 0) out[key] = Buffer.concat([out[key], chunk.subarray(0, remaining)]);
      };
      child.stdout!.on("data", collect("stdout"));
      child.stderr!.on("data", collect("stderr"));
      const exited = Effect.callback<{ code: number | null; error?: Error }>((resume) => {
        child.once("error", (error) => resume(Effect.succeed({ code: null, error })));
        child.once("close", (code) => resume(Effect.succeed({ code })));
      });
      const outcome = yield* exited.pipe(
        Effect.timeoutOption(Duration.seconds(timeoutSeconds)),
        Effect.onInterrupt(() => Effect.sync(() => signalGroup(child, "SIGKILL"))),
      );
      if (outcome._tag === "None") {
        signalGroup(child, "SIGKILL");
        return { exit_code: -1, stdout: "", stderr: `timed out after ${timeoutSeconds}s`, truncated: false, status: "timeout" };
      }
      if (outcome.value.error) return yield* Effect.fail(outcome.value.error);
      return {
        exit_code: outcome.value.code ?? -1,
        stdout: out.stdout.toString(),
        stderr: out.stderr.toString(),
        truncated: out.stdout.length >= MAX_OUTPUT_BYTES || out.stderr.length >= MAX_OUTPUT_BYTES,
        status: "completed",
      };
    });

  const processStart = (params: Record<string, unknown>) =>
    Effect.gen(function* () {
      const name = stringParam(params, "process_name") || `proc-${clock.nowMs().toString(36)}`;
      const command = stringParam(params, "command");
      if (!command) return yield* Effect.fail(new Error("'command' is required"));
      const existing = processes.processes.get(name);
      if (existing?.isRunning()) return yield* Effect.fail(new Error(`process "${name}" is already running`));
      const cwd = resolvePath(cfg.root, stringParam(params, "working_dir") || ".");
      const args = Array.isArray(params.args) ? params.args.map(String) : [];
      // Registration and start are fenced against a scope downgrade: it either refuses this start or sees the
      // process and stops it before acknowledging.
      return yield* Semaphore.withPermits(processFence, 1)(
        Effect.gen(function* () {
          if (hooks.beforeManagedProcessStart) yield* hooks.beforeManagedProcessStart;
          if (scope === SCOPE_LOCAL_FILE_READ) return yield* Effect.fail(new Error(`process start is not permitted for a ${SCOPE_LOCAL_FILE_READ} connector`));
          const proc = yield* spawnManaged(name, command, args, cwd, processStartEnv(cfg.env, params.env), clock.nowMs());
          processes.register(proc);
          return proc.summary();
        }),
      );
    });


  /** Opens a TCP connection relayed over this generation's socket; it outlives the request, not the socket. */
  const lanTcpDial = (session: Session, id: string, params: Record<string, unknown>) =>
    Effect.gen(function* () {
      const host = stringParam(params, "host");
      if (!host) return yield* Effect.fail(new Error("'host' is required"));
      const port = intParam(params, "port", 0);
      if (port < 1 || port > 65535) return yield* Effect.fail(new Error("'port' must be between 1 and 65535"));
      let timeoutSeconds = intParam(params, "timeout_seconds", 0);
      if (timeoutSeconds <= 0 || timeoutSeconds > 15) timeoutSeconds = 15;
      if (scope === SCOPE_LOCAL_FILE_READ) return yield* Effect.fail(new Error(`method "lan_tcp_dial" is not permitted for a ${SCOPE_LOCAL_FILE_READ} connector`));
      const tunnel = yield* Effect.try({ try: () => session.reserveTunnel(id), catch: (e) => (e instanceof Error ? e : new Error(String(e))) });
      const net = yield* Net;
      const dialed = yield* Effect.exit(net.dial(host, port).pipe(Effect.timeoutOption(Duration.seconds(timeoutSeconds))));
      if (Exit.isFailure(dialed) || dialed.value._tag === "None") {
        session.removeTunnel(id, tunnel);
        return yield* Effect.fail(Exit.isFailure(dialed) ? errorFrom(dialed) : new Error(`dial tcp ${host}:${port}: i/o timeout`));
      }
      const conn = dialed.value.value;
      if (!tunnel.attach(conn)) {
        yield* conn.close;
        session.removeTunnel(id, tunnel);
        return yield* Effect.fail(new Error("tunnel closed before the connection opened"));
      }
      return { status: "connected", remote_address: `${host}:${port}`, window: LAN_TUNNEL_WINDOW, max_frame: LAN_TUNNEL_MAX_FRAME };
    });

  // Requests to Salix on the live connection (meeting callbacks and the LLM route share its bounded slots).
  const transport = makeRuntimeTransport({ proxySlots: MAX_CONCURRENT_REQUESTS });
  const computerUse = makeComputerUse(cfg, (effect) => void fork(effect));
  const meeting = makeMeeting({ meetUrl: cfg.meetUrl, callbackHost: cfg.meetCallbackHost, callbackPort: cfg.meetCallbackPort, transport, nowMs: clock.nowMs, run: (effect) => Effect.runPromiseExit(provide(effect)) });
  fork(computerUse.sweepAtStart);

  const tasksCall = (method: string, params: Record<string, unknown>) =>
    runtimesOnly(
      Effect.suspend(() => {
        const tasks = station.tasks;
        if (!tasks) return Effect.fail(new Error("this station takes no Tasks"));
        return Effect.tryPromise({ try: () => tasks.handle(method, params), catch: (e) => (e instanceof Error ? e : new Error(String(e))) });
      }),
    );
  // A Workload's station takes Salix's profiles, and a desktop app's connection: another device's are its own.
  const takesProfiles = () => station.profiles !== undefined && (station.profiles.device === true || !!cfg.workloadCredential);
  const profilesCall = (params: Record<string, unknown>): Effect.Effect<Record<string, unknown>, Error> =>
    Effect.suspend(() => {
      if (!station.profiles) return Effect.fail(new Error("this station takes no profiles"));
      if (!takesProfiles()) return Effect.fail(new Error("not a managed runtime connector"));
      return Effect.try({ try: () => (station.profiles!.received(params.profiles), { received: true }), catch: (e) => (e instanceof Error ? e : new Error(String(e))) });
    });
  // Only a Workload's station is placed by Salix: a device joins its workspace by enrolling.
  const placeCall = (call: (place: StationPlace) => Record<string, unknown>): Effect.Effect<Record<string, unknown>, Error> =>
    Effect.suspend(() => {
      if (!cfg.workloadCredential) return Effect.fail(new Error("not a managed runtime connector"));
      if (!station.place) return Effect.fail(new Error("this station is not placed by Salix"));
      return Effect.try({ try: () => call(station.place!), catch: (e) => (e instanceof Error ? e : new Error(String(e))) });
    });
  const runtimesOnly = <A>(effect: Effect.Effect<A, Error, any>) =>
    Effect.suspend(() => (externalRuntimesEnabled() ? effect : Effect.fail(new Error("external runtimes are disabled for this Connector process"))));

  // The managed lifecycle (a Workload's station only): Salix parks an idle runtime before it archives or stops it.
  // Quiesce holds while no request, process or agent is busy, under a token, for a bounded time; resume ends it,
  // release makes it final. A parked station refuses every other request.
  let parked: { token: string; until: number; released: boolean } | null = null;
  const parkExpired = () => {
    if (parked && !parked.released && clock.nowMs() >= parked.until) parked = null;
  };
  const busy = () => requestSlots > 1 || [...processes.processes.values()].some((p) => p.isRunning()) || station.agentsIdle?.() === false;
  const lifecycle = (method: string, params: Record<string, unknown>): Effect.Effect<Record<string, unknown>, Error> =>
    Effect.suspend((): Effect.Effect<Record<string, unknown>, Error> => {
      if (!cfg.workloadCredential) return Effect.fail(new Error("not a managed runtime connector"));
      parkExpired();
      const token = stringParam(params, "token");
      if (!token || token.length > 128) return Effect.fail(new Error("invalid idle request"));
      const notQuiet = Effect.fail(new Error(RUNTIME_NOT_QUIET));
      if (method === "cloud_runtime_quiesce") {
        // A released runtime stays parked; an ambiguous release response may leave Salix retrying the quiesce.
        if (parked?.released) return Effect.succeed({ quiet: true, continued: false });
        if (parked && parked.token !== token) return notQuiet;
        if (busy()) return notQuiet;
        const continued = parked !== null;
        let ms = intParam(params, "timeout_ms", 60_000);
        if (ms <= 0 || ms > 70 * 60_000) ms = 60_000;
        parked = { token, until: clock.nowMs() + ms, released: false };
        return Effect.succeed({ quiet: true, continued });
      }
      if (!parked || parked.token !== token) return notQuiet;
      if (method === "cloud_runtime_resume") {
        if (parked.released) return notQuiet;
        parked = null;
        return Effect.succeed({ resumed: true });
      }
      parked.released = true;
      return Effect.succeed({ released: true });
    });

  // A Workload's durable archive, over the connection (src/connector/durable-archive.ts).
  const durable = station.archive
    ? makeDurableArchive({
        root: cfg.root,
        dir: archiveStateDir(runtimeStateRoot()),
        state: station.archive,
        allowedUrl: signedStorageUrl(cfg.archiveHostSuffix),
        parked: () => {
          parkExpired();
          return parked !== null && !parked.released;
        },
        fork: (effect) => void fork(effect),
        nowMs: clock.nowMs,
        sleep: (ms, signal) => Effect.runPromise(clock.provide(Effect.sleep(Duration.millis(ms))), { signal }),
      })
    : null;
  const archiveCall = (call: (archive: NonNullable<typeof durable>) => Effect.Effect<Record<string, unknown>, Error>) =>
    Effect.suspend(() => {
      if (!cfg.workloadCredential) return Effect.fail(new Error("not a managed runtime connector"));
      return durable ? call(durable) : Effect.fail(new Error("this station keeps no durable archive"));
    });

  // Salix's readiness check of a Worker's device runtime: probed now, published, and summarized.
  const probeRuntimes = (session: Session, p: Record<string, unknown>) =>
    Effect.gen(function* () {
      const provider = typeof p.provider === "string" ? p.provider.trim() : "";
      if (provider && !["codex", "pi", "kimi", "claude"].includes(provider)) return yield* Effect.fail(new Error("unsupported runtime provider"));
      const identityMaterial = typeof p.identity_material === "string" ? p.identity_material : "";
      const runtimes = yield* runtimeInventory.probe({ provider, identityMaterial, trigger: "operator" });
      yield* session.send(metadataMessage());
      const keys = ["provider", "identity_material", "model", "model_provider", "reasoning_effort", "version", "version_detected", "auth_ready", "auth", "native_server_startable", "ready", "status", "readiness_issue", "readiness_message", "readiness_checked_at", "readiness_valid_until", "probe_trigger", "probe_duration_ms"];
      return { runtimes: runtimes.map((r) => Object.fromEntries(keys.flatMap((k) => ((r as Record<string, unknown>)[k] ?? "") === "" ? [] : [[k, (r as Record<string, unknown>)[k]]]))) };
    });

  const methods: Record<string, (session: Session, id: string, params: Record<string, unknown>) => Effect.Effect<unknown, Error, any>> = {
    exec: (_s, _id, p) => exec(p),
    read: (_s, _id, p) => fs.read(p),
    write: (_s, _id, p) => fs.write(p),
    delete: (_s, _id, p) => fs.delete(p),
    stat: (_s, _id, p) => fs.stat(p),
    list: (_s, _id, p) => fs.list(p),
    glob: (_s, _id, p) => fs.glob(p),
    grep: (_s, _id, p) => fs.grep(p),
    read_stream: (s, id, p) => fs.readStream(s, id, p),
    write_stream: (s, id, p) => fs.prepareWriteStream(s, id, p),
    process_start: (_s, _id, p) => processStart(p),
    process_list: () => Effect.succeed(processes.list()),
    process_write: (_s, _id, p) => processes.write(p),
    process_tail: (_s, _id, p) => processes.tail(p),
    process_stop: (_s, _id, p) => processes.stop(p),
    http_request: (_s, _id, p) => httpRequest(p),
    lan_http_request: (_s, _id, p) => lanHttpRequest(p),
    udp_request: (_s, _id, p) => udpRequest(p),
    lan_tcp_dial: (s, id, p) => lanTcpDial(s, id, p),
    computer_use: (_s, _id, p) => computerUse.call(p),
    cloud_runtime_quiesce: (_s, _id, p) => lifecycle("cloud_runtime_quiesce", p),
    cloud_runtime_resume: (_s, _id, p) => lifecycle("cloud_runtime_resume", p),
    cloud_runtime_release: (_s, _id, p) => lifecycle("cloud_runtime_release", p),
    archive_export: (_s, _id, p) => archiveCall((a) => a.exportArchive(p)),
    archive_status: (_s, _id, p) => archiveCall((a) => a.status(p)),
    archive_cancel: (_s, _id, p) => archiveCall((a) => a.cancel(p)),
    station_profiles: (_s, _id, p) => profilesCall(p),
    station_identity: () => placeCall((place) => place.identity()),
    station_place: (_s, _id, p) => placeCall((place) => (place.placed(p), { placed: true })),
    "task.invite": (_s, _id, p) => tasksCall("task.invite", p),
    "task.put": (_s, _id, p) => tasksCall("task.put", p),
    "task.read": (_s, _id, p) => tasksCall("task.read", p),
    "task.say": (_s, _id, p) => tasksCall("task.say", p),
    "task.status": (_s, _id, p) => tasksCall("task.status", p),
    "task.diff": (_s, _id, p) => tasksCall("task.diff", p),
    "task.save": (_s, _id, p) => tasksCall("task.save", p),
    "task.pull_request": (_s, _id, p) => tasksCall("task.pull_request", p),
    "task.history": (_s, _id, p) => tasksCall("task.history", p),
    "task.leave": (_s, _id, p) => tasksCall("task.leave", p),
    "task.posted_file": (_s, _id, p) => tasksCall("task.posted_file", p),
    device_access: (_s, _id, p) => deviceAccess(p),
    client_mcp: (_s, _id, p) => clientMcp(p),
    runtime_probe: (s, _id, p) => runtimesOnly(probeRuntimes(s, p)),
    meeting_join: (_s, _id, p) => runtimesOnly(meeting.join(p)),
    meeting_send_chat: (_s, _id, p) => runtimesOnly(meeting.sendChat(p)),
    meeting_session_status: (_s, _id, p) => meeting.sessionStatus(p),
    meeting_artifact_read: (s, id, p) => runtimesOnly(meeting.readArtifact(s, id, p)),
    read_ref: (s, id, p) => readRefFrames({ root: cfg.localFileIndexRoot, session: s, id, params: p, identityCurrent: localFileReadIdentityCurrent }),
  };

  const dispatchSession = (session: Session, id: string, method: string, params: Record<string, unknown> = {}): Effect.Effect<unknown, Error> =>
    Effect.suspend(() => {
      // The scope gate precedes every method: a read-only connector serves read_ref, a read-only device also reads
      // its files unless its access is off, and access itself stays manageable. client_mcp reaches only Main,
      // which allows the Mac apps the user turned on in Plugins; like a read, it stops when access is off.
      const deviceRead = cfg.deviceMode && (method === "device_access" || (["read", "list", "stat", "read_stream", "client_mcp"].includes(method) && deviceAccessLevel() !== "off"));
      if (method !== "read_ref" && !deviceRead && scope === SCOPE_LOCAL_FILE_READ) {
        return Effect.fail(new Error(`method "${method}" is not permitted for a ${SCOPE_LOCAL_FILE_READ} connector`));
      }
      parkExpired();
      if (parked && !method.startsWith("cloud_runtime_") && !PARKED_METHODS.has(method)) {
        return Effect.fail(new Error("cloud runtime is idle; reconnect before sending requests"));
      }
      const handler = methods[method];
      if (!handler) return Effect.fail(new Error(`unknown method: ${method}`));
      return provide(handler(session, id, params));
    });

  const requestReply = (session: Session, msg: Message): Effect.Effect<Message> =>
    dispatchSession(session, msg.id ?? "", msg.method ?? "", msg.params ?? {}).pipe(
      Effect.match({
        onSuccess: (result): Message => ({ id: msg.id, type: "response", result }),
        onFailure: (error): Message => ({ id: msg.id, type: "error", error: `${msg.method}: ${error.message}` }),
      }),
    );

  const handleStream = (session: Session, msg: Message): Effect.Effect<void> =>
    Effect.gen(function* () {
      if (!msg.id || !msg.stream) return;
      if (msg.stream.channel === "ack") {
        session.completePendingAck(msg.id, msg.stream.seq ?? 0, msg.error ?? "");
        return;
      }
      if (scope === SCOPE_LOCAL_FILE_READ) {
        // A frame received after a scope downgrade cannot write: the gate is per frame.
        session.abortPendingWrite(msg.id);
        return;
      }
      const pending = session.pendingWrite(msg.id);
      if (!pending) return;
      const done = (error: string) => session.send({ id: msg.id, type: "stream", error, stream: { channel: "done", eof: true } }).pipe(Effect.ignore);
      if (msg.stream.data) {
        const raw = Buffer.from(msg.stream.data, "base64");
        const written = yield* Effect.exit(pending.write(raw));
        if (Exit.isFailure(written)) {
          session.finishPendingWrite(msg.id);
          yield* done(errorMessage(written));
          return;
        }
        if (!msg.stream.eof) yield* session.send({ id: msg.id, type: "stream", stream: { channel: "ack", seq: msg.stream.seq } }).pipe(Effect.ignore);
      }
      if (msg.stream.eof) {
        const size = pending.currentSize();
        session.finishPendingWrite(msg.id);
        yield* session.send({ id: msg.id, type: "stream", stream: { channel: "done", data: JSON.stringify({ size }), eof: true } }).pipe(Effect.ignore);
      }
    });

  const host: SessionHost = {
    isActive: (session) => activeConnection === null || activeConnection === session,
    takeRequestSlot: () => {
      if (requestSlots >= cfg.maxConcurrentRequests) return false;
      requestSlots++;
      return true;
    },
    releaseRequestSlot: () => {
      requestSlots = Math.max(0, requestSlots - 1);
    },
    enqueueCleanup,
    fork,
    provide,
    requestTimeout: (msg) => Duration.millis(requestTimeoutMs(msg, Duration.toMillis(cfg.requestExecutionTimeout))),
    requestReply,
    recoverable: recoverableRequest,
    deadlineApplies: requestDeadlineApplies,
    bindRequestOperation: (session, msg) => bindRequestOperationFor(session, msg, requestFingerprint(msg)),
    completeRequestOperation: (id, method, reply, beforeWrite) => completeRequestOperation(id, method, reply, beforeWrite),
    handleStream,
    hooks,
  };

  const bindRequestOperationFor = (session: Session, msg: Message, fingerprint: string): { binding: RequestBinding; reply?: Message } => {
    if ((activeConnection !== null && activeConnection !== session) || session.closed) return { binding: "rejected" };
    return operations.bind(session, msg, fingerprint, host.takeRequestSlot);
  };

  const completeRequestOperation = (id: string, method: string, reply: Message, beforeWrite: Effect.Effect<void> = Effect.void): Effect.Effect<void> =>
    Effect.suspend(() => {
      const completed = operations.complete(id, method, reply);
      if (!completed || !completed.sink) return beforeWrite;
      return completed.sink.sendRequestReply(completed.reply, beforeWrite).pipe(Effect.ignore);
    });

  const claimConnection = (send: (frame: Message, session: Session) => Effect.Effect<void, unknown>, options: SessionOptions = {}): Session => {
    let session!: Session;
    session = new Session(host, (frame) => send(frame, session), options);
    const previous = activeConnection;
    if (previous) previous.close(new Error("connection replaced"));
    activeConnection = session;
    identity = { runId: "", deviceId: "", connectorId: "", ownerUserId: "", generation: 0 };
    connectionWatchers++;
    fork(session.whenClosed.pipe(Effect.ensuring(Effect.sync(() => connectionWatchers--))));
    if (previous && hooks.afterConnectionPublished) fork(hooks.afterConnectionPublished(previous));
    return session;
  };

  const releaseConnection = (session: Session) => {
    if (activeConnection === session) activeConnection = null;
  };

  function setIdentity(session: Session | null, next: Partial<ConnectionIdentity> | string, deviceId?: string, connectorId?: string, ownerUserId?: string, generation?: number): boolean {
    if (session && activeConnection !== session) return false;
    const value: Partial<ConnectionIdentity> = typeof next === "string" ? { runId: next, deviceId, connectorId, ownerUserId, generation } : next;
    identity = { runId: value.runId ?? "", deviceId: value.deviceId ?? "", connectorId: value.connectorId ?? "", ownerUserId: value.ownerUserId ?? "", generation: value.generation ?? 0 };
    // Whose computer this is: only that user sets its access through the admin API (api/routes/tools.ts).
    if (identity.ownerUserId !== "") {
      try {
        accessStore?.owner?.(identity.ownerUserId);
      } catch {}
    }
    return true;
  }

  const deviceSystemInfo = (): Record<string, unknown> => ({ ...systemInfo(clock.nowMs()), client_source: clientSource(cfg.runtimeNamespace) });

  /** The exact live connection tuple a read_ref must name. */
  const localFileReadIdentityCurrent = (session: Session, request: LocalFileReadRequest) =>
    !session.closed &&
    activeConnection === session &&
    identity.runId !== "" &&
    identity.deviceId !== "" &&
    identity.ownerUserId !== "" &&
    identity.generation > 0 &&
    request.connectorRunId === identity.runId &&
    request.stableDeviceId === identity.deviceId &&
    request.ownerUserId === identity.ownerUserId &&
    request.connectionGeneration === identity.generation;

  const localFileImportAvailable = () => cfg.localFileIndexRoot.trim() !== "";



  // Status file.
  const status = makeStatusWriter({
    path: cfg.statusPath,
    server: cfg.server,
    scope: currentScope,
    identity: () => ({ runId: identity.runId, deviceId: identity.deviceId, connectorId: identity.connectorId }),
    build: () => currentBuildInfo(),
    nowSeconds: () => Math.floor(clock.nowMs() / 1000),
  });

  const externalRuntimesEnabled = () => cfg.deviceMode || scope !== SCOPE_LOCAL_FILE_READ;

  // The runtime inventory: discovered targets and their last observation.
  // The station's sessions are where runtimes work: a target's readiness is what the station knows of it.
  const runtimeProbe = (target: RuntimeTarget): Effect.Effect<Record<string, any>> => runtimeObservation(target, cfg.env);
  const runtimeInventory = new RuntimeInventory({
    run: (target) => provide(runtimeProbe(target)),
    fork: (effect) => void fork(effect),
    discover: () => discoverAgentRuntimeTargets({ env: cfg.env }),
    nowMs: clock.nowMs,
  });

  /** Extension points the runtime subsystems fill in. */
  const extensions = {
    // A read-only device lists its runtimes from discovery alone: nothing is executed until operations are allowed.
    agentRuntimes: (): Array<Record<string, unknown>> =>
      cfg.deviceMode && scope === SCOPE_LOCAL_FILE_READ
        ? discoverAgentRuntimeTargets({ env: cfg.env }).slice(0, MAX_RUNTIME_TARGETS).map(permissionRequired)
        : [...runtimeInventory.snapshot(), ...(meeting.detectRuntime() ?? [])],
    probeRuntimes: (trigger: string): Effect.Effect<void, Error> => runtimeInventory.probe({ trigger }).pipe(Effect.asVoid),
    connectorHealthCounts: () => ({ resumable: 0, recoverable: 0, inputBatches: 0, runtimeEvents: 0 }),
    capabilities: (_full: Record<string, unknown>) => {},
    onConnected: (_session: Session, _carrier: RuntimeCarrier): Effect.Effect<void> => Effect.void,
    onScopeRestricted: (): Effect.Effect<void> => Effect.void,
    onScopeWidened: (): Effect.Effect<void> => Effect.void,
    computerUseAvailable: () => computerUse.available(),
    meetingRuntimeConfigured: () => meeting.configured(),
  };

  const processStartedAt = clock.nowMs();
  const connectorHealth = () => {
    const counts = extensions.connectorHealthCounts();
    return {
      schema_version: 1,
      observed_at: clock.nowMs(),
      process_started_at: processStartedAt,
      request_inflight: requestSlots,
      request_capacity: cfg.maxConcurrentRequests,
      runtime_proxy_inflight: transport.proxyInflight(),
      runtime_proxy_capacity: transport.proxyCapacity(),
      managed_processes: processes.processes.size,
      resumable_runtime_sessions: counts.resumable,
      recoverable_runtime_sessions: counts.recoverable,
      pending_input_batches: counts.inputBatches,
      pending_runtime_events: counts.runtimeEvents,
    };
  };

  const metadataMessage = (): Message => {
    const build = currentBuildInfo();
    const releases = { component_versions: { [COMPONENT_NAME]: build.release_id }, component_releases: { [COMPONENT_NAME]: build } };
    if (scope === SCOPE_LOCAL_FILE_READ) {
      // A scoped connector claims only what its dispatch gate serves: never exec, processes, runtimes or computer use.
      const capabilities: Record<string, unknown> = {
        scope: SCOPE_LOCAL_FILE_READ,
        persistent_processes: false,
        computer_use_tool: false,
        host_access_required: false,
        execution_boundary: "local-file-read-only",
        runtime_probe: false,
        meeting_runtime: false,
        local_file_import_v1: localFileImportAvailable(),
        local_file_index_version: LOCAL_FILE_INDEX_VERSION,
        ...releases,
      };
      if (cfg.deviceMode) {
        capabilities.agent_runtimes = extensions.agentRuntimes();
        capabilities.device_access = true;
        capabilities.access = deviceAccessLevel();
        capabilities.lan_gateway = lanGatewayCapability();
        capabilities.client_mcp = clientMcpServers();
      }
      return { type: "metadata", capabilities, skills: [], system_info: deviceSystemInfo(), connector_health: connectorHealth() };
    }
    const capabilities: Record<string, unknown> = {
      scope,
      persistent_processes: true,
      computer_use_tool: extensions.computerUseAvailable(),
      android_device_tool: false,
      host_access_required: false,
      execution_boundary: "connector-direct",
      runtime_probe: externalRuntimesEnabled() && !dynamicallyWidened,
      meeting_runtime: externalRuntimesEnabled() && extensions.meetingRuntimeConfigured(),
      local_file_import_v1: localFileImportAvailable(),
      local_file_index_version: LOCAL_FILE_INDEX_VERSION,
      ...releases,
    };
    if (externalRuntimesEnabled() && !dynamicallyWidened) capabilities.agent_runtimes = extensions.agentRuntimes();
    // Salix's Tasks have Sessions here take part (task.invite, task.put, task.post, task.hello).
    if (station.tasks) {
      // 2: task.invite/put/post/hello (1 was task.changed/read/post).
      capabilities.tasks = 2;
      capabilities.task_models = station.tasks.models();
    }
    // 1: `task.index` pages once Salix has the station's endpoint id.
    if (station.index) capabilities.task_index = 1;
    if (cfg.deviceMode) {
      capabilities.device_access = true;
      capabilities.client_mcp = clientMcpServers();
      // Salix sends `device_access {access}` (off | read | full) to a device that says its access.
      capabilities.access = deviceAccessLevel();
    }
    capabilities.lan_gateway = lanGatewayCapability();
    extensions.capabilities(capabilities);
    return { type: "metadata", capabilities, skills: [], system_info: deviceSystemInfo(), connector_health: connectorHealth() };
  };

  /** A connector started read-only and widened by the app keeps its runtimes off (they start only at process start). */
  let dynamicallyWidened = false;
  const startedScoped = scope === SCOPE_LOCAL_FILE_READ && !cfg.deviceMode;

  const publishCachedMetadata = (): Effect.Effect<void, Error> =>
    Effect.suspend(() => {
      const session = activeConnection;
      if (!session) return Effect.fail(new Error("connector metadata transport is unavailable"));
      return session.send(metadataMessage());
    });
  // What a Task may choose to run here changed: Salix hears it now, not at the next connection.
  let taskModels = JSON.stringify(station.tasks?.models() ?? {});
  const stopTaskModels =
    station.tasks?.listen?.(() => {
      const next = JSON.stringify(station.tasks!.models());
      if (next === taskModels) return;
      taskModels = next;
      fork(publishCachedMetadata().pipe(Effect.ignore));
    }) ?? (() => {});

  /** Runtimes are probed only when this scope may run them. */
  const probeIfAllowed = (trigger: string): Effect.Effect<void, Error> =>
    scope !== SCOPE_LOCAL_FILE_READ && externalRuntimesEnabled() && !dynamicallyWidened ? extensions.probeRuntimes(trigger) : Effect.void;
  const sendMetadata = (send: (m: Message) => Effect.Effect<void, unknown>, m: Message): Effect.Effect<void, Error> =>
    send(m).pipe(Effect.mapError((e) => (e instanceof Error ? e : new Error(String(e)))));

  /** The connect metadata: runtimes are probed only when this scope may run them. */
  const probeAndPublish = (trigger: string, send: (m: Message) => Effect.Effect<void, unknown>): Effect.Effect<void, Error> =>
    probeIfAllowed(trigger).pipe(Effect.andThen(Effect.suspend(() => sendMetadata(send, metadataMessage()))));

  /**
   * After a connect's first metadata: the runtimes are probed, and their result follows as more metadata only when it
   * changes the runtimes that first metadata told. A connection with nothing to add gets no second frame.
   */
  const probeAndPublishChange = (sent: Message, send: (m: Message) => Effect.Effect<void, unknown>): Effect.Effect<void, Error> =>
    probeIfAllowed("connect").pipe(
      Effect.andThen(
        Effect.suspend(() => {
          const next = metadataMessage();
          const runtimes = (m: Message) => JSON.stringify(m.capabilities?.agent_runtimes ?? null);
          return runtimes(next) === runtimes(sent) ? Effect.void : sendMetadata(send, next);
        }),
      ),
    );

  const systemInfoLoop = (publish: () => Effect.Effect<void, unknown>, server = ""): Effect.Effect<void> =>
    Effect.gen(function* () {
      if (Duration.toMillis(cfg.systemInfoInterval) <= 0) return;
      while (true) {
        yield* Effect.sleep(cfg.systemInfoInterval);
        const published = yield* Effect.exit(publish());
        if (Exit.isSuccess(published)) status.writeStatusMetadataSent(server);
      }
    });

  // Scope changes.
  const setCurrentScope = (next: string): Effect.Effect<void, Error> =>
    Effect.gen(function* () {
      const wanted = next.trim();
      if (wanted !== "" && wanted !== SCOPE_LOCAL_FILE_READ) return yield* Effect.fail(new Error(`unsupported connector scope "${wanted}"`));
      if (scope === wanted) return;
      if (wanted === SCOPE_LOCAL_FILE_READ) {
        scope = SCOPE_LOCAL_FILE_READ;
        activeConnection?.abortPendingWritesForScope("write_stream cancelled: connector scope restricted");
        activeConnection?.finishTunnels("connector scope restricted", true);
        // Wait for an admitted process start to finish (it then sees the scope and refuses), then stop what runs.
        yield* Semaphore.withPermits(processFence, 1)(Effect.void);
        yield* processes.killAll();
        yield* extensions.onScopeRestricted();
        return;
      }
      scope = "";
      if (startedScoped) dynamicallyWidened = true;
      yield* extensions.onScopeWidened();
    });

  /** The scope the computer's access value gives, and Salix told of it (its metadata says the value). */
  const applyAccess = (): Effect.Effect<void, Error> =>
    Effect.gen(function* () {
      yield* setCurrentScope(scopeOf(deviceAccessLevel()));
      if (!activeConnection) return;
      yield* publishCachedMetadata();
      status.writeStatusMetadataSent("");
    });
  // The value changed elsewhere (the admin API, another of the station's connections): this connection follows it.
  const stopAccess = accessStore?.listen(() => void fork(applyAccess().pipe(Effect.ignore))) ?? (() => {});

  /**
   * `device_access`: sets the computer's one access value, `{access}` (off | read | full) or the 2-level
   * `{allow_operations}` of clients and servers from before (device/access.ts `requestedAccess`), and answers once Salix
   * has the metadata that says it.
   */
  const deviceAccess = (params: Record<string, unknown>): Effect.Effect<unknown, Error> =>
    Effect.gen(function* () {
      if (!accessStore) return yield* Effect.fail(new Error("restart this Connector with --device to manage its access"));
      const next = yield* Effect.try({ try: () => requestedAccess(params, deviceAccessLevel()), catch: (e) => e as Error });
      yield* Effect.try({ try: () => accessStore.set(next), catch: (e) => e as Error });
      yield* applyAccess();
      return { access: next, allows_operations: next === "full" };
    });

  /** A desktop's Main serves MCP servers (the Mac apps); a standalone device has no Main. */
  const clientMcpServers = () => (cfg.deviceMode && cfg.configPath ? [...CLIENT_MCP_SERVERS] : []);

  /** `client_mcp`: one JSON-RPC message to an MCP server in Main, answered by Main's reply (null for a notification). */
  const clientMcp = (params: Record<string, unknown>): Effect.Effect<unknown, Error> =>
    Effect.gen(function* () {
      const server = params.server;
      if (typeof server !== "string" || !clientMcpServers().includes(server)) {
        return yield* Effect.fail(new Error(`client MCP server "${String(server)}" is not served by this device`));
      }
      const message = params.message;
      if (message === null || typeof message !== "object" || Array.isArray(message)) {
        return yield* Effect.fail(new Error("message must be a JSON-RPC object"));
      }
      const endpoint = (cfg.env[COMMA_CLIENT_CONTROL_URL_ENV] ?? "").trim().replace(/\/+$/, "");
      const token = cfg.env[COMMA_CLIENT_CONTROL_TOKEN_ENV] ?? "";
      if (!endpoint || !token) return yield* Effect.fail(new Error("the Comma app is not running on this device"));
      const provided = yield* Effect.serviceOption(ClientControl);
      const control = provided._tag === "Some" ? provided.value : yield* Effect.provide(Effect.service(ClientControl), liveClientControl(endpoint));
      if (!control.mcp) return yield* Effect.fail(new Error("the Comma app does not serve MCP"));
      // A tool call that got no answer may still have been made (a message sent, an event created): the error says so,
      // and the request to Main is aborted.
      const reply = yield* control.mcp(token, server, message).pipe(
        Effect.timeoutOrElse({
          duration: CLIENT_MCP_TIMEOUT,
          orElse: () =>
            Effect.fail(new Error(`the Comma app did not answer in ${Duration.toSeconds(CLIENT_MCP_TIMEOUT)} seconds; a change it was making may or may not have been made`)),
        }),
      );
      return { message: reply };
    });

  /** The app's private control pipe: `set_scope` lines carrying this run's exact nonce. */
  const watchScopeControl = (input: AsyncIterable<unknown> | NodeJS.ReadableStream): Effect.Effect<void> =>
    Effect.gen(function* () {
      const lines = yield* Effect.promise(async () => {
        const out: string[] = [];
        let buffer = "";
        for await (const chunk of input as AsyncIterable<unknown>) {
          buffer += typeof chunk === "string" ? chunk : Buffer.from(chunk as Uint8Array).toString();
          let index: number;
          while ((index = buffer.indexOf("\n")) >= 0) {
            out.push(buffer.slice(0, index));
            buffer = buffer.slice(index + 1);
          }
        }
        if (buffer) out.push(buffer);
        return out;
      });
      for (const line of lines) {
        if (line.length > 4096) continue;
        let command: { type?: unknown; run_nonce?: unknown; scope?: unknown };
        try {
          command = JSON.parse(line);
        } catch {
          continue;
        }
        if (command.type !== "set_scope" || typeof command.scope !== "string" || typeof command.run_nonce !== "string") continue;
        if (!constantTimeEqual(command.run_nonce.trim().toLowerCase(), cfg.runNonce)) continue;
        if (Exit.isFailure(yield* Effect.exit(setCurrentScope(command.scope)))) continue;
        // The status file's scope is the app's acknowledgement: it advances only after the metadata went out.
        if (Exit.isSuccess(yield* Effect.exit(publishCachedMetadata()))) status.writeStatusMetadataSent("");
      }
    });

  const connectUrl = (server: string): string => {
    let base = server.replace(/\/+$/, "");
    if (base.startsWith("http://")) base = `ws://${base.slice("http://".length)}`;
    if (base.startsWith("https://")) base = `wss://${base.slice("https://".length)}`;
    const url = new URL(`${base}/v1/connect`);
    url.searchParams.set("name", cfg.name);
    if (cfg.alias) url.searchParams.set("alias", cfg.alias);
    url.searchParams.set("os", goOs());
    url.searchParams.set("arch", goArch());
    // Present even when empty (full): the server fences a predecessor's stale scope with it.
    url.searchParams.set("scope", scope);
    return url.toString();
  };

  const processInstanceId = randomInstanceId();

  // The credential the connection presents: the device's connector token, or a Compute Workload's connect credential.
  // Every connection presents the same one: it has no expiry, and it ends when its Workload's generation advances.
  const credentialHeaders = (): Record<string, string> =>
    cfg.workloadCredential ? { authorization: `Bearer ${cfg.workloadCredential}`, [CREDENTIAL_KIND_HEADER]: "workload" } : { authorization: `Bearer ${cfg.token}` };
  // The connection to Salix while it is up: its socket, and once Salix said `connected`, the carrier its requests ride
  // and whether Salix takes the device's next credential over it (`credential_renewal`).
  let live: { close: Effect.Effect<void>; carrier: RuntimeCarrier | null; renewal: boolean } | null = null;
  /**
   * The device's next connector credential, which the app wrote before the current one expires: the next dial presents
   * it, and the live connection presents it to Salix (`connector_credential_renew`) so that it keeps serving, with its
   * requests and processes, past the credential it holds now. A Salix that refuses it, does not take one, or has not yet
   * confirmed the connection gets a new connection with it at once.
   */
  const renewCredential = (token: string): Effect.Effect<void> =>
    Effect.sync(() => {
      if (!token || token === cfg.token) return;
      cfg.token = token;
      const current = live;
      if (!current) return;
      fork(
        Effect.gen(function* () {
          if (current.carrier && current.renewal && !current.carrier.closed) {
            const request = { id: transport.nextRequestId("credential_"), type: "request", method: "connector_credential_renew", params: { token } };
            const reply = yield* Effect.exit(transport.request(current.carrier, request, SALIX_REQUEST_TIMEOUT));
            if (Exit.isSuccess(reply) && reply.value.type !== "error") return;
          }
          if (live !== current) return;
          // This connection ends, and its socket with it: the next dial presents the new credential.
          if (activeConnection) activeConnection.close(new Error("connector credential renewed"));
          else yield* current.close;
        }),
      );
    });
  // Salix as the relay of last resort: the station proves its endpoint id, then its packets go in binary frames.
  let relaySocket: { sendBinary?(data: Buffer): Effect.Effect<void, Error> } | null = null;
  const registerRelay = (carrier: RuntimeCarrier, challenge: string): Effect.Effect<void> =>
    Effect.gen(function* () {
      const relay = station.relay;
      const socket = relaySocket;
      if (!relay || !socket?.sendBinary) return;
      const signature = relay.sign(relayChallengeMessage(identity.runId, challenge)).toString("base64");
      const reply = yield* Effect.exit(transport.request(carrier, { id: transport.nextRequestId("relay_"), type: "request", method: "relay_register", params: { endpoint_id: relay.endpointId, signature } }, SALIX_REQUEST_TIMEOUT));
      if (Exit.isFailure(reply) || reply.value.type === "error" || carrier.closed || relaySocket !== socket) return;
      relay.attach(socket, (to, data) => {
        if (relaySocket !== socket || !/^[0-9a-f]{64}$/.test(to)) return;
        const frame = Buffer.concat([Buffer.from([RELAY_FRAME]), Buffer.from(to, "hex"), data]);
        fork(socket.sendBinary!(frame).pipe(Effect.ignore));
      });
      fork(syncTaskIndex(carrier));
    });

  /**
   * Keeps Salix's copy of the station's Task index current while `carrier` is the live connection: asks what Salix holds,
   * sends what it lacks a page at a time, and again after the station's writes. Salix answers `rate_limited` to more than
   * a few pages a second; any other refusal (`not_this_group`, a Salix from before) ends it until the next connection.
   */
  const syncTaskIndex = (carrier: RuntimeCarrier): Effect.Effect<void> =>
    Effect.gen(function* () {
      const index = station.index;
      if (!index) return;
      let changed = yield* Deferred.make<void>();
      const stop = index.listen(() => void Effect.runSync(Deferred.succeed(changed, undefined)));
      yield* Effect.addFinalizer(() => Effect.sync(stop));
      const send = (page: ReturnType<typeof probePage>): Effect.Effect<HeldIndex | "rate_limited" | null> =>
        Effect.gen(function* () {
          const reply = yield* Effect.exit(transport.request(carrier, { id: transport.nextRequestId("index_"), type: "request", method: "task.index", params: page }, SALIX_REQUEST_TIMEOUT));
          if (Exit.isFailure(reply)) return null;
          if (reply.value.type === "error") return reply.value.error === "rate_limited" ? "rate_limited" : null;
          return heldFrom(reply.value.result);
        });
      let held: HeldIndex | null = null;
      let page: ReturnType<typeof probePage> | null = probePage(index);
      while (!carrier.closed) {
        if (page === null) {
          // Most writes change no Task's row: wait for one that moved the index, a second's writes together.
          yield* Deferred.await(changed);
          changed = yield* Deferred.make<void>();
          if (held !== null && index.rev() === held.through && index.epoch() === held.epoch) continue;
          yield* Effect.sleep(Duration.seconds(1));
          page = held === null ? probePage(index) : nextPage(index, held);
          continue;
        }
        const answer: HeldIndex | "rate_limited" | null = yield* send(page);
        if (answer === null) return;
        if (answer === "rate_limited") {
          yield* Effect.sleep(Duration.seconds(1));
          continue;
        }
        held = answer;
        page = nextPage(index, answer);
        if (page === null) index.prune(answer.through);
        else yield* Effect.sleep(Duration.millis(300));
      }
    }).pipe(Effect.scoped, Effect.raceFirst(Deferred.await(carrier.done)), Effect.asVoid);

  /** The host a connection generation is served with. */
  const connectionHost = () => ({
    claim: (send: (m: Message) => Effect.Effect<void, unknown>, writer: ReturnType<typeof makeWebSocketWriter> extends Effect.Effect<infer W, any, any> ? W : never) =>
      claimConnection(send, { onClose: (reason: unknown) => void Effect.runFork(writer.close(reason instanceof Error ? reason : new Error(String(reason)))), sendReply: (m: Message, before: Effect.Effect<void>) => writer.sendBeforeWrite(m, before) }),
    release: releaseConnection,
    isActive: (session: Session) => activeConnection === session,
    setIdentity: (session: Session, frame: Message) =>
      setIdentity(session, { runId: frame.connector_run_id ?? "", deviceId: frame.device_id ?? "", connectorId: frame.connector_id ?? "", ownerUserId: frame.owner_user_id ?? "", generation: frame.connection_generation ?? 0 }),
    // The first frame is the metadata as it stands; the runtimes are probed after it, beside the requests. A probe
    // runs each runtime's command, which on a Container just started reads its binary from the image (3 s for
    // Claude Code's): Salix's requests are not held behind it.
    publishConnectMetadata: (session: Session) =>
      Effect.suspend(() => {
        const first = metadataMessage();
        return sendMetadata((m) => session.send(m), first).pipe(
          Effect.tap(() =>
            Effect.sync(() => {
              status.writeStatusMetadataSent(cfg.server);
              fork(probeAndPublishChange(first, (m) => session.send(m)).pipe(Effect.ignore));
            }),
          ),
        );
      }),
    activateCarrier: (session: Session) => transport.activate((m) => session.send(m)),
    revokeCarrier: (carrier: RuntimeCarrier) => transport.revoke(carrier),
    systemInfoLoop: (session: Session) => systemInfoLoop(() => session.send(metadataMessage()), cfg.server),
    onConnected: (session: Session, carrier: RuntimeCarrier, frame: Message) =>
      Effect.gen(function* () {
        if (live) Object.assign(live, { carrier, renewal: frame.credential_renewal === true });
        if (typeof frame.relay_challenge === "string" && frame.relay_challenge) fork(registerRelay(carrier, frame.relay_challenge));
        if (station.profiles && takesProfiles()) {
          station.profiles.attach(async (request) => {
            if (carrier.closed) throw new Error("not connected to Salix");
            const reply = await Effect.runPromise(provide(transport.request(carrier, { id: transport.nextRequestId("share_"), type: "request", method: String(request.method), params: request }, SALIX_REQUEST_TIMEOUT)));
            if (reply.type === "error") throw new Error(String(reply.error ?? "Salix refused"));
            return reply.result;
          });
        }
        if (station.tasks && externalRuntimesEnabled() && scope !== SCOPE_LOCAL_FILE_READ) {
          station.tasks.attach(async (request) => {
            if (carrier.closed) throw new Error("not connected to Salix");
            const timeout = Array.isArray(request.files) && request.files.length > 0 ? SALIX_FILE_POST_TIMEOUT : SALIX_REQUEST_TIMEOUT;
            const reply = await Effect.runPromise(provide(transport.request(carrier, { id: transport.nextRequestId("task_"), type: "request", method: String(request.method), params: request }, timeout)));
            if (reply.type === "error") throw new Refused(String(reply.error ?? "Salix refused"));
            return reply.result;
          });
        }
        remoteReady = true;
        status.writeStatus("connected", cfg.server, null);
        if (!externalRuntimesEnabled() || scope === SCOPE_LOCAL_FILE_READ) return;
        yield* extensions.onConnected(session, carrier);
      }),
    completeRuntimeReply: (frame: Message) => transport.complete(frame),
    writeTimeout: null,
    fork,
  });

  const writeBounded = (effect: Effect.Effect<void, Error>) =>
    effect.pipe(
      Effect.timeoutOption(WEBSOCKET_WRITE_TIMEOUT),
      Effect.flatMap((o) => (o._tag === "Some" ? Effect.void : Effect.fail(new Error("websocket write deadline exceeded")))),
    );

  /** Each read: the next frame within the read timeout. */
  const readBounded = (receive: Effect.Effect<unknown, Error>) =>
    receive.pipe(
      Effect.timeoutOrElse({
        duration: WEBSOCKET_READ_TIMEOUT,
        orElse: () => Effect.fail(new Error(`websocket read deadline exceeded: nothing from Salix in ${Duration.toSeconds(WEBSOCKET_READ_TIMEOUT)} seconds`)),
      }),
    );

  const serve = (socket: FrameSocket) =>
    Effect.scoped(
      Effect.gen(function* () {
        const writer = yield* makeWebSocketWriter(socketWriter(socket, writeBounded));
        return yield* serveConnection(connectionHost(), { ...socket, receive: readBounded(socket.receive) }, writer);
      }),
    );

  // Salix connection.
  let remoteReady = false;

  const runRemoteOnce: Effect.Effect<void, Error> = Effect.gen(function* () {
    status.writeStatus("connecting", cfg.server, null);
    const url = connectUrl(cfg.server);
    const sockets = yield* SocketsService;
    const socket = yield* sockets.dial(url, { ...credentialHeaders(), [CONNECTOR_INSTANCE_HEADER]: processInstanceId });
    const current: NonNullable<typeof live> = { close: socket.close, carrier: null, renewal: false };
    live = current;
    const fatalWatch = fork(Deferred.await(fatalSignal).pipe(Effect.andThen(socket.close)));
    // Packets through Salix ride this connection, once Salix has the station's endpoint id (`relay_register`).
    const relay = station.relay;
    if (relay && socket.onBinary) {
      socket.onBinary((frame) => {
        if (frame.length < 33 || frame[0] !== RELAY_FRAME) return;
        relay.incoming(frame.subarray(1, 33).toString("hex"), frame.subarray(33), socket);
      });
    }
    relaySocket = relay && socket.sendBinary ? socket : null;
    const outcome = yield* Effect.exit(serve({ send: (f) => socket.send(f), receive: socket.receive, close: socket.close }));
    yield* Fiber.interrupt(fatalWatch);
    if (live === current) live = null;
    relaySocket = null;
    station.relay?.attach(socket, null);
    station.profiles?.attach(null);
    if (fatal) return yield* Effect.fail(fatal);
    if (Exit.isFailure(outcome)) return yield* Effect.fail(errorFrom(outcome));
    return yield* Effect.fail(outcome.value);
  }).pipe((effect) => provide(effect as Effect.Effect<void, Error, any>));

  const jitterBackoff = (base: number) => {
    const factor = 800 + Math.floor(Math.random() * 401);
    return Math.min(Math.max(Math.floor((base * factor) / 1000), MIN_RECONNECT_BACKOFF_MS), MAX_RECONNECT_BACKOFF_MS);
  };

  const runRemote: Effect.Effect<void, Error> = provide(
    Effect.gen(function* () {
      status.writeStatus("starting", "", null);
      yield* meeting.start;
      let backoff = MIN_RECONNECT_BACKOFF_MS;
      while (true) {
        if (fatal) return yield* Effect.fail(fatal);
        remoteReady = false;
        const outcome = yield* Effect.exit(runRemoteOnce);
        const error = Exit.isFailure(outcome) ? errorFrom(outcome) : new Error("connection closed");
        if (fatal) return yield* Effect.fail(fatal);
        if (terminalConnectionError(error)) return yield* Effect.fail(error);
        if (!cfg.reconnect) return yield* Effect.fail(error);
        if (remoteReady) backoff = MIN_RECONNECT_BACKOFF_MS;
        remoteReady = false;
        const sleepMs = jitterBackoff(backoff);
        // A workload whose credential Salix refuses is not current (its Workload's generation advanced): it stops.
        if (error instanceof AuthError && cfg.workloadCredential) {
          status.writeStatus("auth_required", "", error);
          return yield* Effect.fail(new Error(`workload credential rejected: ${error.message}`));
        }
        if (error instanceof AuthError) {
          // A scoped connector is supervised by the app, which re-mints and respawns: a rejected credential ends it.
          if (scope === SCOPE_LOCAL_FILE_READ) {
            status.writeStatus("auth_required", "", error);
            return yield* Effect.fail(new Error(`connector credential rejected for ${SCOPE_LOCAL_FILE_READ} scope: ${error.message}`));
          }
          status.writeStatus("auth_required", "", error, sleepMs);
          backoff = MIN_RECONNECT_BACKOFF_MS;
        } else status.writeStatus("reconnecting", "", error, sleepMs);
        const woke = yield* Effect.raceFirst(Effect.sleep(Duration.millis(sleepMs)).pipe(Effect.as(false)), Deferred.await(fatalSignal).pipe(Effect.as(true)));
        if (woke) return yield* Effect.fail(fatal!);
        backoff = Math.min(backoff * 2, MAX_RECONNECT_BACKOFF_MS);
      }
    }),
  );

  /** A connection over an in-memory socket (tests): served as Salix's connection is. */
  const connectForTest = (options: { window?: number } = {}) =>
    Effect.gen(function* () {
      const toServer = yield* Queue.unbounded<unknown>();
      const toClient = yield* Queue.unbounded<unknown>();
      const credit = options.window === undefined ? null : yield* Semaphore.make(options.window);
      let clientClosed = false;
      let serverClosed = false;
      const END = Symbol("end");
      const serverSocket: FrameSocket = {
        send: (frame) =>
          Effect.gen(function* () {
            if (credit) yield* Semaphore.take(credit, 1);
            if (clientClosed || serverClosed) return yield* Effect.fail(new Error("socket closed"));
            yield* Queue.offer(toClient, JSON.parse(JSON.stringify(frame)));
          }),
        receive: Queue.take(toServer).pipe(Effect.flatMap((f) => (f === END ? Effect.fail(new Error("socket closed")) : Effect.succeed(f)))),
        close: Effect.sync(() => {
          if (serverClosed) return;
          serverClosed = true;
          Queue.offerUnsafe(toClient, END);
          if (credit) Semaphore.releaseAll(credit).pipe(Effect.runSync);
        }),
      };
      const fiber = fork(
        serve(serverSocket).pipe(
          Effect.catch((stuck: unknown) => Effect.sync(() => reportFatal(stuck))),
          Effect.asVoid,
        ),
      );
      const client = {
        send: (frame: Message) => (serverClosed || clientClosed ? Effect.fail(new Error("socket closed")) : Queue.offer(toServer, JSON.parse(JSON.stringify(encodeMessage(frame)))).pipe(Effect.asVoid)),
        read: Queue.take(toClient).pipe(
          Effect.tap(() => (credit ? Semaphore.release(credit, 1) : Effect.void)),
          Effect.flatMap((f) => (f === END ? Effect.fail(new Error("socket closed")) : Effect.succeed(f as Message))),
        ),
        close: Effect.sync(() => {
          if (clientClosed) return;
          clientClosed = true;
          Queue.offerUnsafe(toServer, END);
        }),
        served: fiber,
      };
      yield* Effect.addFinalizer(() => client.close);
      return client;
    });


  const connector = {
    cfg,
    root: () => cfg.root,
    currentScope,
    claimConnection,
    releaseConnection,
    setIdentity,
    connectionIdentity: () => ({ runId: identity.runId, deviceId: identity.deviceId, connectorId: identity.connectorId }),
    localFileConnectionIdentity: () => ({ ...identity }),
    activeConnectionForTest: () => activeConnection,
    connectionWatcherCountForTest: () => connectionWatchers,
    requestSlotsInUse: () => requestSlots,
    bindRequestOperation: (session: Session, msg: Message, fingerprint: string) => bindRequestOperationFor(session, msg, fingerprint).binding,
    completeRequestOperation: (id: string, method: string, reply: Message) => Effect.runFork(completeRequestOperation(id, method, reply)),
    requestOperationForTest: (id: string) => operations.get(id),
    dispatchSession,
    dispatchForTest: (id: string, method: string, params: Record<string, unknown> = {}) =>
      Effect.suspend(() => {
        const session = new Session(host, () => Effect.void);
        return provide(dispatchSession(session, id, method, params)).pipe(Effect.ensuring(Effect.sync(() => session.close("canceled"))));
      }),
    requestReply,
    prepareWriteStream: (session: Session, id: string, params: Record<string, unknown>) => provide(fs.prepareWriteStream(session, id, params)),
    processWrite: (params: Record<string, unknown>) => provide(processes.write(params)),
    processList: () => Effect.succeed(processes.list()),
    lanTcpDial: (session: Session, id: string, params: Record<string, unknown>) => provide(lanTcpDial(session, id, params)),
    registerProcessForTest: (name: string, stdin: ProcessStdin) => {
      const proc = new ManagedProcess(name, stdin, clock.nowMs());
      proc.status = "running";
      processes.register(proc);
    },
    processStdinBusyForTest: (name: string) => processes.processes.get(name)?.stdinBusy ?? false,
    processRunningForTest: (name: string) => processes.processes.get(name)?.isRunning() ?? false,
    setHooksForTest: (next: typeof hooks) => Object.assign(hooks, next),
    enqueueCleanup,
    blockCleanupWorkerForTest: () =>
      Effect.sync(() => {
        cleanupBlocked = Deferred.makeUnsafe<void>();
        const gate = cleanupBlocked;
        return Effect.sync(() => {
          cleanupBlocked = null;
          Deferred.doneUnsafe(gate, Exit.void);
        });
      }),
    connectorFatal: () => fatal,
    nextFatalError: Deferred.await(fatalSignal),
    reportFatal,
    metadata: metadataMessage,
    metadataMessage,
    publishCachedMetadata,
    probeAndPublish: (trigger: string, send: (m: Message) => Effect.Effect<void, unknown>) => provide(probeAndPublish(trigger, send)),
    publishPeriodicSystemInfo: (send: (m: Message) => Effect.Effect<void, unknown>) => send(metadataMessage()),
    systemInfoLoop: (publish: () => Effect.Effect<void, unknown>) => provide(systemInfoLoop(publish)),
    setCurrentScope: (next: string) => provide(setCurrentScope(next)),
    renewCredential,
    watchScopeControl: (input: AsyncIterable<unknown> | NodeJS.ReadableStream) => provide(watchScopeControl(input)),
    connectUrl,
    writeStatus: status.writeStatus,
    writeStatusMetadataSent: status.writeStatusMetadataSent,
    writeStatusLocalRequestError: status.writeStatusLocalRequestError,
    runRemoteOnce,
    runRemote,
    connectForTest,
    extensions,
    transport,
    externalRuntimesEnabled,
    runtimeInventory,
    config: () => cfg,
    meeting,
    meetingJoin: (params: Record<string, unknown>) => provide(meeting.join(params)),
    meetingSendChat: (params: Record<string, unknown>) => provide(meeting.sendChat(params)),
    meetingLeave: (params: Record<string, unknown>) => provide(meeting.leave(params)),
    meetingSessionStatus: (params: Record<string, unknown>) => provide(meeting.sessionStatus(params)),
    deviceAccess: (params: Record<string, unknown>) => provide(deviceAccess(params)),
    clientMcp: (params: Record<string, unknown>) => provide(clientMcp(params)),
    computerUse: (params: Record<string, unknown>) => provide(computerUse.call(params)),
    shutdownComputerUseDaemon: provide(computerUse.shutdown),
    computerUseHelperCommand: (token: string) => provide(computerUse.helperCommand(token)),
    storeComputerUseImage: (response: DaemonResponse) => provide(computerUse.storeImage(response)),
    readComputerUseImage: (name: string) => provide(computerUse.readImage(name)),
    computerUseImageDirectory: provide(computerUse.imageDirectory),
    activateRuntimeTransportForTest: (send: (m: Message) => Effect.Effect<void, unknown>) => {
      const carrier = transport.activate(send);
      return () => void Effect.runFork(provide(transport.revoke(carrier)));
    },
    activeTransportForTest: () => transport.active(),
    revokeRuntimeTransport: (carrier: RuntimeCarrier) => provide(transport.revoke(carrier)),
    completeRuntimeProxy: (msg: Message) => transport.complete(msg),
    registerPendingRuntimeRequestForTest: (id: string) => transport.registerPending(id),
    saturateRuntimeProxySlotsForTest: () => transport.saturateProxySlotsForTest(),
    sendRuntimeProxy: (params: Record<string, unknown>) => provide(transport.proxy(params)),
    connectorHealth,
    localFileImportAvailable,
    deviceSystemInfo,
    nowForTest: () => clock.nowMs(),
    advanceClockForTest: (duration: Duration.Input) => clock.advance(duration),
    sleepsForTest: () => clock.sleeps(),
    provideClockForTest: provide,
    close: () =>
      provide(
        Effect.gen(function* () {
          stopTaskModels();
          stopAccess();
          yield* processes.killAll();
          yield* meeting.close;
          durable?.close();
          for (const closer of abandonedCleanup.splice(0)) yield* closer.close.pipe(Effect.ignore);
        }),
      ),
  };
  return connector;
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  return timingSafeEqual(Buffer.from(left), Buffer.from(right));
}

function randomInstanceId(): string {
  return randomBytes(16).toString("hex");
}

function errorFrom(exit: Exit.Exit<unknown, unknown>): Error {
  const error = Exit.isFailure(exit) ? Cause.squash(exit.cause) : new Error("failed");
  return error instanceof Error ? error : new Error(String(error));
}

function errorMessage(exit: Exit.Exit<unknown, unknown>): string {
  if (Exit.isSuccess(exit)) return "";
  const error = Cause.squash(exit.cause);
  return error instanceof Error ? error.message : String(error);
}

export type Connector = ReturnType<typeof makeConnector>;
export { MAX_OUTPUT_BYTES };

export const SHUTDOWN_REQUEST_POLL_INTERVAL = Duration.millis(50);

/** Completes when the parent's lifeline reaches EOF (the app exited); payload on the lifeline means nothing. */
export function watchParentLifeline(lifeline: NodeJS.ReadableStream): Effect.Effect<void> {
  return Effect.callback<void>((resume) => {
    lifeline.on("data", () => {});
    lifeline.once("end", () => resume(Effect.void));
    lifeline.once("close", () => resume(Effect.void));
    lifeline.once("error", () => resume(Effect.void));
  });
}

/**
 * Completes when the run directory holds a cooperative shutdown request carrying this run's exact nonce (a restarted
 * app's PID-free way to stop the run it found). Writing the file is never proof of exit by itself.
 */
export function watchShutdownRequest(path: string, runNonce: string): Effect.Effect<void> {
  return Effect.gen(function* () {
    while (true) {
      const matched = yield* Effect.promise(async () => {
        try {
          const request = JSON.parse(await readFileAsync(path, "utf8")) as { runNonce?: unknown };
          return request.runNonce === runNonce;
        } catch {
          return false;
        }
      });
      if (matched) return;
      yield* Effect.sleep(SHUTDOWN_REQUEST_POLL_INTERVAL);
    }
  });
}

const permissionRequired = (target: RuntimeTarget): Record<string, unknown> => ({
  kind: "external",
  provider: target.provider,
  command: target.identityMaterial,
  identity_material: target.identityMaterial,
  ready: false,
  status: "unavailable",
  readiness_issue: "permission_required",
  readiness_message: "Set Access to Full in Comma Settings > Devices to use this agent.",
});

/** A standalone device's access from before the computer's value: "" (operations allowed) or local_file_read; null when none was stored. */
function loadDeviceAccess(path: string): string | null {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw error;
  }
  let stored: { scope?: unknown } | null = null;
  try {
    stored = JSON.parse(raw);
  } catch {}
  const value = stored?.scope;
  if (typeof value !== "string" || (value !== "" && value !== SCOPE_LOCAL_FILE_READ)) throw new Error("invalid device access preference; restore device-access.json before starting");
  return value;
}

