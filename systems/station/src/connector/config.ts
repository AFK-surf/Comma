// Connector configuration: defaults, command-line flags and environment (as the Go connector read them, minus the
// removed modes), the desktop app's config file, normalization and validation.
import { readFile } from "node:fs/promises";
import { hostname } from "node:os";
import { join, normalize, resolve } from "node:path";
import { Duration, Effect } from "effect";
import { computerUseSocketPathForRuntime, defaultComputerUseHelperAppPath } from "./computer-use-paths.ts";

export const SCOPE_LOCAL_FILE_READ = "local_file_read";
export const MAX_CONCURRENT_REQUESTS = 16;
export const CLEANUP_QUEUE_SIZE = 64;
export const REQUEST_EXECUTION_TIMEOUT = Duration.minutes(2);

export type ConnectorConfig = {
  configPath: string;
  name: string;
  alias: string;
  root: string;
  server: string;
  token: string;
  statusPath: string;
  reconnect: boolean;
  scope: string;
  runNonce: string;
  parentLifelineFd: number;
  shutdownRequestPath: string;
  localFileIndexRoot: string;
  deviceMode: boolean;
  deviceStateRoot: string;
  externalStateRoot: string;
  deviceWorkspaceId: string;
  runtimeNamespace: string;
  runtimeRoot: string;
  /** Where the station runs from: the Computer Use helper ships beside it. */
  executablePath: string;
  computerUseHelperApp: string;
  computerUseSocketPath: string;
  computerUseRuntimePath: string;
  meetUrl: string;
  meetCallbackHost: string;
  meetCallbackPort: number;
  /** A Compute Workload's credential (bootstrap at first, short-lived after the first handshake); empty on a device. */
  workloadCredential: string;
  /** The host suffix of the signed object storage URLs archives move through. */
  archiveHostSuffix: string;
  systemInfoInterval: Duration.Duration;
  workspaceArchiveEnabled: boolean;
  workspaceArchiveIdle: Duration.Duration;
  workspaceArchiveRestoreTimeout: Duration.Duration;
  /** The environment the connector and its children see (defaults to the station's own). */
  env: Record<string, string | undefined>;
  testClock: boolean;
  maxConcurrentRequests: number;
  cleanupQueueSize: number;
  runtimeAuthSlots: number;
  runtimeControlSlots: number;
  requestExecutionTimeout: Duration.Duration;
  runtimePingIntervalMs: number;
  imageHarnessCommands: Record<string, string>;
  externalRuntimeCheckInterval: Duration.Duration;
  /** Replaces the runtime implementations (tests); "inert" accepts input and recovers without native state. */
};

export const WORKSPACE_ARCHIVE_IDLE_DEFAULT = Duration.hours(24);
export const WORKSPACE_ARCHIVE_RESTORE_TIMEOUT_DEFAULT = Duration.minutes(10);

export function defaultConfig(env: Record<string, string | undefined> = process.env as Record<string, string | undefined>): ConnectorConfig {
  return {
    configPath: "",
    name: "",
    alias: "",
    root: process.cwd(),
    server: "",
    token: "",
    statusPath: "",
    reconnect: false,
    scope: "",
    runNonce: "",
    parentLifelineFd: -1,
    shutdownRequestPath: "",
    localFileIndexRoot: "",
    deviceMode: false,
    deviceStateRoot: "",
    externalStateRoot: "",
    deviceWorkspaceId: "",
    runtimeNamespace: "",
    runtimeRoot: "",
    executablePath: process.execPath,
    computerUseHelperApp: "",
    computerUseSocketPath: "",
    computerUseRuntimePath: "",
    meetUrl: "",
    meetCallbackHost: "",
    meetCallbackPort: 0,
    workloadCredential: "",
    archiveHostSuffix: ".r2.cloudflarestorage.com",
    systemInfoInterval: Duration.zero,
    workspaceArchiveEnabled: false,
    workspaceArchiveIdle: WORKSPACE_ARCHIVE_IDLE_DEFAULT,
    workspaceArchiveRestoreTimeout: WORKSPACE_ARCHIVE_RESTORE_TIMEOUT_DEFAULT,
    env,
    testClock: false,
    maxConcurrentRequests: MAX_CONCURRENT_REQUESTS,
    cleanupQueueSize: CLEANUP_QUEUE_SIZE,
    runtimeAuthSlots: 4,
    runtimeControlSlots: 4,
    requestExecutionTimeout: REQUEST_EXECUTION_TIMEOUT,
    runtimePingIntervalMs: 0,
    imageHarnessCommands: {},
    externalRuntimeCheckInterval: Duration.seconds(10),
  };
}

