import { spawn } from "node:child_process";
import { execFile } from "node:child_process";
import { createWriteStream, existsSync } from "node:fs";
import {
  mkdir,
  readFile,
  readdir,
  readlink,
  realpath,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { createHash, randomBytes } from "node:crypto";
import { createServer, type Server, type Socket } from "node:net";
import { join, posix, win32 } from "node:path";
import { CommaApiError, createCommaApi } from "@comma/app/api";
import { sessionExpectation } from "@comma/session-contract";
import { z } from "zod";
import type { LocalFileRegistrationTarget } from "../local-files/registration";
import type { MainProductCredentialLease } from "../session/main-product-credential-authority";
import {
  createMainSessionFetch,
  type MainSessionTransportAuthority,
} from "../session/main-session-transport";

const CONNECTOR_READY_TIMEOUT_MS = 12_000;
const CONNECTOR_STATUS_POLL_MS = 150;
const CONNECTOR_WATCHDOG_INTERVAL_MS = 30_000;
const CONNECTOR_STOP_GRACE_MS = 1_000;
const CONNECTOR_BACKOFF_MS = [500, 2_000, 8_000, 30_000] as const;
const MAX_CONCURRENT_WORKSPACE_CONNECTORS = 3;
const CONNECTOR_TOKEN_TTL_SECONDS = 2 * 60 * 60;
const CONNECTOR_REVOKE_TIMEOUT_MS = 5_000;
// Legacy runs created before nonce evidence use pid as a lookup hint and then
// verify exact executable path plus process start time. Current runs are
// recovered by exact executable/config/nonce identity instead, including the
// pre-pid crash window.
const ORPHAN_START_TIME_TOLERANCE_MS = 10_000;

/** The capability scope minted for attachment connectors; see docs/tools-integrations.md. */
const LOCAL_FILE_READ_SCOPE = "local_file_read";
export type ConnectorScope = "" | typeof LOCAL_FILE_READ_SCOPE;

export interface WorkspaceConnectorScopeState {
  available: boolean;
  scope: ConnectorScope;
  workspaceId: string;
  deviceId?: string;
}

export interface WorkspaceConnectorScopeSnapshot {
  revision: number;
  scopes: WorkspaceConnectorScopeState[];
}

// Modeled in tla/connector/ConnectorProcessContainment.tla: pre-spawn
// evidence, parent lifeline, nonce shutdown, two independent confirmations,
// and the evidence-deletion gate are one Main-owned recovery protocol.

/**
 * The exact status file the salix-connect binary maintains next to its config.
 * Liveness is never inferred from this file alone: a target is valid only for
 * a currently supervised child whose status was written after that spawn.
 */
const connectorStatusFileSchema = z.object({
  connector_run_id: z.string().trim().min(1).optional(),
  device_id: z.string().trim().min(1).optional(),
  last_error_class: z.string().optional(),
  last_error_message: z.string().optional(),
  local_file_index_version: z.number().int().positive().optional(),
  state: z.string().trim().min(1).optional(),
  scope: z.union([z.literal(""), z.literal(LOCAL_FILE_READ_SCOPE)]).optional(),
  updated_at: z.number().int().positive().optional(),
});

type ConnectorStatusFile = z.output<typeof connectorStatusFileSchema>;

const connectorPidFileSchema = z.object({
  binaryPath: z.string().min(1),
  configPath: z.string().min(1).optional(),
  pid: z.number().int().positive(),
  runNonce: z
    .string()
    .regex(/^[a-f0-9]{32}$/)
    .optional(),
  shutdownRequestPath: z.string().min(1).optional(),
  startedAtMs: z.number().int().positive(),
  workspaceId: z.string().min(1).optional(),
});

/**
 * Written BEFORE the token-bearing config and therefore before any child can
 * exist: at every crash point, a run directory holding a credential also
 * holds the workspace identity needed to revoke it. The PID file (written
 * after spawn) can never be the only recovery evidence.
 */
const connectorRunEvidenceSchema = z.object({
  binaryPath: z.string().min(1),
  configPath: z.string().min(1).optional(),
  credentialContainedAtMs: z.number().int().positive().optional(),
  preparedAtMs: z.number().int().positive(),
  processAbsentAtMs: z.number().int().positive().optional(),
  runNonce: z
    .string()
    .regex(/^[a-f0-9]{32}$/)
    .optional(),
  shutdownRequestPath: z.string().min(1).optional(),
  workspaceId: z.string().min(1),
});

const connectorConfigTokenSchema = z.object({
  connector: z.object({ connector_token: z.string().min(1) }).loose(),
});

const connectorDeviceFileSchema = z.object({
  deviceId: z.string().trim().min(1),
});

const connectorScopePreferenceSchema = z.strictObject({
  scope: z.union([z.literal(""), z.literal(LOCAL_FILE_READ_SCOPE)]),
  version: z.literal(1),
});

export interface ConnectorChildLike {
  readonly pid?: number | undefined;
  once(event: "exit", listener: () => void): unknown;
  /** Closes Main's stable parent-lifeline endpoint; never signals a numeric pid. */
  requestStop(): void;
  /** Sends a run-nonce-bound command through this child's private stdin. */
  setScope(scope: ConnectorScope): Promise<void> | void;
}

export type SpawnConnectorChild = (input: {
  binaryPath: string;
  clientControl?: { endpoint: string; token: string } | undefined;
  cliDir: string;
  configPath: string;
  logPath: string;
  parentLifelineFd: 3;
  runNonce: string;
  shutdownRequestPath: string;
  synchDataDir?: string | undefined;
}) => ConnectorChildLike;

export interface ConnectorSpawnPlan {
  args: string[];
  lifeline: { fd: 3; kind: "fd" } | { kind: "named_pipe"; pipePath: string };
  stdio: Array<"ignore" | "pipe">;
}

export type InspectProcess = (
  pid: number
) => Promise<{ command: string; startedAtMs: number | undefined } | null>;

export interface ConnectorProcessInfo {
  commandLine: string;
  executablePath: string;
  pid: number;
  startedAtMs: number | undefined;
}

export interface ConnectorProcessSnapshot {
  /** False means absence is not proven and run evidence must be retained. */
  complete: boolean;
  processes: ConnectorProcessInfo[];
}

export type EnumerateConnectorProcesses = (identity: {
  runNonce: string;
}) => Promise<ConnectorProcessSnapshot>;

export type PersistConnectorContainmentEvidence = (
  path: string,
  evidence: z.output<typeof connectorRunEvidenceSchema>
) => Promise<void>;

export type PersistConnectorPidEvidence = (
  path: string,
  evidence: z.output<typeof connectorPidFileSchema>
) => Promise<void>;

export interface WorkspaceConnectorRuntimeLike {
  close(): Promise<void>;
  prewarm(workspaceId: string): void;
  recycle(workspaceId: string): void;
  scopeSnapshot(): WorkspaceConnectorScopeSnapshot;
  scope(workspaceId: string): Promise<WorkspaceConnectorScopeState>;
  setScope(
    workspaceId: string,
    scope: ConnectorScope
  ): Promise<WorkspaceConnectorScopeState>;
  registrationTarget(
    workspaceId: string,
    options?: { signal?: AbortSignal }
  ): Promise<LocalFileRegistrationTarget | null>;
  resumeContainment?(): void;
  copyConnectCommand?(
    workspaceId: string,
    copy: (text: string) => Promise<void> | void
  ): Promise<void>;
}

export interface WorkspaceConnectorRuntimeOptions {
  /**
   * Resolved salix-connect binary path. Undefined means the runtime is
   * unavailable and every target resolution fails closed immediately.
   */
  binaryPath: string | undefined;
  /** Resolved lazily because the Main-owned loopback server opens later in bootstrap. */
  clientControl?: (() => { endpoint: string; token: string } | undefined) | undefined;
  /** Filesystem root the connector serves; the user's home in production. */
  connectorFileRoot: string;
  /** Private per-workspace state root, e.g. `<userData>/connectors`. */
  connectorsRootDir: string;
  /** Stable release namespace passed to salix-connect without re-resolving flavor. */
  runtimeNamespace?: string | undefined;
  /** Electron-owned runtime root passed to salix-connect as its path pointer. */
  runtimeRoot?: string | undefined;
  /** Bundled CLI exposed to env.exec through each connector's private bin. */
  synchBinaryPath?: string | undefined;
  /** Comma-owned node selected when the CLI receives no explicit --data-dir. */
  synchDataDir?: string | undefined;
  enumerateProcesses?: EnumerateConnectorProcesses;
  fetch?: typeof fetch | undefined;
  inspectProcess?: InspectProcess;
  /** Must be the exact index root the local-file snapshot store writes. */
  localFileIndexRoot: string;
  log?: {
    info(message: string): void;
    warn(message: string): void;
  };
  backoffScheduleMs?: readonly number[];
  maxWorkspaces?: number;
  onScopeStateChanged?:
    | ((snapshot: WorkspaceConnectorScopeSnapshot) => void)
    | undefined;
  persistContainmentEvidence?: PersistConnectorContainmentEvidence;
  /** Narrow crash-window seam; production persists the PID record directly. */
  persistPidEvidence?: PersistConnectorPidEvidence;
  /** Injectable only to exercise native path semantics on non-native CI hosts. */
  processPlatform?: NodeJS.Platform;
  readyTimeoutMs?: number;
  session: MainSessionTransportAuthority;
  spawnConnector?: SpawnConnectorChild;
  /**
   * Test/E2E-only static mode: resolve every workspace target from this
   * legacy status file and never mint tokens or spawn processes.
   */
  staticStatusFilePath?: string | undefined;
  statusPollIntervalMs?: number;
  stopGraceMs?: number;
  tokenTtlSeconds?: number;
  watchdogIntervalMs?: number;
}

type EntryPhase = "starting" | "connected" | "backoff" | "stopped";

interface WorkspaceConnectorEntry {
  child: ConnectorChildLike | undefined;
  childExited: boolean;
  configPath: string;
  credential: MainProductCredentialLease;
  exited: Promise<void> | undefined;
  lastError: string | undefined;
  lastUsedAtMs: number;
  logPath: string;
  loop: Promise<void>;
  mintedToken: string | undefined;
  /** Local clock when `mintedToken` was issued; bounds its requested TTL. */
  mintedAtMs: number | undefined;
  /** The connector reported that the server refuses `mintedToken`. */
  mintedTokenRejected: boolean;
  phase: EntryPhase;
  pidPath: string;
  recycleRequested: boolean;
  runDir: string;
  spawnedAtMs: number;
  statusPath: string;
  shutdownRequestPath: string;
  stopController: AbortController;
  stopRequested: boolean;
  waiters: Set<() => void>;
  waitingCount: number;
  workspaceDir: string;
  workspaceId: string;
  runNonce: string;
  desiredScope: ConnectorScope;
}

function requestEntryStop(entry: WorkspaceConnectorEntry) {
  entry.stopRequested = true;
  entry.stopController.abort();
  notifyEntry(entry);
}

export interface WorkspaceConnectorEntryState {
  phase: EntryPhase;
  lastError: string | undefined;
  pid: number | undefined;
  workspaceId: string;
}

/**
 * Electron Main's owner for per-workspace salix-connect processes.
 *
 * Ownership and containment invariants:
 * - Runtime state lives under this app's own userData in a per-workspace
 *   directory. Each supervised entry gets a fresh `runs/<runId>` directory
 *   for its config/status/pid/log, so a replaced or evicted supervisor can
 *   only ever delete its own generation's files — never a successor's.
 * - Device identity is durable per workspace (`device.json`) and re-attached
 *   at every mint, so credential rotation never strands routes that were
 *   registered against the stable device.
 * - Every minted credential is full and short-lived. The user's per-workspace
 *   scope choice is stored outside generation-owned run directories and is
 *   applied to every replacement child. Missing state allows operations by
 *   default. Malformed or unreadable state restricts access to `local_file_read`.
 * - The Session credential lease is the event-driven local supervisor stop
 *   trigger: lease abort stops the entry immediately, and teardown revokes
 *   the minted credential while any authorized Session is available. An
 *   expired credential the server already refused is forgotten after two
 *   failed revocations; the server's generation fence and pending stop
 *   target remain authoritative for it. The durable server admission fence
 *   remains the Registry credential generation.
 * - Orphan reaping never sends a nonzero signal to a numeric pid. Current
 *   runs stop through an exact-nonce request and parent lifeline, then require
 *   a fresh complete native scan before process absence becomes durable.
 */
export class WorkspaceConnectorRuntimeService implements WorkspaceConnectorRuntimeLike {
  readonly #backoffScheduleMs: readonly number[];
  readonly #binaryPath: string | undefined;
  #closed = false;
  readonly #connectorFileRoot: string;
  readonly #clientControl:
    | (() => { endpoint: string; token: string } | undefined)
    | undefined;
  readonly #connectorsRootDir: string;
  readonly #entries = new Map<string, WorkspaceConnectorEntry>();
  readonly #enumerateProcesses: EnumerateConnectorProcesses;
  readonly #fetch: typeof fetch | undefined;
  readonly #inspectProcess: InspectProcess;
  readonly #localFileIndexRoot: string;
  readonly #log: { info(message: string): void; warn(message: string): void };
  readonly #loops = new Set<Promise<void>>();
  readonly #maxWorkspaces: number;
  readonly #onScopeStateChanged:
    | ((snapshot: WorkspaceConnectorScopeSnapshot) => void)
    | undefined;
  readonly #persistContainmentEvidence: PersistConnectorContainmentEvidence;
  readonly #persistPidEvidence: PersistConnectorPidEvidence;
  readonly #devicePersistChains = new Map<string, Promise<void>>();
  #orphanSweepIncomplete = false;
  #orphanReap: Promise<void> | undefined;
  readonly #readyTimeoutMs: number;
  readonly #runtimeNamespace: string | undefined;
  readonly #runtimeRoot: string | undefined;
  readonly #processPlatform: NodeJS.Platform;
  readonly #session: MainSessionTransportAuthority;
  readonly #spawnConnector: SpawnConnectorChild;
  readonly #synchBinaryPath: string | undefined;
  readonly #synchDataDir: string | undefined;
  #scopeRevision = 0;
  readonly #scopeStates = new Map<string, WorkspaceConnectorScopeState>();
  readonly #scopeTails = new Map<string, Promise<void>>();
  readonly #staticStatusFilePath: string | undefined;
  readonly #statusPollIntervalMs: number;
  readonly #stopGraceMs: number;
  readonly #tokenTtlSeconds: number;
  readonly #watchdogIntervalMs: number;

  constructor(options: WorkspaceConnectorRuntimeOptions) {
    this.#backoffScheduleMs = options.backoffScheduleMs ?? CONNECTOR_BACKOFF_MS;
    this.#binaryPath = options.binaryPath;
    this.#clientControl = options.clientControl;
    this.#connectorFileRoot = options.connectorFileRoot;
    this.#connectorsRootDir = options.connectorsRootDir;
    this.#processPlatform = options.processPlatform ?? process.platform;
    this.#enumerateProcesses =
      options.enumerateProcesses ??
      enumerateConnectorProcessesNative(this.#processPlatform);
    this.#fetch = options.fetch;
    this.#inspectProcess = options.inspectProcess ?? inspectProcessNative;
    this.#localFileIndexRoot = options.localFileIndexRoot;
    this.#log = options.log ?? { info: () => {}, warn: () => {} };
    this.#maxWorkspaces = options.maxWorkspaces ?? MAX_CONCURRENT_WORKSPACE_CONNECTORS;
    this.#onScopeStateChanged = options.onScopeStateChanged;
    this.#persistContainmentEvidence =
      options.persistContainmentEvidence ?? persistConnectorContainmentEvidence;
    this.#persistPidEvidence =
      options.persistPidEvidence ?? persistConnectorPidEvidence;
    this.#readyTimeoutMs = options.readyTimeoutMs ?? CONNECTOR_READY_TIMEOUT_MS;
    this.#runtimeNamespace = options.runtimeNamespace;
    this.#runtimeRoot = options.runtimeRoot;
    this.#session = options.session;
    this.#spawnConnector = options.spawnConnector ?? spawnConnectorProcess;
    this.#synchBinaryPath = options.synchBinaryPath;
    this.#synchDataDir = options.synchDataDir;
    this.#staticStatusFilePath = options.staticStatusFilePath;
    this.#statusPollIntervalMs =
      options.statusPollIntervalMs ?? CONNECTOR_STATUS_POLL_MS;
    this.#stopGraceMs = options.stopGraceMs ?? CONNECTOR_STOP_GRACE_MS;
    this.#tokenTtlSeconds = options.tokenTtlSeconds ?? CONNECTOR_TOKEN_TTL_SECONDS;
    this.#watchdogIntervalMs =
      options.watchdogIntervalMs ?? CONNECTOR_WATCHDOG_INTERVAL_MS;
    // Orphan recovery must not wait for the first attachment demand: a child
    // that survived a crashed Main is reaped as soon as the runtime exists.
    if (!this.#staticStatusFilePath && this.#binaryPath) {
      this.#orphanReap = this.#runOrphanSweep();
      void this.#orphanReap.catch(() => undefined);
    }
  }

  /**
   * Re-runs orphan containment for a newly signed-in Session. The
   * construction-time sweep usually runs signed-out and cannot revoke
   * credentials server-side; containment is driven by the sign-in
   * transition itself, never deferred to the first attachment demand.
   */
  resumeContainment(): void {
    if (this.#closed || this.#staticStatusFilePath || !this.#binaryPath) {
      return;
    }
    // Unconditional by design: gating on the incomplete flag would race an
    // in-flight construction sweep that has not marked its failure yet.
    // Sign-ins are rare and a sweep over zero stale directories is free.
    this.#orphanSweepIncomplete = false;
    const next = (this.#orphanReap ?? Promise.resolve())
      .catch(() => undefined)
      .then(() => this.#runOrphanSweep());
    this.#orphanReap = next;
    void next.catch(() => undefined);
  }

  state(): WorkspaceConnectorEntryState[] {
    return [...this.#entries.values()].map((entry) => ({
      lastError: entry.lastError,
      phase: entry.phase,
      pid: entry.child?.pid,
      workspaceId: entry.workspaceId,
    }));
  }

  scopeSnapshot(): WorkspaceConnectorScopeSnapshot {
    return {
      revision: this.#scopeRevision,
      scopes: [...this.#scopeStates.values()]
        .toSorted((left, right) => left.workspaceId.localeCompare(right.workspaceId))
        .map((state) => ({ ...state })),
    };
  }

  #publishScopeState(state: WorkspaceConnectorScopeState): void {
    const current = this.#scopeStates.get(state.workspaceId);
    if (
      current?.available === state.available &&
      current.scope === state.scope &&
      current.deviceId === state.deviceId
    ) {
      return;
    }

    if (!current && this.#scopeStates.size >= this.#maxWorkspaces) {
      const staleWorkspaceId = [...this.#scopeStates.keys()].find(
        (workspaceId) => !this.#entries.has(workspaceId)
      );
      if (staleWorkspaceId) this.#scopeStates.delete(staleWorkspaceId);
    }
    this.#scopeStates.set(state.workspaceId, { ...state });
    this.#scopeRevision += 1;
    this.#onScopeStateChanged?.(this.scopeSnapshot());
  }

  #publishEntryScopeState(
    entry: WorkspaceConnectorEntry,
    state: WorkspaceConnectorScopeState
  ): void {
    if (this.#entries.get(entry.workspaceId) !== entry) return;
    this.#publishScopeState(state);
  }

  #forgetEntryScopeState(entry: WorkspaceConnectorEntry): void {
    if (this.#entries.get(entry.workspaceId) !== entry) return;
    if (!this.#scopeStates.delete(entry.workspaceId)) return;
    this.#scopeRevision += 1;
    this.#onScopeStateChanged?.(this.scopeSnapshot());
  }

  prewarm(workspaceId: string): void {
    if (this.#closed || this.#staticStatusFilePath || !this.#binaryPath) return;
    try {
      this.#ensureEntry(workspaceId);
    } catch {
      // Prewarm is advisory; demand-time resolution reports real failures.
    }
  }

  /**
   * Discards the current child and credential for a workspace so the next
   * demand connects with a freshly minted connector token. Used when the
   * server requires connector reconfiguration (e.g. owner upgrade).
   */
  recycle(workspaceId: string): void {
    if (this.#closed) return;
    const entry = this.#entries.get(workspaceId);
    if (!entry) {
      this.prewarm(workspaceId);
      return;
    }
    entry.recycleRequested = true;
    notifyEntry(entry);
  }

  /**
   * Ensures and observes only the explicitly named workspace child. Permission
   * remains workspace-local: a first-use workspace starts restricted, while a
   * replacement child restores that workspace's persisted desired scope.
   */
  async scope(workspaceId: string): Promise<WorkspaceConnectorScopeState> {
    const normalized = workspaceId.trim();
    const unavailable = connectorScopeUnavailable(normalized);
    if (!normalized || this.#closed || !this.#binaryPath) return unavailable;
    if (this.#staticStatusFilePath) {
      const status = await readStatusFile(this.#staticStatusFilePath);
      const state = statusScopeState(normalized, status) ?? unavailable;
      this.#publishScopeState(state);
      return state;
    }
    let entry: WorkspaceConnectorEntry;
    try {
      entry = this.#ensureEntry(normalized);
    } catch {
      return unavailable;
    }
    return this.#waitForScopeState(entry, Date.now() + this.#readyTimeoutMs);
  }

  async setScope(
    workspaceId: string,
    scope: ConnectorScope
  ): Promise<WorkspaceConnectorScopeState> {
    const normalized = workspaceId.trim();
    const unavailable = connectorScopeUnavailable(normalized);
    if (
      !normalized ||
      (scope !== "" && scope !== LOCAL_FILE_READ_SCOPE) ||
      this.#closed ||
      !this.#binaryPath ||
      this.#staticStatusFilePath
    ) {
      return unavailable;
    }
    let resolveResult!: (state: WorkspaceConnectorScopeState) => void;
    let rejectResult!: (error: unknown) => void;
    const result = new Promise<WorkspaceConnectorScopeState>((resolve, reject) => {
      resolveResult = resolve;
      rejectResult = reject;
    });
    const previous = this.#scopeTails.get(normalized) ?? Promise.resolve();
    const operation = previous
      .catch(() => undefined)
      .then(async () => {
        try {
          await this.#persistDesiredScope(normalized, scope);
          const entry = this.#ensureEntry(normalized);
          entry.desiredScope = scope;
          resolveResult(await this.#setEntryScope(entry, scope));
        } catch (error) {
          rejectResult(error);
        }
      });
    this.#scopeTails.set(normalized, operation);
    void operation.finally(() => {
      if (this.#scopeTails.get(normalized) === operation) {
        this.#scopeTails.delete(normalized);
      }
    });
    return result;
  }

  async #setEntryScope(
    entry: WorkspaceConnectorEntry,
    scope: ConnectorScope
  ): Promise<WorkspaceConnectorScopeState> {
    const deadline = Date.now() + this.#readyTimeoutMs;
    const current = await this.#waitForScopeState(entry, deadline);
    if (!current.available || !entry.child || entry.childExited) return current;
    if (current.scope === scope) return current;
    const child = entry.child;
    await child.setScope(scope);

    for (;;) {
      if (
        Date.now() >= deadline ||
        this.#closed ||
        !this.#entryActive(entry) ||
        entry.child !== child ||
        entry.childExited
      ) {
        return connectorScopeUnavailable(entry.workspaceId, entry.desiredScope);
      }
      const state = statusScopeState(
        entry.workspaceId,
        await readStatusFile(entry.statusPath)
      );
      if (state?.available && state.scope === scope) {
        this.#publishEntryScopeState(entry, state);
        return state;
      }
      await waitForEntryChange(entry, this.#statusPollIntervalMs);
    }
  }

  async #waitForScopeState(
    entry: WorkspaceConnectorEntry,
    deadline: number
  ): Promise<WorkspaceConnectorScopeState> {
    for (;;) {
      if (
        Date.now() >= deadline ||
        this.#closed ||
        !this.#entryActive(entry) ||
        entry.credential.signal.aborted
      ) {
        return connectorScopeUnavailable(entry.workspaceId, entry.desiredScope);
      }
      if (entry.child && !entry.childExited) {
        const state = statusScopeState(
          entry.workspaceId,
          await readStatusFile(entry.statusPath)
        );
        if (state?.available) {
          this.#publishEntryScopeState(entry, state);
          return state;
        }
      }
      await waitForEntryChange(entry, this.#statusPollIntervalMs);
    }
  }

  async registrationTarget(
    workspaceId: string,
    options: { signal?: AbortSignal } = {}
  ): Promise<LocalFileRegistrationTarget | null> {
    if (this.#closed) return null;
    if (this.#staticStatusFilePath) {
      return readStatusTarget(this.#staticStatusFilePath);
    }
    if (!this.#binaryPath) return null;

    let entry: WorkspaceConnectorEntry;
    try {
      entry = this.#ensureEntry(workspaceId);
    } catch {
      return null;
    }

    const deadline = Date.now() + this.#readyTimeoutMs;
    entry.waitingCount += 1;
    try {
      for (;;) {
        if (
          this.#closed ||
          options.signal?.aborted ||
          entry.credential.signal.aborted ||
          entry.stopRequested
        ) {
          return null;
        }
        if (entry.phase === "connected" && entry.child && !entry.childExited) {
          const target = await readStatusTarget(entry.statusPath);
          if (target) {
            // The stable device must be durable BEFORE any caller can bind a
            // route to it: a crash after registration but before the write
            // would otherwise strand the committed route's identity.
            await this.#persistDeviceId(entry, target.deviceId);
            entry.lastUsedAtMs = Date.now();
            return target;
          }
        }
        const remaining = deadline - Date.now();
        if (remaining <= 0) return null;
        await waitForEntryChange(
          entry,
          Math.min(remaining, this.#statusPollIntervalMs),
          options.signal
        );
      }
    } finally {
      entry.waitingCount -= 1;
    }
  }

  async close(): Promise<void> {
    if (this.#closed) return;
    this.#closed = true;
    const entries = [...this.#entries.values()];
    this.#entries.clear();
    if (this.#scopeStates.size > 0) {
      this.#scopeStates.clear();
      this.#scopeRevision += 1;
      this.#onScopeStateChanged?.(this.scopeSnapshot());
    }
    for (const entry of entries) requestEntryStop(entry);
    // Also awaits loops of previously evicted/replaced entries that are
    // still tearing their children down.
    await Promise.all([...this.#loops].map((loop) => loop.catch(() => undefined)));
    await Promise.all(
      [...this.#scopeTails.values()].map((operation) =>
        operation.catch(() => undefined)
      )
    );
    await this.#orphanReap?.catch(() => undefined);
  }

  #ensureEntry(workspaceId: string): WorkspaceConnectorEntry {
    const normalized = workspaceId.trim();
    if (!normalized || normalized.length > 160) {
      throw new Error("A concrete workspace is required.");
    }

    const existing = this.#entries.get(normalized);
    if (existing && !existing.stopRequested && !existing.credential.signal.aborted) {
      existing.lastUsedAtMs = Date.now();
      return existing;
    }
    if (existing) {
      this.#forgetEntryScopeState(existing);
      requestEntryStop(existing);
      this.#entries.delete(normalized);
    }

    const credential = this.#acquireCredential();
    if (!credential) {
      throw new Error("No signed-in Session credential is available.");
    }

    this.#evictBeyondCapacity();
    this.#orphanReap ??= this.#runOrphanSweep();
    if (this.#orphanSweepIncomplete) {
      // A previous sweep left stale state behind (no Session credential for
      // revocation, or an uncontainable process). Each new demand — the
      // first one after sign-in included — retries containment.
      this.#orphanSweepIncomplete = false;
      const next = this.#orphanReap
        .catch(() => undefined)
        .then(() => this.#runOrphanSweep());
      this.#orphanReap = next;
      void next.catch(() => undefined);
    }

    const workspaceDir = join(
      this.#connectorsRootDir,
      workspaceStateDirName(normalized)
    );
    // A generation-unique run directory guarantees a stopping predecessor can
    // never race this entry on config/status/pid paths.
    const runDir = join(workspaceDir, "runs", randomBytes(6).toString("hex"));
    const configPath = join(runDir, "connector.json");
    const entry: WorkspaceConnectorEntry = {
      child: undefined,
      childExited: true,
      configPath,
      credential,
      exited: undefined,
      lastError: undefined,
      lastUsedAtMs: Date.now(),
      logPath: join(runDir, "connector.log"),
      loop: Promise.resolve(),
      mintedToken: undefined,
      mintedAtMs: undefined,
      mintedTokenRejected: false,
      phase: "starting",
      pidPath: join(runDir, "connector.pid"),
      recycleRequested: false,
      runNonce: randomBytes(16).toString("hex"),
      runDir,
      desiredScope: LOCAL_FILE_READ_SCOPE,
      spawnedAtMs: 0,
      statusPath: `${configPath}.status.json`,
      shutdownRequestPath: join(runDir, "shutdown-request.json"),
      stopController: new AbortController(),
      stopRequested: false,
      waiters: new Set(),
      waitingCount: 0,
      workspaceDir,
      workspaceId: normalized,
    };
    this.#entries.set(normalized, entry);
    this.#publishEntryScopeState(entry, connectorScopeUnavailable(normalized));
    // The Session lease is the stop authority and it must act immediately —
    // not at the next status poll or watchdog tick.
    credential.signal.addEventListener(
      "abort",
      () => {
        this.#publishEntryScopeState(
          entry,
          connectorScopeUnavailable(normalized, entry.desiredScope)
        );
        requestEntryStop(entry);
      },
      { once: true }
    );
    entry.loop = this.#runEntry(entry).catch((error) => {
      entry.lastError = errorText(error);
      entry.phase = "stopped";
      notifyEntry(entry);
    });
    this.#loops.add(entry.loop);
    void entry.loop.finally(() => this.#loops.delete(entry.loop));
    return entry;
  }

  /**
   * Acquires a Main-held product credential for the current signed-in
   * generation. The returned lease signal aborts on any Session transition.
   */
  #acquireCredential(): MainProductCredentialLease | null {
    const snapshot = this.#session.authority.getSnapshot();
    if (snapshot.phase !== "signed_in") return null;
    return this.#session.authority.acquireProductCredential(
      sessionExpectation(snapshot)
    );
  }

  async #runEntry(entry: WorkspaceConnectorEntry): Promise<void> {
    let backoffStep = 0;
    const binaryPath = this.#binaryPath;
    if (!binaryPath) return;

    while (this.#entryActive(entry)) {
      try {
        if (entry.child && !entry.childExited) {
          const contained = await this.#stopChild(entry);
          if (!contained) {
            entry.phase = "backoff";
            entry.lastError = "The previous connector is still stopping.";
            notifyEntry(entry);
            await waitForEntryChange(entry, this.#backoffDelayMs(backoffStep));
            backoffStep += 1;
            continue;
          }
        }
        entry.phase = "starting";
        entry.recycleRequested = false;
        notifyEntry(entry);

        if (!existsSync(binaryPath)) {
          throw new Error(
            `salix-connect binary was not found at ${binaryPath}. Run pnpm --filter @comma/electron build:native.`
          );
        }
        const executablePath = await realpath(binaryPath);
        const clientControl = this.#clientControl?.();
        if (this.#clientControl && !clientControl) {
          throw new Error("Comma client-control endpoint is not ready.");
        }
        // A superseded credential must not stay redeemable while this entry
        // mints its replacement.
        await this.#retireMintedToken(entry);
        // Recovery evidence FIRST: if any later step crashes Main — after
        // the token became durable or after the child spawned but before
        // its PID landed — the sweep can still revoke by workspace.
        await this.#writeRunEvidence(entry, executablePath);
        const token = await this.#mintConnectorToken(entry);
        entry.mintedToken = token.token;
        entry.mintedAtMs = Date.now();
        entry.mintedTokenRejected = false;
        entry.desiredScope = await this.#readDesiredScope(entry.workspaceDir);
        this.#publishEntryScopeState(
          entry,
          connectorScopeUnavailable(entry.workspaceId, entry.desiredScope)
        );
        await this.#writeConnectorConfig(entry, token);
        const cliDir = await this.#writeClientCLIs(entry, executablePath);
        await rm(entry.statusPath, { force: true });
        // A recycled entry reuses its run nonce, so clear only its own prior
        // cooperative-stop request. Recheck activity immediately before and
        // after the await: a retired owner may never spawn after recovery has
        // begun proving this identity absent.
        if (!this.#entryActive(entry)) {
          throw new Error("Workspace connector entry stopped before spawn.");
        }
        await rm(entry.shutdownRequestPath, { force: true });
        if (!this.#entryActive(entry)) {
          throw new Error("Workspace connector entry stopped before spawn.");
        }

        const child = this.#spawnConnector({
          binaryPath: executablePath,
          clientControl,
          cliDir,
          configPath: entry.configPath,
          logPath: entry.logPath,
          parentLifelineFd: 3,
          runNonce: entry.runNonce,
          shutdownRequestPath: entry.shutdownRequestPath,
          synchDataDir: this.#synchDataDir,
        });
        entry.child = child;
        entry.childExited = false;
        entry.spawnedAtMs = Date.now();
        entry.exited = new Promise<void>((resolve) => {
          child.once("exit", () => {
            entry.childExited = true;
            this.#publishEntryScopeState(
              entry,
              connectorScopeUnavailable(entry.workspaceId, entry.desiredScope)
            );
            notifyEntry(entry);
            resolve();
          });
        });
        await this.#writePidFile(entry, child, executablePath);
        this.#log.info(
          `workspace connector spawned: workspace=${entry.workspaceId} pid=${child.pid ?? "?"}`
        );

        const outcome = await this.#superviseChild(entry, entry.exited);
        if (
          outcome === "unauthorized" ||
          (await this.#statusReportsRejectedCredential(entry))
        ) {
          entry.mintedTokenRejected = true;
        }
        const stopped = await this.#stopChild(entry);
        if (!stopped) {
          if (!this.#entryActive(entry)) break;
          entry.phase = "backoff";
          entry.lastError = "The previous connector is still stopping.";
          notifyEntry(entry);
          await waitForEntryChange(entry, this.#backoffDelayMs(backoffStep));
          backoffStep += 1;
          continue;
        }
        if (!this.#entryActive(entry)) break;

        if (outcome === "connected-exit" || outcome === "recycle") {
          backoffStep = 0;
        }
        if (outcome !== "recycle") {
          entry.phase = "backoff";
          notifyEntry(entry);
          await waitForEntryChange(entry, this.#backoffDelayMs(backoffStep));
          backoffStep += 1;
        }
      } catch (error) {
        entry.lastError = errorText(error);
        this.#log.warn(
          `workspace connector attempt failed: workspace=${entry.workspaceId} ${entry.lastError}`
        );
        const stopped = await this.#stopChild(entry);
        if (!this.#entryActive(entry)) break;
        entry.phase = "backoff";
        notifyEntry(entry);
        await waitForEntryChange(entry, this.#backoffDelayMs(backoffStep));
        backoffStep += 1;
        if (!stopped) continue;
      }
    }

    await this.#stopChild(entry);
    try {
      await this.#retireMintedToken(entry);
      if (!(await this.#recordEntryCredentialContained(entry))) {
        this.#log.warn(
          `workspace connector credential marker remains pending: workspace=${entry.workspaceId}`
        );
      }
    } catch (error) {
      // The token and its config remain the durable retry handle. Finalization
      // must still run the common two-proof reaper, but it may not erase this
      // run directory merely because local supervision ended.
      this.#log.warn(
        `workspace connector final revocation remains pending: workspace=${entry.workspaceId} ${errorText(error)}`
      );
    }
    // Normal teardown and crash recovery share one deletion gate: the stable
    // per-workspace device identity survives, while this generation-unique run
    // directory is removed only after both credential and process containment
    // have been durably recorded. Credential containment is a confirmed
    // revocation, or an expired credential the server already refused.
    if (!(await this.#reapRunDir(entry.runDir))) {
      this.#orphanSweepIncomplete = true;
    }
    entry.phase = "stopped";
    if (this.#entries.get(entry.workspaceId) === entry) {
      this.#forgetEntryScopeState(entry);
      this.#entries.delete(entry.workspaceId);
    }
    notifyEntry(entry);
  }

  /**
   * Waits for the freshly spawned child to reach `connected`, then holds the
   * connection under a slow watchdog. The binary owns its own reconnect
   * backoff, so a slow-to-connect child is never killed here; only exit,
   * token rejection, an explicit recycle, or a stop ends supervision.
   */
  async #superviseChild(
    entry: WorkspaceConnectorEntry,
    exited: Promise<void>
  ): Promise<"connected-exit" | "exit" | "recycle" | "stopped" | "unauthorized"> {
    let connected = false;

    for (;;) {
      if (!this.#entryActive(entry)) return "stopped";
      if (entry.recycleRequested) return "recycle";
      if (entry.childExited) return connected ? "connected-exit" : "exit";

      const status = await readStatusFile(entry.statusPath);
      const scopeState = statusScopeState(entry.workspaceId, status);
      if (scopeState?.available) {
        this.#publishEntryScopeState(entry, scopeState);
      }
      if (status?.state === "auth_required") {
        entry.lastError =
          status.last_error_message ?? "The connector token was rejected.";
        return "unauthorized";
      }
      if (status?.state === "connected" && statusTarget(status)) {
        if (!connected) {
          connected = true;
          entry.phase = "connected";
          entry.lastError = undefined;
          // Persist the device identity only once the run has provably
          // registered it: a device the server never saw must not become
          // durable, or the next mint would request reuse of an identity the
          // registry cannot verify and wedge until the file is removed.
          await this.#persistDeviceId(entry, status.device_id);
          notifyEntry(entry);
          this.#log.info(
            `workspace connector connected: workspace=${entry.workspaceId}`
          );
        }
      } else if (status?.last_error_message) {
        entry.lastError = status.last_error_message;
      }

      const interval = connected
        ? this.#watchdogIntervalMs
        : this.#statusPollIntervalMs;
      await Promise.race([exited, waitForEntryChange(entry, interval)]);
    }
  }

  async copyConnectCommand(
    workspaceId: string,
    copy: (text: string) => Promise<void> | void
  ) {
    const credential = this.#acquireCredential();
    if (!credential) throw new Error("Sign in before adding a device.");
    const api = this.#api(credential);
    const token = requireCompleteToken(
      await api.createConnectorToken(
        workspaceId,
        {
          name: "Comma Connector",
          alias: "device",
          installation: true,
        },
        { signal: credential.signal }
      )
    );
    try {
      credential.signal.throwIfAborted();
      if (!token.install_command)
        throw new Error("Connector installation is unavailable.");
      await copy(token.install_command);
    } catch (error) {
      await api
        .revokeConnectorToken(workspaceId, { token: token.token })
        .catch(() => undefined);
      throw error;
    }
  }

  #api(credential: MainProductCredentialLease) {
    return createCommaApi({
      baseUrl: credential.audience,
      fetch: createMainSessionFetch({
        credential,
        ...(this.#fetch ? { fetch: this.#fetch } : {}),
        session: this.#session,
      }),
      token: credential.token,
    });
  }

  /**
   * Mints a full, short-lived connector credential re-attached to this
   * workspace's stable device identity. Only the server's typed
   * `403 stable_device_unavailable` refusal proves the stored device absent or
   * foreign; then the identity is discarded and a fresh device is minted.
   * Every transient or ambiguous failure preserves it because committed
   * routes still depend on that identity.
   */
  async #mintConnectorToken(entry: WorkspaceConnectorEntry) {
    const api = this.#api(entry.credential);
    const stableDeviceId = await this.#readDeviceId(entry);
    const attrs = {
      expiresInSeconds: this.#tokenTtlSeconds,
      ...(stableDeviceId ? { stableDeviceId } : {}),
    } as const;
    try {
      const token = await api.createConnectorToken(entry.workspaceId, attrs, {
        signal: entry.stopController.signal,
      });
      return requireCompleteToken(token);
    } catch (error) {
      // Only the server's explicit, machine-readable refusal of this exact
      // stable device may discard the stored identity. Committed routes are
      // bound to it, so a transient failure (rate limit, conflict, outage)
      // must keep the identity and retry — losing it would permanently break
      // already-sent attachments.
      if (
        stableDeviceId &&
        error instanceof CommaApiError &&
        error.status === 403 &&
        error.body?.error === "stable_device_unavailable"
      ) {
        await rm(this.#deviceFilePath(entry), { force: true }).catch(() => undefined);
        const token = await api.createConnectorToken(
          entry.workspaceId,
          { expiresInSeconds: this.#tokenTtlSeconds },
          { signal: entry.stopController.signal }
        );
        return requireCompleteToken(token);
      }
      throw error;
    }
  }

  /**
   * Revokes the entry's outstanding connector credential server-side. Runs
   * under whichever Session credential is currently authorized — the entry's
   * own if still current, otherwise a freshly acquired lease (covering
   * generation bumps). Failure — including no signed-in Session — retains the
   * token and throws so the entry backoff retries before it can mint or
   * overwrite a successor config.
   *
   * The retry is bounded by the credential's own lifetime. Once the requested
   * TTL has elapsed AND the connector has reported the server refusing the
   * token, the credential is no longer redeemable by anyone, so an
   * unconfirmed revocation no longer protects anything: the entry drops the
   * handle and mints a replacement. The server keeps its own durable
   * pending-stop record for the retired generation; see
   * systems/ops/connector-recovery.md.
   */
  async #retireMintedToken(entry: WorkspaceConnectorEntry) {
    const token = entry.mintedToken;
    if (!token) return;

    const credential = entry.credential.signal.aborted
      ? this.#acquireCredential()
      : entry.credential;
    if (!credential) {
      throw new Error("No signed-in Session credential is available for revocation.");
    }
    // Server-side revocation first advances the durable credential-generation
    // high-water fence, then confirms the pending owner stop. The operation is
    // safely repeatable, so a transient failure gets one bounded retry here
    // before the caller preserves the durable retry handle.
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        await this.#api(credential).revokeConnectorToken(
          entry.workspaceId,
          { token },
          { signal: AbortSignal.timeout(CONNECTOR_REVOKE_TIMEOUT_MS) }
        );
        this.#log.info(
          `workspace connector token revoked: workspace=${entry.workspaceId}`
        );
        this.#forgetMintedToken(entry, token);
        return;
      } catch (error) {
        this.#log.warn(
          `workspace connector token revocation failed (attempt ${attempt + 1}): workspace=${entry.workspaceId} ${errorText(error)}`
        );
      }
    }
    if (this.#mintedTokenUnredeemable(entry)) {
      this.#log.warn(
        `workspace connector token revocation remains unconfirmed after the credential expired; minting a replacement: workspace=${entry.workspaceId}`
      );
      this.#forgetMintedToken(entry, token);
      return;
    }
    throw new Error(
      `Connector token revocation remains unconfirmed for workspace ${entry.workspaceId}.`
    );
  }

  /**
   * Reads the child's last status once after supervision ends, before the
   * cooperative stop overwrites it. For the `local_file_read` scope the binary
   * writes `auth_required` and exits in the same call, so supervision sees the
   * exit before any poll can read that status; for the unrestricted scope a
   * recycle or stop can preempt the poll while the child backs off. The status
   * file is removed before every spawn, so a report that is present here
   * belongs to the current credential.
   */
  async #statusReportsRejectedCredential(entry: WorkspaceConnectorEntry) {
    const status = await readStatusFile(entry.statusPath);
    if (status?.state !== "auth_required") return false;
    entry.lastError = status.last_error_message ?? "The connector token was rejected.";
    return true;
  }

  #forgetMintedToken(entry: WorkspaceConnectorEntry, token: string) {
    if (entry.mintedToken !== token) return;
    entry.mintedToken = undefined;
    entry.mintedAtMs = undefined;
    entry.mintedTokenRejected = false;
  }

  /**
   * True only when both independent signals agree that the outstanding
   * credential cannot be redeemed: the requested TTL has elapsed on the local
   * clock, and the server itself already refused the token to the connector.
   * A live credential whose revocation cannot be confirmed still blocks.
   */
  #mintedTokenUnredeemable(entry: WorkspaceConnectorEntry) {
    if (!entry.mintedTokenRejected || entry.mintedAtMs === undefined) return false;
    return Date.now() >= entry.mintedAtMs + this.#tokenTtlSeconds * 1_000;
  }

  async #recordEntryCredentialContained(entry: WorkspaceConnectorEntry) {
    try {
      const result = connectorRunEvidenceSchema.safeParse(
        JSON.parse(await readFile(join(entry.runDir, "run.json"), "utf8"))
      );
      if (!result.success) return false;
      if (result.data.credentialContainedAtMs !== undefined) return true;
      const persisted = await this.#persistRunEvidence(entry.runDir, result.data, {
        credentialContainedAtMs: Date.now(),
      });
      return persisted.persisted;
    } catch (error) {
      this.#log.warn(
        `could not record connector credential containment: workspace=${entry.workspaceId} ${errorText(error)}`
      );
      return false;
    }
  }

  #deviceFilePath(entry: WorkspaceConnectorEntry) {
    return join(entry.workspaceDir, "device.json");
  }

  #scopePreferenceFilePath(workspaceDir: string) {
    return join(workspaceDir, "scope.json");
  }

  async #readDesiredScope(workspaceDir: string): Promise<ConnectorScope> {
    try {
      const parsed = connectorScopePreferenceSchema.safeParse(
        JSON.parse(await readFile(this.#scopePreferenceFilePath(workspaceDir), "utf8"))
      );
      return parsed.success ? parsed.data.scope : LOCAL_FILE_READ_SCOPE;
    } catch (error) {
      return isNotFoundError(error) ? "" : LOCAL_FILE_READ_SCOPE;
    }
  }

  async #persistDesiredScope(
    workspaceId: string,
    scope: ConnectorScope
  ): Promise<void> {
    const workspaceDir = join(
      this.#connectorsRootDir,
      workspaceStateDirName(workspaceId)
    );
    await mkdir(workspaceDir, { mode: 0o700, recursive: true });
    const destination = this.#scopePreferenceFilePath(workspaceDir);
    const temporary = `${destination}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
    try {
      await writeFile(temporary, `${JSON.stringify({ scope, version: 1 })}\n`, {
        mode: 0o600,
      });
      await rename(temporary, destination);
    } finally {
      await rm(temporary, { force: true });
    }
  }

  async #readDeviceId(entry: WorkspaceConnectorEntry): Promise<string | undefined> {
    try {
      const parsed = connectorDeviceFileSchema.safeParse(
        JSON.parse(await readFile(this.#deviceFilePath(entry), "utf8"))
      );
      return parsed.success ? parsed.data.deviceId : undefined;
    } catch {
      return undefined;
    }
  }

  async #persistDeviceId(entry: WorkspaceConnectorEntry, deviceId: string | undefined) {
    // Persists are serialized per WORKSPACE, not per entry: a replaced old
    // generation and its successor share device.json, and only a single
    // writer chain with an activity recheck inside the chain guarantees a
    // stale entry can never land its rename after the successor's.
    const previous =
      this.#devicePersistChains.get(entry.workspaceDir) ?? Promise.resolve();
    const chained = previous.then(async () => {
      // Rechecked INSIDE the serialized chain, immediately before the write:
      // a replaced or stopping entry must never write identity.
      if (!deviceId || !this.#entryActive(entry)) return;
      const current = await this.#readDeviceId(entry);
      if (current === deviceId) return;
      if (!this.#entryActive(entry)) return;
      await mkdir(entry.workspaceDir, { mode: 0o700, recursive: true });
      const temporary = `${this.#deviceFilePath(entry)}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
      await writeFile(temporary, `${JSON.stringify({ deviceId })}\n`, { mode: 0o600 });
      await rename(temporary, this.#deviceFilePath(entry));
    });
    this.#devicePersistChains.set(
      entry.workspaceDir,
      chained.catch(() => undefined)
    );
    return chained;
  }

  async #writeConnectorConfig(
    entry: WorkspaceConnectorEntry,
    token: {
      alias?: string | undefined;
      name?: string | undefined;
      server: string;
      token: string;
    }
  ) {
    await mkdir(entry.runDir, { mode: 0o700, recursive: true });
    const config = {
      connector: {
        alias: token.alias ?? "comma",
        connector_token: token.token,
        name: token.name ?? "Comma Desktop",
        reconnect: true,
        root: this.#connectorFileRoot,
        scope: entry.desiredScope,
        device: true,
        device_state_root: entry.workspaceDir,
        workspace_id: entry.workspaceId,
        server: token.server,
      },
      electron: {
        local_file_index_root: this.#localFileIndexRoot,
        run_nonce: entry.runNonce,
        ...(this.#runtimeNamespace
          ? { runtime_namespace: this.#runtimeNamespace }
          : {}),
        ...(this.#runtimeRoot ? { runtime_root: this.#runtimeRoot } : {}),
      },
    };
    const temporary = `${entry.configPath}.${process.pid}.tmp`;
    await writeFile(temporary, `${JSON.stringify(config, null, 2)}\n`, {
      mode: 0o600,
    });
    await rename(temporary, entry.configPath);
  }

  async #writeClientCLIs(entry: WorkspaceConnectorEntry, binaryPath: string) {
    const cliDir = join(entry.runDir, "bin");
    await mkdir(cliDir, { mode: 0o700, recursive: true });
    const windows = this.#processPlatform === "win32";
    const commaPath = join(cliDir, windows ? "comma.cmd" : "comma");
    const commaSource = windows
      ? `@echo off\r\n"${binaryPath.replaceAll("%", "%%")}" comma-client %*\r\n`
      : `#!/bin/sh\nexec ${shellQuote(binaryPath)} comma-client "$@"\n`;
    await writeFile(commaPath, commaSource, { mode: 0o700 });
    if (this.#synchBinaryPath) {
      if (!existsSync(this.#synchBinaryPath)) {
        throw new Error(
          `synch binary was not found at ${this.#synchBinaryPath}; env.exec cannot be started safely.`
        );
      }
      const synchPath = join(cliDir, windows ? "synch.cmd" : "synch");
      const synchSource = windows
        ? `@echo off\r\n"${this.#synchBinaryPath.replaceAll("%", "%%")}" %*\r\n`
        : `#!/bin/sh\nexec ${shellQuote(this.#synchBinaryPath)} "$@"\n`;
      await writeFile(synchPath, synchSource, { mode: 0o700 });
    }
    return cliDir;
  }

  async #writeRunEvidence(entry: WorkspaceConnectorEntry, binaryPath: string) {
    try {
      await mkdir(entry.runDir, { recursive: true });
      await writeFile(
        join(entry.runDir, "run.json"),
        `${JSON.stringify({
          binaryPath,
          configPath: entry.configPath,
          preparedAtMs: Date.now(),
          runNonce: entry.runNonce,
          shutdownRequestPath: entry.shutdownRequestPath,
          workspaceId: entry.workspaceId,
        })}\n`,
        { mode: 0o600 }
      );
    } catch (error) {
      // Without durable workspace evidence a crash could strand a
      // revocable credential with no way to name it. Abort the attempt
      // before any token becomes durable.
      throw new Error(`could not record connector run evidence: ${errorText(error)}`, {
        cause: error,
      });
    }
  }

  async #writePidFile(
    entry: WorkspaceConnectorEntry,
    child: ConnectorChildLike,
    binaryPath: string
  ) {
    if (!child.pid) return;
    try {
      await this.#persistPidEvidence(entry.pidPath, {
        binaryPath,
        configPath: entry.configPath,
        pid: child.pid,
        runNonce: entry.runNonce,
        shutdownRequestPath: entry.shutdownRequestPath,
        startedAtMs: entry.spawnedAtMs,
        workspaceId: entry.workspaceId,
      });
    } catch (error) {
      // Pre-spawn nonce evidence keeps this child discoverable across a Main
      // crash, but PID evidence is still required for this supervised
      // attempt's diagnostics. Abort, stop, and retry rather than deliberately
      // running without that record.
      throw new Error(`could not record connector pid: ${errorText(error)}`, {
        cause: error,
      });
    }
  }

  async #stopChild(entry: WorkspaceConnectorEntry): Promise<boolean> {
    const child = entry.child;
    const exited = entry.exited;
    if (!child) {
      entry.childExited = true;
      entry.exited = undefined;
      return true;
    }
    if (entry.childExited) {
      entry.child = undefined;
      entry.exited = undefined;
      await rm(entry.pidPath, { force: true }).catch(() => undefined);
      return true;
    }
    await persistCooperativeShutdownRequest(
      entry.shutdownRequestPath,
      entry.runNonce
    ).catch((error) => {
      this.#log.warn(
        `could not persist connector shutdown request: workspace=${entry.workspaceId} ${errorText(error)}`
      );
    });
    try {
      // This closes the stable parent-lifeline endpoint owned by this exact
      // ChildProcess. It never addresses a numeric pid and therefore cannot
      // signal a reused foreign process.
      child.requestStop();
    } catch {
      // The durable nonce request remains for the common recovery reaper.
    }
    const settled = exited
      ? await Promise.race([
          exited.then(() => true),
          delayMs(this.#stopGraceMs).then(() => false),
        ])
      : false;
    if (!settled && !entry.childExited) {
      this.#log.warn(
        `workspace connector did not exit after cooperative stop: workspace=${entry.workspaceId}`
      );
      // Do not erase the pid/evidence or wait forever. The common reaper will
      // re-issue the exact nonce request and only persist absence after a
      // complete native scan observes no matching process.
      return false;
    }
    entry.childExited = true;
    entry.child = undefined;
    entry.exited = undefined;
    // A pid file must only ever describe a live supervised child.
    await rm(entry.pidPath, { force: true }).catch(() => undefined);
    return true;
  }

  #backoffDelayMs(step: number) {
    const index = Math.min(Math.max(step, 0), this.#backoffScheduleMs.length - 1);
    return Math.max(1, this.#backoffScheduleMs[index] ?? 1);
  }

  #entryActive(entry: WorkspaceConnectorEntry) {
    return (
      !this.#closed &&
      !entry.stopRequested &&
      !entry.credential.signal.aborted &&
      this.#entries.get(entry.workspaceId) === entry
    );
  }

  #evictBeyondCapacity() {
    while (this.#entries.size >= this.#maxWorkspaces) {
      const idle = [...this.#entries.values()]
        .filter((candidate) => candidate.waitingCount === 0)
        .toSorted((left, right) => left.lastUsedAtMs - right.lastUsedAtMs)[0];
      // Every remaining entry has an active waiter; briefly exceeding the
      // cap is better than tearing down a connector mid-registration.
      if (!idle) return;
      this.#forgetEntryScopeState(idle);
      requestEntryStop(idle);
      this.#entries.delete(idle.workspaceId);
    }
  }

  /**
   * Sweeps run directories that survived a previous Main process. Current
   * runs are discovered by exact executable/config/nonce identity; legacy pid
   * evidence is only a lookup hint and requires exact executable/start-time
   * verification. Any unverifiable process or credential retains the run
   * evidence for a later retry.
   */
  async #runOrphanSweep(): Promise<void> {
    let workspaceDirs: string[];
    try {
      workspaceDirs = await readdir(this.#connectorsRootDir);
    } catch (error) {
      if (!isNotFoundError(error)) {
        this.#orphanSweepIncomplete = true;
        this.#log.warn(`connector orphan enumeration failed: ${errorText(error)}`);
      }
      return;
    }
    for (const workspaceDir of workspaceDirs) {
      const runsRoot = join(this.#connectorsRootDir, workspaceDir, "runs");
      let runDirs: string[];
      try {
        runDirs = await readdir(runsRoot);
      } catch (error) {
        if (!isNotFoundError(error)) {
          this.#orphanSweepIncomplete = true;
          this.#log.warn(
            `connector run enumeration failed: ${runsRoot} ${errorText(error)}`
          );
        }
        continue;
      }
      for (const runId of runDirs) {
        const runDir = join(runsRoot, runId);
        if (this.#ownsRunDir(runDir)) continue;
        const contained = await this.#reapRunDir(runDir);
        if (!contained) this.#orphanSweepIncomplete = true;
      }
    }
  }

  #ownsRunDir(runDir: string) {
    return [...this.#entries.values()].some((entry) => entry.runDir === runDir);
  }

  /**
   * Contains one stale run directory. Credential revocation and OS process
   * absence are independent confirmations. Neither substitutes for the other,
   * and evidence is deleted only after both have linearized. The pre-spawn
   * nonce/config identity makes a child discoverable even when Main crashed
   * before publishing its pid.
   */
  async #reapRunDir(runDir: string): Promise<boolean> {
    const pidPath = join(runDir, "connector.pid");
    let parsed: z.output<typeof connectorPidFileSchema> | undefined;
    try {
      const result = connectorPidFileSchema.safeParse(
        JSON.parse(await readFile(pidPath, "utf8"))
      );
      parsed = result.success ? result.data : undefined;
    } catch {
      parsed = undefined;
    }
    let evidence: z.output<typeof connectorRunEvidenceSchema> | undefined;
    let evidenceReadable = true;
    try {
      const result = connectorRunEvidenceSchema.safeParse(
        JSON.parse(await readFile(join(runDir, "run.json"), "utf8"))
      );
      if (result.success) {
        evidence = result.data;
      } else {
        evidenceReadable = false;
      }
    } catch (error) {
      evidence = undefined;
      evidenceReadable = isNotFoundError(error);
    }

    const credential = await inspectRunDirCredential(runDir);
    let credentialContained = evidence?.credentialContainedAtMs !== undefined;
    if (!credentialContained) {
      let confirmed = credential.state === "absent";
      if (credential.state === "present") {
        confirmed = await this.#revokeRunDirToken(
          credential.token,
          evidence?.workspaceId ?? parsed?.workspaceId
        );
      }
      if (confirmed && evidence) {
        const persisted = await this.#persistRunEvidence(runDir, evidence, {
          credentialContainedAtMs: Date.now(),
        });
        evidence = persisted.evidence;
        credentialContained = persisted.persisted;
      } else {
        credentialContained = confirmed && evidenceReadable;
      }
    }

    let processContained = evidence?.processAbsentAtMs !== undefined;
    if (!processContained) {
      const confirmed = await this.#containRunProcess(runDir, evidence, parsed);
      if (confirmed && evidence) {
        const persisted = await this.#persistRunEvidence(runDir, evidence, {
          processAbsentAtMs: Date.now(),
        });
        evidence = persisted.evidence;
        processContained = persisted.persisted;
      } else {
        processContained = confirmed && evidenceReadable;
      }
    }

    if (evidenceReadable && credentialContained && processContained) {
      await rm(runDir, { force: true, recursive: true }).catch(() => undefined);
      return true;
    }
    this.#log.warn(
      `keeping stale run state for retry: ${runDir} (containment unconfirmed)`
    );
    return false;
  }

  async #persistRunEvidence(
    runDir: string,
    evidence: z.output<typeof connectorRunEvidenceSchema>,
    update: Partial<z.output<typeof connectorRunEvidenceSchema>>
  ) {
    const next = { ...evidence, ...update };
    const path = join(runDir, "run.json");
    try {
      await this.#persistContainmentEvidence(path, next);
      return { evidence: next, persisted: true } as const;
    } catch (error) {
      this.#log.warn(
        `could not persist connector containment evidence: ${runDir} ${errorText(error)}`
      );
      return { evidence, persisted: false } as const;
    }
  }

  async #containRunProcess(
    runDir: string,
    evidence: z.output<typeof connectorRunEvidenceSchema> | undefined,
    pidRecord: z.output<typeof connectorPidFileSchema> | undefined
  ): Promise<boolean> {
    const binaryPath = evidence?.binaryPath ?? pidRecord?.binaryPath;
    const configPath =
      evidence?.configPath ?? pidRecord?.configPath ?? join(runDir, "connector.json");
    const runNonce = evidence?.runNonce ?? pidRecord?.runNonce;

    // Current evidence always carries a nonce. Enumerating by the exact full
    // executable path plus config/nonce argv recovers the pre-PID crash
    // window and avoids PID reuse entirely.
    if (binaryPath && runNonce) {
      let snapshot: ConnectorProcessSnapshot;
      try {
        snapshot = await this.#enumerateProcesses({ runNonce });
      } catch (error) {
        this.#log.warn(`connector process enumeration failed: ${errorText(error)}`);
        return false;
      }
      if (!snapshot.complete) {
        this.#log.warn("connector process enumeration incomplete; retaining evidence");
        return false;
      }
      const matches = snapshot.processes.filter((candidate) =>
        this.#matchesRunProcess(candidate, binaryPath, configPath, runNonce)
      );
      if (matches.length === 0) return true;

      // Numeric pids are observations, never authority: an enumerate -> kill
      // sequence cannot exclude PID reuse. Ask only the nonce-authenticated Go
      // child to stop, then require a fresh complete scan to prove absence.
      const shutdownRequestPath =
        evidence?.shutdownRequestPath ??
        pidRecord?.shutdownRequestPath ??
        join(runDir, "shutdown-request.json");
      try {
        await persistCooperativeShutdownRequest(shutdownRequestPath, runNonce);
      } catch (error) {
        this.#log.warn(
          `could not request cooperative orphan shutdown: ${runDir} ${errorText(error)}`
        );
        return false;
      }
      return this.#waitForRunProcessAbsence(binaryPath, configPath, runNonce);
    }

    // Compatibility recovery for runs created before nonce evidence existed.
    // A recorded PID remains only a lookup hint. Legacy runs have no
    // nonce-authenticated stop endpoint, so recovery observes but never sends
    // a nonzero signal to that numeric identity.
    if (pidRecord) {
      const supervisedPids = new Set(
        [...this.#entries.values()].flatMap((current) =>
          current.child?.pid ? [current.child.pid] : []
        )
      );
      if (
        supervisedPids.has(pidRecord.pid) ||
        processPresence(pidRecord.pid) === "absent"
      ) {
        return true;
      }
      const live = await this.#inspectProcess(pidRecord.pid).catch(() => null);
      const sameBinary =
        live !== null &&
        sameExecutable(live.command, pidRecord.binaryPath, this.#processPlatform);
      const sameStart =
        live !== null &&
        live.startedAtMs !== undefined &&
        Math.abs(live.startedAtMs - pidRecord.startedAtMs) <=
          ORPHAN_START_TIME_TOLERANCE_MS;
      if (live && sameBinary && sameStart) {
        // Legacy evidence has no nonce-authenticated cooperative endpoint.
        // Signalling the recorded pid would retain an unavoidable reuse race,
        // so keep the evidence until auth-driven/natural exit is observed.
        this.#log.warn(
          `not signalling legacy pid=${pidRecord.pid}; waiting for affirmative exit`
        );
        return false;
      }
      if (live && !sameBinary) {
        return true;
      }
      this.#log.warn(
        `not signalling pid=${pidRecord.pid}; process identity could not be verified`
      );
      return false;
    }

    // A wholly empty run directory cannot correspond to a spawned child.
    // Conversely, malformed/token-bearing state without process identity is
    // not affirmative absence and remains for operator/retry recovery.
    return !evidence && !existsSync(join(runDir, "connector.json"));
  }

  #matchesRunProcess(
    candidate: ConnectorProcessInfo,
    binaryPath: string,
    configPath: string,
    runNonce: string
  ) {
    return (
      sameExecutable(candidate.executablePath, binaryPath, this.#processPlatform) &&
      commandLineHasRunIdentity(
        candidate.commandLine,
        configPath,
        runNonce,
        this.#processPlatform
      )
    );
  }

  async #waitForRunProcessAbsence(
    binaryPath: string,
    configPath: string,
    runNonce: string
  ): Promise<boolean> {
    // Native enumeration itself can take longer than the supervised-child
    // grace (especially CIM/lsof). Give the cooperative watcher enough time
    // for at least one request poll plus a fresh complete observation.
    const deadline = Date.now() + Math.max(this.#stopGraceMs, 2_000);
    for (;;) {
      let snapshot: ConnectorProcessSnapshot;
      try {
        snapshot = await this.#enumerateProcesses({ runNonce });
      } catch (error) {
        this.#log.warn(`connector process re-enumeration failed: ${errorText(error)}`);
        return false;
      }
      if (!snapshot.complete) return false;
      if (
        !snapshot.processes.some((candidate) =>
          this.#matchesRunProcess(candidate, binaryPath, configPath, runNonce)
        )
      ) {
        return true;
      }
      if (Date.now() >= deadline) return false;
      await delayMs(25);
    }
  }

  /**
   * Revokes the credential a stale run directory's config still holds. This
   * credential-containment half needs no OS process access: the server severs
   * the live socket. It is never process-exit proof; the separate native scan
   * and nonce shutdown path must still confirm absence before cleanup.
   */
  async #revokeRunDirToken(
    token: string,
    workspaceId: string | undefined
  ): Promise<boolean> {
    if (!workspaceId) return false;
    const credential = this.#acquireCredential();
    if (!credential) return false;
    try {
      await this.#api(credential).revokeConnectorToken(
        workspaceId,
        { token },
        { signal: AbortSignal.timeout(CONNECTOR_REVOKE_TIMEOUT_MS) }
      );
      this.#log.info(`revoked orphaned connector credential: workspace=${workspaceId}`);
      return true;
    } catch (error) {
      this.#log.warn(
        `orphaned credential revocation failed: workspace=${workspaceId} ${errorText(error)}`
      );
      return false;
    }
  }
}