type FlagSpec = { key: keyof ConnectorConfig | "systemInfoIntervalSeconds" | "workspaceArchiveIdleSeconds" | "workspaceArchiveRestoreTimeoutSeconds"; kind: "string" | "int" | "bool"; env?: string };

/** The station's flags: the Go connector's, without the removed --stdio, --vm-server, Android and retired flags. */
const FLAGS: Record<string, FlagSpec> = {
  config: { key: "configPath", kind: "string", env: "SALIX_CONNECTOR_CONFIG" },
  "run-nonce": { key: "runNonce", kind: "string", env: "SALIX_CONNECTOR_RUN_NONCE" },
  "parent-lifeline-fd": { key: "parentLifelineFd", kind: "int", env: "SALIX_CONNECTOR_PARENT_LIFELINE_FD" },
  "shutdown-request-file": { key: "shutdownRequestPath", kind: "string", env: "SALIX_CONNECTOR_SHUTDOWN_REQUEST_FILE" },
  "workspace-archive": { key: "workspaceArchiveEnabled", kind: "bool", env: "SALIX_WORKSPACE_ARCHIVE" },
  server: { key: "server", kind: "string", env: "SALIX_SERVER" },
  "connector-token": { key: "token", kind: "string", env: "SALIX_CONNECTOR_TOKEN" },
  "status-file": { key: "statusPath", kind: "string", env: "SALIX_CONNECTOR_STATUS_FILE" },
  name: { key: "name", kind: "string", env: "SALIX_CONNECTOR_NAME" },
  alias: { key: "alias", kind: "string", env: "SALIX_CONNECTOR_ALIAS" },
  root: { key: "root", kind: "string", env: "SALIX_CONNECTOR_ROOT" },
  "state-root": { key: "externalStateRoot", kind: "string" },
  reconnect: { key: "reconnect", kind: "bool" },
  scope: { key: "scope", kind: "string", env: "SALIX_CONNECTOR_SCOPE" },
  "local-file-index": { key: "localFileIndexRoot", kind: "string", env: "SALIX_LOCAL_FILE_INDEX" },
  "meet-url": { key: "meetUrl", kind: "string", env: "SALIX_MEET_URL" },
  "meet-callback-host": { key: "meetCallbackHost", kind: "string", env: "SALIX_MEET_CALLBACK_HOST" },
  "meet-callback-port": { key: "meetCallbackPort", kind: "int", env: "SALIX_MEET_CALLBACK_PORT" },
  "workload-credential": { key: "workloadCredential", kind: "string", env: "SALIX_WORKLOAD_CREDENTIAL" },
  "system-info-interval": { key: "systemInfoIntervalSeconds", kind: "int", env: "SALIX_CONNECTOR_SYSTEM_INFO_INTERVAL" },
  "workspace-archive-idle-seconds": { key: "workspaceArchiveIdleSeconds", kind: "int", env: "SALIX_WORKSPACE_ARCHIVE_IDLE_SECONDS" },
  "workspace-archive-restore-timeout-seconds": { key: "workspaceArchiveRestoreTimeoutSeconds", kind: "int", env: "SALIX_WORKSPACE_ARCHIVE_RESTORE_TIMEOUT_SECONDS" },
  device: { key: "deviceMode", kind: "bool" },
};

const parseBool = (value: string) => ["1", "t", "true", "y", "yes", "on"].includes(value.trim().toLowerCase());