function processPresence(pid: number): "absent" | "alive" | "unknown" {
  try {
    process.kill(pid, 0);
    return "alive";
  } catch (error) {
    // Only ESRCH is affirmative absence. EPERM/EACCES and every unfamiliar
    // platform error retain recovery evidence; access denial is never proof
    // that the recorded child exited.
    return (error as NodeJS.ErrnoException).code === "ESRCH" ? "absent" : "unknown";
  }
}

export function createConnectorSpawnPlan(
  input: {
    configPath: string;
    parentLifelineFd: 3;
    runNonce: string;
    shutdownRequestPath: string;
  },
  platform: NodeJS.Platform = process.platform,
  parentPid: number = process.pid
): ConnectorSpawnPlan {
  const args = [
    "--config",
    input.configPath,
    "--run-nonce",
    input.runNonce,
    "--shutdown-request-file",
    input.shutdownRequestPath,
  ];
  if (platform === "win32") {
    const pipePath = `\\\\.\\pipe\\comma-salix-parent-${parentPid}-${input.runNonce}`;
    return {
      args: [...args, "--parent-lifeline-pipe", pipePath],
      lifeline: { kind: "named_pipe", pipePath },
      stdio: ["pipe", "pipe", "pipe"],
    };
  }
  return {
    args: [...args, "--parent-lifeline-fd", String(input.parentLifelineFd)],
    lifeline: { fd: input.parentLifelineFd, kind: "fd" },
    stdio: ["pipe", "pipe", "pipe", "pipe"],
  };
}