/** Flags (`--name value`, `--name=value`, `-name`), then environment, then defaults. Returns the explicitly set flags. */
export function parseArgs(argv: string[], env: Record<string, string | undefined>): { cfg: ConnectorConfig; explicit: Set<string> } {
  const cfg = defaultConfig(env);
  cfg.name = env.SALIX_CONNECTOR_NAME ?? hostname();
  cfg.root = env.SALIX_CONNECTOR_ROOT ?? ".";
  cfg.reconnect = true;
  cfg.workspaceArchiveEnabled = env.SALIX_WORKSPACE_ARCHIVE === undefined ? true : parseBool(env.SALIX_WORKSPACE_ARCHIVE);
  let systemInfoSeconds = 300;
  let idleSeconds = Duration.toSeconds(WORKSPACE_ARCHIVE_IDLE_DEFAULT);
  let restoreSeconds = Duration.toSeconds(WORKSPACE_ARCHIVE_RESTORE_TIMEOUT_DEFAULT);
  const assign = (spec: FlagSpec, raw: string) => {
    const value = spec.kind === "int" ? Number.parseInt(raw, 10) : spec.kind === "bool" ? parseBool(raw) : raw;
    if (spec.kind === "int" && !Number.isFinite(value as number)) throw new Error(`invalid value ${JSON.stringify(raw)} for an integer flag`);
    if (spec.key === "systemInfoIntervalSeconds") systemInfoSeconds = value as number;
    else if (spec.key === "workspaceArchiveIdleSeconds") idleSeconds = value as number;
    else if (spec.key === "workspaceArchiveRestoreTimeoutSeconds") restoreSeconds = value as number;
    else (cfg as Record<string, unknown>)[spec.key] = value;
  };
  for (const [name, spec] of Object.entries(FLAGS)) {
    if (spec.env && env[spec.env] !== undefined && name !== "workspace-archive") assign(spec, env[spec.env]!);
  }
  const explicit = new Set<string>();
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith("-")) throw new Error(`unexpected argument ${JSON.stringify(arg)}`);
    const body = arg.replace(/^--?/, "");
    const [name, inline] = body.includes("=") ? [body.slice(0, body.indexOf("=")), body.slice(body.indexOf("=") + 1)] : [body, undefined];
    const spec = FLAGS[name];
    if (!spec) throw new Error(`flag provided but not defined: -${name}`);
    let raw = inline;
    if (raw === undefined) raw = spec.kind === "bool" ? "true" : argv[++i];
    if (raw === undefined) throw new Error(`flag needs an argument: -${name}`);
    assign(spec, raw);
    explicit.add(name);
  }
  cfg.systemInfoInterval = Duration.seconds(Math.max(systemInfoSeconds, 0));
  cfg.workspaceArchiveIdle = Duration.seconds(idleSeconds > 0 ? idleSeconds : Duration.toSeconds(WORKSPACE_ARCHIVE_IDLE_DEFAULT));
  cfg.workspaceArchiveRestoreTimeout = Duration.seconds(restoreSeconds > 0 ? restoreSeconds : Duration.toSeconds(WORKSPACE_ARCHIVE_RESTORE_TIMEOUT_DEFAULT));
  return { cfg, explicit };
}

type FileConfig = {
  connector?: {
    device?: boolean;
    device_state_root?: string;
    workspace_id?: string;
    server?: string;
    connector_token?: string;
    name?: string;
    alias?: string;
    root?: string;
    reconnect?: boolean;
    scope?: string;
  };
  status?: { path?: string };
  electron?: { local_file_index_root?: string; run_nonce?: string; runtime_namespace?: string; runtime_root?: string; bin_dir?: string; computer_use_helper_app?: string; env?: Record<string, string> };
};