export function spawnConnectorProcess(input: {
  binaryPath: string;
  clientControl?: { endpoint: string; token: string } | undefined;
  cliDir: string;
  configPath: string;
  logPath: string;
  parentLifelineFd: 3;
  runNonce: string;
  shutdownRequestPath: string;
  synchDataDir?: string | undefined;
}): ConnectorChildLike {
  const log = createWriteStream(input.logPath, { flags: "w", mode: 0o600 });
  const plan = createConnectorSpawnPlan(input);
  let lifelineServer: Server | undefined;
  let lifelineSocket: Socket | undefined;
  if (plan.lifeline.kind === "named_pipe") {
    lifelineServer = createServer((socket) => {
      if (lifelineSocket) {
        socket.destroy();
        return;
      }
      lifelineSocket = socket;
      socket.on("error", () => undefined);
    });
    // A listen failure makes the child fail closed when it cannot open the
    // named pipe; consume the event so Main itself does not crash first.
    lifelineServer.on("error", () => undefined);
    lifelineServer.listen(plan.lifeline.pipePath);
  }
  const child = spawn(input.binaryPath, plan.args, {
    detached: false,
    // POSIX fd 3 is inherited directly. Windows uses a named pipe because
    // numeric CRT descriptors are not stable OS handles across spawn.
    stdio: plan.stdio,
    env: {
      ...process.env,
      ...(input.clientControl
        ? {
            COMMA_CLIENT_CONTROL_TOKEN: input.clientControl.token,
            COMMA_CLIENT_CONTROL_URL: input.clientControl.endpoint,
          }
        : {}),
      ...(input.synchDataDir ? { SYNCH_DATA_DIR: input.synchDataDir } : {}),
      PATH: `${input.cliDir}${process.platform === "win32" ? ";" : ":"}${process.env.PATH ?? ""}`,
    },
  });
  child.stdout?.pipe(log);
  child.stderr?.pipe(log);
  // A raced EPIPE must reject the individual scope write, never become an
  // unhandled stream error that takes down Electron Main.
  child.stdin?.on("error", () => undefined);
  const parentLifeline =
    plan.lifeline.kind === "fd" ? child.stdio[plan.lifeline.fd] : undefined;
  const closeLifeline = () => {
    parentLifeline?.destroy();
    lifelineSocket?.destroy();
    try {
      lifelineServer?.close();
    } catch {
      // A listen failure can leave the server without an active handle.
    }
  };
  const closeControl = () => child.stdin?.destroy();

  // A spawn failure emits only "error"; supervision must still observe an
  // ended child, so both terminal events settle the same single exit.
  let settled = false;
  const exitListeners = new Set<() => void>();
  const settle = () => {
    if (settled) return;
    settled = true;
    closeLifeline();
    closeControl();
    log.end();
    const listeners = Array.from(exitListeners);
    exitListeners.clear();
    for (const listener of listeners) listener();
  };
  child.once("exit", settle);
  child.once("error", settle);

  return {
    get pid() {
      return child.pid;
    },
    once(_event: "exit", listener: () => void) {
      if (settled) {
        listener();
      } else {
        exitListeners.add(listener);
      }
      return this;
    },
    requestStop() {
      closeControl();
      closeLifeline();
    },
    setScope(scope: ConnectorScope) {
      const control = child.stdin;
      if (!control || control.destroyed || control.writableEnded) {
        throw new Error("Connector scope control channel is unavailable.");
      }
      return new Promise<void>((resolve, reject) => {
        let settledWrite = false;
        const settleWrite = (error?: Error | null) => {
          if (settledWrite) return;
          settledWrite = true;
          control.off("error", onError);
          if (error) reject(error);
          else resolve();
        };
        const onError = (error: Error) => settleWrite(error);
        control.once("error", onError);
        try {
          control.write(
            `${JSON.stringify({ type: "set_scope", run_nonce: input.runNonce, scope })}\n`,
            (error) => settleWrite(error)
          );
        } catch (error) {
          settleWrite(error instanceof Error ? error : new Error(String(error)));
        }
      });
    },
  };
}

function runPs(args: string[]) {
  return new Promise<string | null>((resolve) => {
    execFile("ps", args, { timeout: 3_000 }, (error, stdout) => {
      resolve(error ? null : stdout.trim());
    });
  });
}

function runPowerShell(command: string) {
  return new Promise<string | null>((resolve) => {
    execFile(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-Command", command],
      { timeout: 5_000, windowsHide: true },
      (error, stdout) => resolve(error ? null : stdout.trim())
    );
  });
}

function readDarwinExecutablePath(pid: number) {
  return new Promise<string | null>((resolve) => {
    execFile(
      "/usr/sbin/lsof",
      ["-a", "-p", String(pid), "-d", "txt", "-Fn"],
      { timeout: 3_000 },
      (error, stdout) => {
        if (error) {
          resolve(null);
          return;
        }
        const firstTextPath = stdout.split("\n").find((line) => line.startsWith("n/"));
        resolve(firstTextPath?.slice(1) ?? null);
      }
    );
  });
}

async function readPosixExecutablePath(pid: number, psCommand: string) {
  if (process.platform === "linux") {
    return readlink(`/proc/${pid}/exe`).catch(() => null);
  }
  if (process.platform === "darwin") {
    return readDarwinExecutablePath(pid);
  }
  return posix.isAbsolute(psCommand) ? psCommand : null;
}