/** The desktop app's config file: fills what the command line did not set; a mismatched run nonce is refused. */
export function applyConfigFile(cfg: ConnectorConfig, explicit: Set<string>): Effect.Effect<void, Error> {
  return Effect.gen(function* () {
    const raw = yield* Effect.tryPromise({ try: () => readFile(cfg.configPath, "utf8"), catch: (e) => new Error(`read --config: ${String(e)}`) });
    const file = yield* Effect.try({ try: () => JSON.parse(raw) as FileConfig, catch: (e) => new Error(`decode --config: ${String(e)}`) });
    const conn = file.connector ?? {};
    if (file.status?.path && !explicit.has("status-file")) cfg.statusPath = file.status.path;
    if (conn.server && !explicit.has("server")) cfg.server = conn.server;
    if (conn.connector_token && !explicit.has("connector-token")) cfg.token = conn.connector_token;
    if (conn.name && !explicit.has("name")) cfg.name = conn.name;
    if (conn.alias && !explicit.has("alias")) cfg.alias = conn.alias;
    if (conn.root && !explicit.has("root")) cfg.root = conn.root;
    if (typeof conn.reconnect === "boolean" && !explicit.has("reconnect")) cfg.reconnect = conn.reconnect;
    if (conn.scope && !explicit.has("scope")) cfg.scope = conn.scope;
    if (!explicit.has("device")) cfg.deviceMode = conn.device === true;
    cfg.deviceStateRoot = conn.device_state_root ?? "";
    cfg.deviceWorkspaceId = conn.workspace_id ?? "";
    const electron = file.electron ?? {};
    if (electron.local_file_index_root && !explicit.has("local-file-index")) cfg.localFileIndexRoot = electron.local_file_index_root;
    if (electron.runtime_namespace) cfg.runtimeNamespace = electron.runtime_namespace;
    if (electron.runtime_root) cfg.runtimeRoot = electron.runtime_root;
    // The app carries the Computer Use helper beside its own native parts, not beside the station's Node.
    if (electron.computer_use_helper_app) cfg.computerUseHelperApp = electron.computer_use_helper_app;
    // The app's commands for the agents (`comma`, `synch`): first on the PATH of what this connection runs.
    // What the app gives the agents' commands (its control endpoint, the synch node): this connection's alone.
    if (electron.env) cfg.env = { ...cfg.env, ...Object.fromEntries(Object.entries(electron.env).filter(([, v]) => typeof v === "string")) };
    if (electron.bin_dir) cfg.env = { ...cfg.env, PATH: [electron.bin_dir, cfg.env.PATH].filter(Boolean).join(":") };
    const fileNonce = (electron.run_nonce ?? "").trim();
    if (fileNonce) {
      if (explicit.has("run-nonce") && cfg.runNonce.trim() !== fileNonce) return yield* Effect.fail(new Error("--run-nonce does not match electron.run_nonce in config"));
      if (!explicit.has("run-nonce")) cfg.runNonce = fileNonce;
    }
  });
}

/** Trims and fills derived values; an unknown scope never widens to full capability. */
export function normalizeConfig(cfg: ConnectorConfig): void {
  cfg.server = cfg.server.trim();
  cfg.token = cfg.token.trim();
  cfg.runNonce = cfg.runNonce.trim().toLowerCase();
  cfg.shutdownRequestPath = cfg.shutdownRequestPath.trim();
  cfg.statusPath = cfg.statusPath.trim();
  if (!cfg.statusPath && cfg.configPath) cfg.statusPath = `${cfg.configPath}.status.json`;
  cfg.scope = cfg.scope.trim();
  if (cfg.scope !== "" && cfg.scope !== SCOPE_LOCAL_FILE_READ) throw new Error(`unknown connector scope ${JSON.stringify(cfg.scope)}; supported: ${JSON.stringify(SCOPE_LOCAL_FILE_READ)}`);
  if (cfg.scope === SCOPE_LOCAL_FILE_READ && !cfg.deviceMode && !cfg.localFileIndexRoot.trim()) throw new Error("scope local_file_read requires a local file index root");
  cfg.runtimeNamespace = cfg.runtimeNamespace.trim();
  cfg.runtimeRoot = cfg.runtimeRoot.trim();
  cfg.computerUseHelperApp = cfg.computerUseHelperApp.trim() || defaultComputerUseHelperAppPath(cfg.executablePath);
  cfg.computerUseSocketPath = cfg.computerUseSocketPath.trim() || computerUseSocketPathForRuntime(cfg.runtimeNamespace, cfg.runtimeRoot);
  cfg.computerUseRuntimePath = cfg.computerUseRuntimePath.trim();
  if (!cfg.computerUseRuntimePath && cfg.runtimeRoot) cfg.computerUseRuntimePath = join(cfg.runtimeRoot, "computer-use");
  cfg.localFileIndexRoot = cfg.localFileIndexRoot.trim();
  if (cfg.localFileIndexRoot) cfg.localFileIndexRoot = normalize(resolve(cfg.localFileIndexRoot));
}

const RUN_NONCE = /^[a-f0-9]{32}$/;
export const validRunNonce = (nonce: string) => RUN_NONCE.test(nonce.trim().toLowerCase());

/** A local-file-read connector started by the app must carry its run identity, one lifeline and a shutdown file. */
export function validateConfig(cfg: Partial<ConnectorConfig>): void {
  if (cfg.scope !== SCOPE_LOCAL_FILE_READ || cfg.deviceMode) return;
  if (!validRunNonce(cfg.runNonce ?? "")) throw new Error("scope local_file_read requires a 128-bit hexadecimal run nonce");
  if ((cfg.parentLifelineFd ?? -1) < 3) throw new Error("scope local_file_read requires exactly one parent lifeline");
  if (!cfg.shutdownRequestPath) throw new Error("scope local_file_read requires a cooperative shutdown request file");
}