/**
 * Resolves a live process's executable name and start time via `ps`. Returns
 * null when the pid is not running. A missing or unparsable start time keeps
 * the process unverified, which fails safe (evidence is retained).
 */
async function inspectProcessViaPs(
  pid: number
): Promise<{ command: string; startedAtMs: number | undefined } | null> {
  const command = await runPs(["-p", String(pid), "-o", "comm="]);
  if (!command) return null;
  const lstart = await runPs(["-p", String(pid), "-o", "lstart="]);
  const startedAtMs = lstart ? Date.parse(lstart) : Number.NaN;
  const executablePath = await readPosixExecutablePath(pid, command);
  return {
    command: executablePath ?? command,
    startedAtMs: Number.isFinite(startedAtMs) ? startedAtMs : undefined,
  };
}

/**
 * Windows counterpart of the `ps` probe: resolves executable path/name and
 * start time through CIM so legacy orphan identity remains observable on
 * win32 too. Returns null when the pid is not running; an unparsable start
 * time keeps the process unverified, which fails safe.
 */
async function inspectProcessViaCim(
  pid: number
): Promise<{ command: string; startedAtMs: number | undefined } | null> {
  if (!Number.isInteger(pid) || pid <= 0) return null;
  const stdout = await runPowerShell(
    `Get-CimInstance Win32_Process -Filter "ProcessId=${pid}" | Select-Object Name,ExecutablePath,CreationDate | ConvertTo-Json -Compress`
  );
  if (!stdout) return null;
  try {
    const parsed = JSON.parse(stdout) as {
      CreationDate?: string | null;
      ExecutablePath?: string | null;
      Name?: string | null;
    };
    const command = parsed.ExecutablePath || parsed.Name || "";
    if (!command) return null;
    return { command, startedAtMs: parseCimTimestamp(parsed.CreationDate) };
  } catch {
    return null;
  }
}

// Windows PowerShell serializes DateTime as "/Date(<ms>)/"; PowerShell 7
// serializes ISO-8601. Accept both; anything else stays unverified.
function parseCimTimestamp(value: string | null | undefined): number | undefined {
  if (!value) return undefined;
  const wrapped = /\/Date\((\d+)\)\//.exec(value);
  if (wrapped?.[1]) return Number(wrapped[1]);
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

const inspectProcessNative: InspectProcess = (pid) =>
  process.platform === "win32" ? inspectProcessViaCim(pid) : inspectProcessViaPs(pid);

async function enumerateConnectorProcessesViaPs(identity: {
  runNonce: string;
}): Promise<ConnectorProcessSnapshot> {
  const listing = await runPs(["-ww", "-axo", "pid=,command="]);
  if (listing === null) return { complete: false, processes: [] };
  const marker = `--run-nonce ${identity.runNonce}`;
  const candidatePids = listing
    .split("\n")
    .filter((line) => line.includes(marker))
    .map((line) => Number(/^\s*(\d+)\s+/.exec(line)?.[1]))
    .filter((pid) => Number.isInteger(pid) && pid > 0);
  const inspected = await Promise.all(
    candidatePids.map(async (pid): Promise<ConnectorProcessInfo | null> => {
      const [psCommand, commandLine, lstart] = await Promise.all([
        runPs(["-p", String(pid), "-o", "comm="]),
        runPs(["-ww", "-p", String(pid), "-o", "command="]),
        runPs(["-p", String(pid), "-o", "lstart="]),
      ]);
      if (!psCommand || !commandLine) return null;
      const executablePath = await readPosixExecutablePath(pid, psCommand);
      if (!executablePath) return null;
      const startedAtMs = lstart ? Date.parse(lstart) : Number.NaN;
      return {
        commandLine,
        executablePath,
        pid,
        startedAtMs: Number.isFinite(startedAtMs) ? startedAtMs : undefined,
      };
    })
  );
  // A candidate that stayed alive but could not be inspected means native
  // enumeration is incomplete; absence cannot be inferred from it.
  const complete = inspected.every(
    (candidate, index) =>
      candidate !== null || processPresence(candidatePids[index]!) === "absent"
  );
  return {
    complete,
    processes: inspected.filter(
      (candidate): candidate is ConnectorProcessInfo => candidate !== null
    ),
  };
}

async function enumerateConnectorProcessesViaCim(identity: {
  runNonce: string;
}): Promise<ConnectorProcessSnapshot> {
  const stdout = await runPowerShell(
    `Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*--run-nonce ${identity.runNonce}*' } | Select-Object ProcessId,ExecutablePath,CommandLine,CreationDate | ConvertTo-Json -Compress`
  );
  if (stdout === null) return { complete: false, processes: [] };
  if (!stdout) return { complete: true, processes: [] };
  try {
    const decoded = JSON.parse(stdout) as
      | {
          CommandLine?: string | null;
          CreationDate?: string | null;
          ExecutablePath?: string | null;
          ProcessId?: number | null;
        }
      | Array<{
          CommandLine?: string | null;
          CreationDate?: string | null;
          ExecutablePath?: string | null;
          ProcessId?: number | null;
        }>;
    const rows = Array.isArray(decoded) ? decoded : [decoded];
    const relevant = rows.filter((row) =>
      row.CommandLine?.includes(`--run-nonce ${identity.runNonce}`)
    );
    const complete = relevant.every(
      (row) =>
        typeof row.ProcessId === "number" &&
        Boolean(row.ExecutablePath) &&
        Boolean(row.CommandLine)
    );
    return {
      complete,
      processes: relevant.flatMap((row) =>
        typeof row.ProcessId === "number" && row.ExecutablePath && row.CommandLine
          ? [
              {
                commandLine: row.CommandLine,
                executablePath: row.ExecutablePath,
                pid: row.ProcessId,
                startedAtMs: parseCimTimestamp(row.CreationDate),
              },
            ]
          : []
      ),
    };
  } catch {
    return { complete: false, processes: [] };
  }
}

function enumerateConnectorProcessesNative(
  platform: NodeJS.Platform
): EnumerateConnectorProcesses {
  return platform === "win32"
    ? enumerateConnectorProcessesViaCim
    : enumerateConnectorProcessesViaPs;
}

/** Full executable identity only; a matching basename is never sufficient. */
function canonicalWindowsPath(value: string) {
  return win32
    .normalize(value.replace(/^\\\\\?\\/, ""))
    .replaceAll("/", "\\")
    .toLocaleLowerCase("en-US");
}

function sameExecutable(
  liveCommand: string,
  recordedBinaryPath: string,
  platform: NodeJS.Platform
) {
  if (platform === "win32") {
    if (!win32.isAbsolute(liveCommand) || !win32.isAbsolute(recordedBinaryPath)) {
      return false;
    }
    return (
      canonicalWindowsPath(liveCommand) === canonicalWindowsPath(recordedBinaryPath)
    );
  }
  if (!posix.isAbsolute(liveCommand) || !posix.isAbsolute(recordedBinaryPath)) {
    return false;
  }
  return posix.normalize(liveCommand) === posix.normalize(recordedBinaryPath);
}

function commandLineHasRunIdentity(
  commandLine: string,
  configPath: string,
  runNonce: string,
  platform: NodeJS.Platform
) {
  const args = splitCommandLine(commandLine, platform);
  let configMatches = false;
  let nonceMatches = false;
  for (let index = 0; index < args.length - 1; index += 1) {
    if (
      args[index] === "--config" &&
      pathsEqual(args[index + 1]!, configPath, platform)
    ) {
      configMatches = true;
    }
    if (args[index] === "--run-nonce" && args[index + 1] === runNonce) {
      nonceMatches = true;
    }
  }
  if (configMatches && nonceMatches) return true;

  // BSD ps may flatten an argv element containing spaces without retaining
  // quotes. The nonce is unguessable and the executable is separately exact,
  // so this exact adjacent pair remains a process identity rather than a
  // basename/substring heuristic.
  const configForms = [configPath, `"${configPath}"`, `'${configPath}'`]
    .map(escapeRegularExpression)
    .join("|");
  const exactAdjacentIdentity = new RegExp(
    `(?:^|\\s)--config\\s+(?:${configForms})\\s+--run-nonce\\s+${escapeRegularExpression(runNonce)}(?=\\s|$)`
  );
  return exactAdjacentIdentity.test(commandLine);
}

function escapeRegularExpression(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function pathsEqual(left: string, right: string, platform: NodeJS.Platform) {
  if (platform === "win32") {
    return (
      win32.normalize(left).replaceAll("/", "\\").toLocaleLowerCase("en-US") ===
      win32.normalize(right).replaceAll("/", "\\").toLocaleLowerCase("en-US")
    );
  }
  return posix.normalize(left) === posix.normalize(right);
}

function splitCommandLine(commandLine: string, platform: NodeJS.Platform) {
  const args: string[] = [];
  let current = "";
  let quote: '"' | "'" | undefined;
  for (let index = 0; index < commandLine.length; index += 1) {
    const character = commandLine[index]!;
    if (quote) {
      if (character === quote) {
        quote = undefined;
      } else if (
        platform !== "win32" &&
        character === "\\" &&
        index + 1 < commandLine.length
      ) {
        current += commandLine[(index += 1)]!;
      } else {
        current += character;
      }
    } else if (character === '"' || character === "'") {
      quote = character;
    } else if (/\s/.test(character)) {
      if (current) {
        args.push(current);
        current = "";
      }
    } else {
      current += character;
    }
  }
  if (current) args.push(current);
  return args;
}

function requireCompleteToken<
  T extends {
    alias?: string | undefined;
    device_id?: string | undefined;
    name?: string | undefined;
    server: string;
    token: string;
  },
>(token: T): T {
  if (!token.token || !token.server) {
    throw new Error("The workspace connector token response was incomplete.");
  }
  return token;
}

function workspaceStateDirName(workspaceId: string) {
  const safe = workspaceId.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 64);
  const hash = createHash("sha256").update(workspaceId).digest("hex").slice(0, 12);
  return `${safe}-${hash}`;
}

async function persistConnectorContainmentEvidence(
  path: string,
  evidence: z.output<typeof connectorRunEvidenceSchema>
) {
  const temporary = `${path}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  try {
    await writeFile(temporary, `${JSON.stringify(evidence)}\n`, { mode: 0o600 });
    await rename(temporary, path);
  } catch (error) {
    await rm(temporary, { force: true }).catch(() => undefined);
    throw error;
  }
}

async function persistConnectorPidEvidence(
  path: string,
  evidence: z.output<typeof connectorPidFileSchema>
) {
  await writeFile(path, `${JSON.stringify(evidence)}\n`, { mode: 0o600 });
}

async function persistCooperativeShutdownRequest(path: string, runNonce: string) {
  const temporary = `${path}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  try {
    await writeFile(temporary, `${JSON.stringify({ runNonce })}\n`, { mode: 0o600 });
    await rename(temporary, path);
  } catch (error) {
    await rm(temporary, { force: true }).catch(() => undefined);
    throw error;
  }
}

async function inspectRunDirCredential(
  runDir: string
): Promise<
  { state: "absent" } | { state: "present"; token: string } | { state: "unknown" }
> {
  const path = join(runDir, "connector.json");
  try {
    const parsed = connectorConfigTokenSchema.safeParse(
      JSON.parse(await readFile(path, "utf8"))
    );
    return parsed.success
      ? { state: "present", token: parsed.data.connector.connector_token }
      : { state: "unknown" };
  } catch (error) {
    return isNotFoundError(error) ? { state: "absent" } : { state: "unknown" };
  }
}

function isNotFoundError(error: unknown) {
  return (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT";
}

async function readStatusFile(path: string): Promise<ConnectorStatusFile | undefined> {
  if (!existsSync(path)) return undefined;
  try {
    const parsed = connectorStatusFileSchema.safeParse(
      JSON.parse(await readFile(path, "utf8"))
    );
    return parsed.success ? parsed.data : undefined;
  } catch {
    return undefined;
  }
}

async function readStatusTarget(
  path: string
): Promise<LocalFileRegistrationTarget | null> {
  return statusTarget(await readStatusFile(path));
}

function statusTarget(
  status: ConnectorStatusFile | undefined
): LocalFileRegistrationTarget | null {
  return status?.state === "connected" &&
    status.local_file_index_version === 2 &&
    status.device_id &&
    status.connector_run_id
    ? {
        connectorRunId: status.connector_run_id,
        deviceId: status.device_id,
        localFileIndexVersion: 2,
      }
    : null;
}

function connectorScopeUnavailable(
  workspaceId: string,
  scope: ConnectorScope = LOCAL_FILE_READ_SCOPE
): WorkspaceConnectorScopeState {
  return { available: false, scope, workspaceId };
}

function statusScopeState(
  workspaceId: string,
  status: ConnectorStatusFile | undefined
): WorkspaceConnectorScopeState | undefined {
  if (status?.state !== "connected" || status.scope === undefined) return undefined;
  return {
    available: true,
    scope: status.scope,
    workspaceId,
    ...(status.device_id ? { deviceId: status.device_id } : {}),
  };
}

function notifyEntry(entry: WorkspaceConnectorEntry) {
  const waiters = [...entry.waiters];
  entry.waiters.clear();
  for (const waiter of waiters) waiter();
}

function waitForEntryChange(
  entry: WorkspaceConnectorEntry,
  timeoutMs: number,
  signal?: AbortSignal
): Promise<void> {
  if (timeoutMs <= 0) return Promise.resolve();
  return new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      entry.waiters.delete(finish);
      signal?.removeEventListener("abort", finish);
      resolve();
    };
    const timer = setTimeout(finish, timeoutMs);
    timer.unref?.();
    entry.waiters.add(finish);
    signal?.addEventListener("abort", finish, { once: true });
    if (signal?.aborted) finish();
  });
}

function delayMs(ms: number): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    timer.unref?.();
  });
}

function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function shellQuote(value: string) {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}
