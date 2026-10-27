import { existsSync } from "node:fs";
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { createHash, randomBytes } from "node:crypto";
import { join } from "node:path";
import { sessionExpectation } from "@comma/session-contract";
import { z } from "zod";
import { realMainClock, type MainClock } from "../../clock";
import type { LocalFileRegistrationTarget } from "../local-files/registration";
import type { CoreClient } from "@comma/core-kernel/client";
import type { CommaConnectorToken, CommaDeviceInstall } from "@comma/core/api-schemas";
import type { MainProductCredentialLease } from "../session/main-credential-gate";
import type { MainSessionTransportAuthority } from "../session/main-session-transport";

const CONNECTOR_READY_TIMEOUT_MS = 12_000;
const CONNECTOR_STATUS_POLL_MS = 150;
const MAX_CONCURRENT_WORKSPACE_CONNECTORS = 3;
const CONNECTOR_TOKEN_TTL_SECONDS = 2 * 60 * 60;
/** The next credential is minted when a quarter of the current one's life remains. */
const RENEW_AT_LIFE_FRACTION = 0.75;
const CONNECTOR_REVOKE_TIMEOUT_MS = 5_000;
const MINT_RETRY_MS = [500, 2_000, 8_000, 30_000] as const;
const CREDENTIAL_WATCH_MS = 2_000;

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

/**
 * The status file the station writes for each connection
 * (`<instance>.json.status.json`, systems/station/src/connector/status.ts).
 * Its scope advances only once metadata carrying that scope reached Salix.
 */
const connectorStatusFileSchema = z.object({
  connector_run_id: z.string().trim().min(1).optional(),
  device_id: z.string().trim().min(1).optional(),
  last_error_message: z.string().optional(),
  local_file_index_version: z.number().int().positive().optional(),
  state: z.string().trim().min(1).optional(),
  scope: z.union([z.literal(""), z.literal(LOCAL_FILE_READ_SCOPE)]).optional(),
  updated_at: z.number().int().positive().optional(),
});

type ConnectorStatusFile = z.output<typeof connectorStatusFileSchema>;

const instanceFileSchema = z.object({
  comma: z.object({ workspace_id: z.string().min(1) }),
  connector: z.object({ connector_token: z.string().min(1) }).loose(),
});

const connectorDeviceFileSchema = z.object({
  deviceId: z.string().trim().min(1),
});

const connectorScopePreferenceSchema = z.strictObject({
  scope: z.union([z.literal(""), z.literal(LOCAL_FILE_READ_SCOPE)]),
  version: z.literal(1),
});

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

/** The machine's station as this runtime needs it (../station: LocalStation). */
export interface StationHost {
  /** `<station data>/connector/instances`: one file per Workspace connection. */
  readonly instancesDir: string;
  /** The station's own command (`comma-client`, `computer-use`) for the agents' `comma`. */
  readonly commandPath: string | undefined;
  /** Whether the app carries a station at all. */
  readonly carried: boolean;
  /** Starts it when it is not running (idempotent). */
  start(): void;
}

export interface WorkspaceConnectorRuntimeOptions {
  /** The machine's station. Undefined means none: every target resolution fails closed. */
  station: StationHost | undefined;
  /** Main's client control endpoint, for the agents' `comma`; given once it listens. */
  clientControl?: (() => { endpoint: string; token: string } | undefined) | undefined;
  /** Filesystem root the connector serves; the user's home in production. */
  connectorFileRoot: string;
  /** Private per-workspace state root, e.g. `<userData>/connectors`. */
  connectorsRootDir: string;
  /** Stable release namespace given to the station's connection. */
  runtimeNamespace?: string | undefined;
  /** Electron-owned runtime root given to the station's connection. */
  runtimeRoot?: string | undefined;
  /** The Computer Use helper the app carries. */
  computerUseHelperApp?: string | undefined;
  /** Bundled CLI exposed to env.exec through each connection's bin directory. */
  synchBinaryPath?: string | undefined;
  /** Comma-owned node selected when the CLI receives no explicit --data-dir. */
  synchDataDir?: string | undefined;
  /** Main's own channel to the client core, which makes the Connector's credential requests. */
  core: () => CoreClient | undefined;
  /** Must be the exact index root the local-file snapshot store writes. */
  localFileIndexRoot: string;
  log?: {
    info(message: string): void;
    warn(message: string): void;
  };
  maxWorkspaces?: number;
  onScopeStateChanged?:
    | ((snapshot: WorkspaceConnectorScopeSnapshot) => void)
    | undefined;
  readyTimeoutMs?: number;
  session: MainSessionTransportAuthority;
  /**
   * Test/E2E-only static mode: resolve every workspace target from this
   * status file and never mint tokens or write connections.
   */
  staticStatusFilePath?: string | undefined;
  statusPollIntervalMs?: number;
  tokenTtlSeconds?: number;
  /**
   * Main's clock: the runtime's deadlines, when it used and wrote a connection, and its timers (a mint retry, the
   * credential watch, a status poll).
   */
  clock?: MainClock;
}

interface MintedConnector {
  alias?: string | undefined;
  name?: string | undefined;
  server: string;
}

interface WorkspaceConnectorEntry {
  credential: MainProductCredentialLease;
  desiredScope: ConnectorScope;
  instancePath: string;
  lastError: string | undefined;
  lastUsedAtMs: number;
  mintedToken: string | undefined;
  /** When the credential in use expires, and when its successor is minted (the runtime's clock). */
  mintedExpiresAtMs: number;
  renewAtMs: number;
  renewAttempts: number;
  /** Credentials a renewal replaced: each is revoked once it has expired, or when the entry stops. */
  retiring: { token: string; expiresAtMs: number }[];
  /** The entry's mints, revocations and connection writes, one at a time (`#oneAtATime`). */
  credentialWork: Promise<void>;
  renewal: (() => void) | undefined;
  statusPath: string;
  stopped: boolean;
  /** When the connection was last written (seconds, as the status file's `updated_at`). */
  writtenAtSeconds: number;
  waiters: Set<() => void>;
  workspaceDir: string;
  workspaceId: string;
  /** The credential in the connection file this entry last wrote. */
  writtenToken: string | undefined;
  /** Where and as what the last minted credential connects. */
  minted: MintedConnector | undefined;
}

export interface WorkspaceConnectorEntryState {
  lastError: string | undefined;
  workspaceId: string;
}

/**
 * Electron Main's owner of the signed-in Workspaces' connections on this
 * machine's station (systems/station/README.md). The station runs one
 * connection per file in its instances directory; this service writes, changes
 * and removes those files.
 *
 * - Each Workspace has a private directory under `connectorsRootDir`: its
 *   stable device identity (`device.json`), re-attached at every mint, and the
 *   user's scope choice (`scope.json`). Missing state allows operations by
 *   default; malformed or unreadable state restricts access to
 *   `local_file_read`.
 * - Every minted credential is full and short-lived, and its lifetime bounds
 *   the connection that holds it. A quarter of its life before it expires, the
 *   next one is minted and written: the station presents it on its live
 *   connection, which keeps serving past the old one (systems/station/README.md).
 *   The replaced credential is revoked once it has expired. When Salix refuses
 *   a credential, the ones held are revoked and the connection is written again
 *   with a new one.
 * - The Session credential lease is the stop authority: its abort removes the
 *   connection at once, and its credential is revoked while any authorized
 *   Session is available. A connection file left by an earlier run of the app
 *   (the station outlives nothing: it ends with the app) is removed, and its
 *   credential revoked, at the next sign-in.
 * - A scope change is written to the connection's file; the station changes
 *   the running connection in place and acknowledges the scope in its status
 *   file once Salix has the metadata.
 */
export class WorkspaceConnectorRuntimeService implements WorkspaceConnectorRuntimeLike {
  #closed = false;
  readonly #options: WorkspaceConnectorRuntimeOptions;
  readonly #entries = new Map<string, WorkspaceConnectorEntry>();
  readonly #log: { info(message: string): void; warn(message: string): void };
  readonly #maxWorkspaces: number;
  readonly #readyTimeoutMs: number;
  readonly #statusPollIntervalMs: number;
  readonly #tokenTtlSeconds: number;
  readonly #clock: MainClock;
  readonly #setTimer: MainClock["setTimer"];
  #scopeRevision = 0;
  readonly #scopeStates = new Map<string, WorkspaceConnectorScopeState>();
  readonly #scopeTails = new Map<string, Promise<void>>();
  readonly #devicePersistChains = new Map<string, Promise<void>>();
  /** Writes and removals of each connection file, one at a time: a replaced entry and its successor share it. */
  readonly #instanceChains = new Map<string, Promise<void>>();
  #leftovers: Promise<void> | undefined;

  constructor(options: WorkspaceConnectorRuntimeOptions) {
    this.#options = options;
    this.#log = options.log ?? { info: () => {}, warn: () => {} };
    this.#maxWorkspaces = options.maxWorkspaces ?? MAX_CONCURRENT_WORKSPACE_CONNECTORS;
    this.#readyTimeoutMs = options.readyTimeoutMs ?? CONNECTOR_READY_TIMEOUT_MS;
    this.#statusPollIntervalMs =
      options.statusPollIntervalMs ?? CONNECTOR_STATUS_POLL_MS;
    this.#tokenTtlSeconds = options.tokenTtlSeconds ?? CONNECTOR_TOKEN_TTL_SECONDS;
    this.#clock = options.clock ?? realMainClock;
    this.#setTimer = (ms, run) => this.#clock.setTimer(ms, run);
  }

  /**
   * At a sign-in: connection files an earlier run of the app left behind are
   * removed and their credentials revoked under the new Session.
   */
  resumeContainment(): void {
    if (this.#closed || this.#options.staticStatusFilePath || !this.#options.station)
      return;
    this.#leftovers = (this.#leftovers ?? Promise.resolve())
      .catch(() => undefined)
      .then(() => this.#retireLeftovers());
    void this.#leftovers.catch(() => undefined);
  }

  state(): WorkspaceConnectorEntryState[] {
    return [...this.#entries.values()].map((entry) => ({
      lastError: entry.lastError,
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

  prewarm(workspaceId: string): void {
    if (this.#closed || this.#options.staticStatusFilePath || !this.#available())
      return;
    try {
      this.#ensureEntry(workspaceId);
    } catch {
      // Prewarm is advisory; demand-time resolution reports real failures.
    }
  }

  /** Writes the Workspace's connection again with a freshly minted credential. */
  recycle(workspaceId: string): void {
    if (this.#closed) return;
    const entry = this.#entries.get(workspaceId);
    if (!entry) {
      this.prewarm(workspaceId);
      return;
    }
    void this.#connect(entry);
  }

  async scope(workspaceId: string): Promise<WorkspaceConnectorScopeState> {
    const normalized = workspaceId.trim();
    const unavailable = connectorScopeUnavailable(normalized);
    if (!normalized || this.#closed) return unavailable;
    if (this.#options.staticStatusFilePath) {
      const state =
        statusScopeState(
          normalized,
          await readStatusFile(this.#options.staticStatusFilePath)
        ) ?? unavailable;
      this.#publishScopeState(state);
      return state;
    }
    if (!this.#available()) return unavailable;
    let entry: WorkspaceConnectorEntry;
    try {
      entry = this.#ensureEntry(normalized);
    } catch {
      return unavailable;
    }
    return this.#waitForScope(entry, undefined);
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
      !this.#available() ||
      this.#options.staticStatusFilePath
    ) {
      return unavailable;
    }
    const previous = this.#scopeTails.get(normalized) ?? Promise.resolve();
    let result!: Promise<WorkspaceConnectorScopeState>;
    const operation = previous
      .catch(() => undefined)
      .then(async () => {
        await this.#persistDesiredScope(normalized, scope);
        const entry = this.#ensureEntry(normalized);
        entry.desiredScope = scope;
        // After any renewal in flight: the file keeps the credential in use.
        await this.#oneAtATime(entry, async () => {
          if (entry.mintedToken) await this.#writeInstance(entry, entry.mintedToken);
        });
        return this.#waitForScope(entry, scope);
      });
    result = operation;
    const tail = operation.then(
      () => undefined,
      () => undefined
    );
    this.#scopeTails.set(normalized, tail);
    void tail.finally(() => {
      if (this.#scopeTails.get(normalized) === tail)
        this.#scopeTails.delete(normalized);
    });
    return result;
  }

  async registrationTarget(
    workspaceId: string,
    options: { signal?: AbortSignal } = {}
  ): Promise<LocalFileRegistrationTarget | null> {
    if (this.#closed) return null;
    if (this.#options.staticStatusFilePath) {
      return statusTarget(await readStatusFile(this.#options.staticStatusFilePath));
    }
    if (!this.#available()) return null;
    let entry: WorkspaceConnectorEntry;
    try {
      entry = this.#ensureEntry(workspaceId);
    } catch {
      return null;
    }
    const deadline = this.#clock.now() + this.#readyTimeoutMs;
    for (;;) {
      if (this.#closed || options.signal?.aborted || entry.stopped) return null;
      const target = statusTarget(await this.#entryStatus(entry));
      if (target) {
        // The stable device must be durable BEFORE any caller can bind a
        // route to it.
        await this.#persistDeviceId(entry, target.deviceId);
        entry.lastUsedAtMs = this.#clock.now();
        return target;
      }
      const remaining = deadline - this.#clock.now();
      if (remaining <= 0) return null;
      await waitForEntryChange(
        entry,
        Math.min(remaining, this.#statusPollIntervalMs),
        this.#setTimer,
        options.signal
      );
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
      this.#options.onScopeStateChanged?.(this.scopeSnapshot());
    }
    await Promise.all(entries.map((entry) => this.#stop(entry)));
    await Promise.all(this.#scopeTails.values());
    await this.#leftovers?.catch(() => undefined);
  }

  async copyConnectCommand(
    workspaceId: string,
    copy: (text: string) => Promise<void> | void
  ) {
    const credential = this.#acquireCredential();
    if (!credential) throw new Error("Sign in before adding a device.");
    const api = this.#api(credential);
    const install = await api.createDeviceInstall(workspaceId, {
      name: "Comma Connector",
      alias: "device",
    });
    if ("kind" in install) {
      credential.signal.throwIfAborted();
      await copy(install.install_command);
      return;
    }
    const token = requireCompleteToken(install);
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

  #available() {
    return this.#options.station?.carried === true;
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
      const stale = [...this.#scopeStates.keys()].find((id) => !this.#entries.has(id));
      if (stale) this.#scopeStates.delete(stale);
    }
    this.#scopeStates.set(state.workspaceId, { ...state });
    this.#scopeRevision += 1;
    this.#options.onScopeStateChanged?.(this.scopeSnapshot());
  }

  #forgetScopeState(workspaceId: string): void {
    if (!this.#scopeStates.delete(workspaceId)) return;
    this.#scopeRevision += 1;
    this.#options.onScopeStateChanged?.(this.scopeSnapshot());
  }

  /** Waits for the station to acknowledge the connection (and `scope`, when given). */
  async #waitForScope(
    entry: WorkspaceConnectorEntry,
    scope: ConnectorScope | undefined
  ): Promise<WorkspaceConnectorScopeState> {
    const deadline = this.#clock.now() + this.#readyTimeoutMs;
    for (;;) {
      if (this.#clock.now() >= deadline || this.#closed || entry.stopped) {
        return connectorScopeUnavailable(entry.workspaceId, entry.desiredScope);
      }
      const state = statusScopeState(entry.workspaceId, await this.#entryStatus(entry));
      if (state?.available && (scope === undefined || state.scope === scope)) {
        if (this.#entries.get(entry.workspaceId) === entry)
          this.#publishScopeState(state);
        return state;
      }
      await waitForEntryChange(entry, this.#statusPollIntervalMs, this.#setTimer);
    }
  }

  /** The station's status of this entry's own connection: none before it wrote the file, nor an earlier one's. */
  async #entryStatus(entry: WorkspaceConnectorEntry) {
    if (!entry.writtenToken) return undefined;
    const status = await readStatusFile(entry.statusPath);
    return (status?.updated_at ?? 0) >= entry.writtenAtSeconds ? status : undefined;
  }

  #ensureEntry(workspaceId: string): WorkspaceConnectorEntry {
    const normalized = workspaceId.trim();
    if (!normalized || normalized.length > 160) {
      throw new Error("A concrete workspace is required.");
    }
    const existing = this.#entries.get(normalized);
    if (existing && !existing.stopped && !existing.credential.signal.aborted) {
      existing.lastUsedAtMs = this.#clock.now();
      return existing;
    }
    if (existing) {
      this.#entries.delete(normalized);
      void this.#stop(existing);
    }
    const station = this.#options.station;
    if (!station?.carried) throw new Error("This build carries no station.");
    const credential = this.#acquireCredential();
    if (!credential) throw new Error("No signed-in Session credential is available.");
    this.#evictBeyondCapacity();
    station.start();
    const dirName = workspaceStateDirName(normalized);
    const instancePath = join(station.instancesDir, `${dirName}.json`);
    const entry: WorkspaceConnectorEntry = {
      credential,
      desiredScope: LOCAL_FILE_READ_SCOPE,
      instancePath,
      lastError: undefined,
      lastUsedAtMs: this.#clock.now(),
      mintedToken: undefined,
      mintedExpiresAtMs: 0,
      renewAtMs: 0,
      renewAttempts: 0,
      retiring: [],
      credentialWork: Promise.resolve(),
      renewal: undefined,
      statusPath: `${instancePath}.status.json`,
      stopped: false,
      writtenAtSeconds: 0,
      waiters: new Set(),
      workspaceDir: join(this.#options.connectorsRootDir, dirName),
      workspaceId: normalized,
      minted: undefined,
      writtenToken: undefined,
    };
    this.#entries.set(normalized, entry);
    this.#publishScopeState(connectorScopeUnavailable(normalized));
    // The Session lease is the stop authority and it acts at once.
    credential.signal.addEventListener(
      "abort",
      () => {
        if (this.#entries.get(normalized) === entry) {
          this.#entries.delete(normalized);
          this.#forgetScopeState(normalized);
        }
        void this.#stop(entry);
      },
      { once: true }
    );
    void this.#connect(entry);
    return entry;
  }

  /**
   * Runs `work` after the entry's earlier credential work. A revocation fences
   * every generation up to the one it names, so a mint must not overlap
   * another: one's revocation could fence the credential the other wrote.
   */
  #oneAtATime(
    entry: WorkspaceConnectorEntry,
    work: () => Promise<void>
  ): Promise<void> {
    const run = entry.credentialWork.then(work);
    entry.credentialWork = run.catch(() => undefined);
    return run;
  }

  /**
   * Mints a credential and writes the connection, retried with backoff. A
   * credential is redeemed when the connection connects; once Salix refuses it
   * (it ran out, or was revoked) the station reports `auth_required` and the
   * connection is written again with a new one.
   */
  #connect(entry: WorkspaceConnectorEntry, attempt = 0): Promise<void> {
    return this.#oneAtATime(entry, () => this.#connectNow(entry, attempt));
  }

  async #connectNow(entry: WorkspaceConnectorEntry, attempt: number): Promise<void> {
    if (entry.stopped || this.#closed) return;
    entry.renewal?.();
    entry.renewal = undefined;
    try {
      if (this.#options.clientControl && !this.#options.clientControl()) {
        throw new Error("The client control endpoint is not ready yet.");
      }
      entry.desiredScope = await this.#readDesiredScope(entry.workspaceDir);
      const previous = entry.mintedToken;
      if (previous) {
        entry.mintedToken = undefined;
        await this.#revoke(entry.workspaceId, previous);
      }
      await this.#revokeRetiring(entry, Number.POSITIVE_INFINITY);
      const token = await this.#mintConnectorToken(entry);
      if (entry.stopped || this.#closed) {
        await this.#revoke(entry.workspaceId, token.token);
        return;
      }
      entry.mintedToken = token.token;
      this.#scheduleRenewal(entry);
      // Salix records the device at mint; the next mint re-attaches to it.
      await this.#persistDeviceId(entry, token.device_id);
      await rm(entry.statusPath, { force: true });
      entry.writtenAtSeconds = Math.floor(this.#clock.now() / 1000);
      await this.#writeInstance(entry, token.token, token);
      entry.lastError = undefined;
      notifyEntry(entry);
      this.#watchCredential(entry);
    } catch (error) {
      entry.lastError = errorText(error);
      this.#log.warn(
        `workspace connection not written: workspace=${entry.workspaceId} ${entry.lastError}`
      );
      notifyEntry(entry);
      const delay =
        MINT_RETRY_MS[Math.min(attempt, MINT_RETRY_MS.length - 1)] ?? 30_000;
      entry.renewal = this.#setTimer(
        delay,
        () => void this.#connect(entry, attempt + 1)
      );
    }
  }

  /**
   * Reads the connection's status until Salix refuses its credential, renews
   * the credential when it is due, and revokes the replaced ones that expired.
   */
  #watchCredential(entry: WorkspaceConnectorEntry) {
    const watch = this.#setTimer(CREDENTIAL_WATCH_MS, async () => {
      if (entry.stopped || this.#closed) return;
      const status = await readStatusFile(entry.statusPath);
      const refused =
        status?.state === "auth_required" &&
        (status.updated_at ?? 0) >= entry.writtenAtSeconds;
      if (refused) {
        this.#log.info(
          `workspace connector credential refused; minting another: workspace=${entry.workspaceId}`
        );
        void this.#connect(entry);
        return;
      }
      await this.#oneAtATime(entry, async () => {
        // Unless `#connect` took over meanwhile: it watches its own credential.
        if (entry.renewal !== watch || entry.stopped || this.#closed) return;
        await this.#revokeRetiring(entry, this.#clock.now());
        if (this.#clock.now() >= entry.renewAtMs) await this.#renew(entry);
      });
      if (entry.renewal === watch && !entry.stopped && !this.#closed) {
        this.#watchCredential(entry);
      }
    });
    entry.renewal = watch;
  }

  /**
   * Mints the next credential before the one in use expires and writes it into
   * the same connection file, without a new connection: the station presents it
   * on its live connection. The entry switches to it once the file holds it.
   * The replaced credential is revoked once it has expired, since the live
   * connection may still hold it until it switches. A failed mint or write is
   * retried with backoff while the watch goes on; past the old credential's
   * expiry, Salix's refusal starts over with `#connect`.
   */
  async #renew(entry: WorkspaceConnectorEntry) {
    const replaced = entry.mintedToken;
    if (!replaced) return;
    try {
      const token = await this.#mintConnectorToken(entry);
      if (entry.stopped || this.#closed) {
        await this.#revoke(entry.workspaceId, token.token);
        return;
      }
      try {
        await this.#persistDeviceId(entry, token.device_id);
        await this.#writeInstance(entry, token.token, token);
      } catch (error) {
        // No connection holds it, but revoking it now would also fence the one
        // in use (a revocation covers every older generation): it goes once it
        // has expired.
        entry.retiring.push({
          token: token.token,
          expiresAtMs: this.#clock.now() + this.#tokenTtlSeconds * 1_000,
        });
        throw error;
      }
      if (entry.stopped || this.#closed) {
        await this.#revoke(entry.workspaceId, token.token);
        return;
      }
      entry.retiring.push({ token: replaced, expiresAtMs: entry.mintedExpiresAtMs });
      entry.mintedToken = token.token;
      this.#scheduleRenewal(entry);
    } catch (error) {
      // The connection still holds a valid credential: not the entry's error.
      this.#log.warn(
        `workspace connector credential not renewed: workspace=${entry.workspaceId} ${errorText(error)}`
      );
      const delay =
        MINT_RETRY_MS[Math.min(entry.renewAttempts, MINT_RETRY_MS.length - 1)] ??
        30_000;
      entry.renewAttempts += 1;
      entry.renewAtMs = this.#clock.now() + delay;
    }
  }

  /** When the credential just minted expires, and when its successor is due. */
  #scheduleRenewal(entry: WorkspaceConnectorEntry) {
    const now = this.#clock.now();
    const lifeMs = this.#tokenTtlSeconds * 1_000;
    entry.mintedExpiresAtMs = now + lifeMs;
    entry.renewAtMs = now + Math.floor(lifeMs * RENEW_AT_LIFE_FRACTION);
    entry.renewAttempts = 0;
  }

  /** Revokes the replaced credentials that expired by `until`. */
  async #revokeRetiring(entry: WorkspaceConnectorEntry, until: number) {
    const due = entry.retiring.filter((retired) => retired.expiresAtMs <= until);
    entry.retiring = entry.retiring.filter((retired) => retired.expiresAtMs > until);
    for (const retired of due) await this.#revoke(entry.workspaceId, retired.token);
  }

  /** Removes the connection (the station closes it) and revokes its credential. */
  async #stop(entry: WorkspaceConnectorEntry): Promise<void> {
    if (entry.stopped) return;
    entry.stopped = true;
    entry.renewal?.();
    notifyEntry(entry);
    await this.#onInstance(entry.instancePath, async () => {
      // Only its own: a successor may have written the file already.
      if (
        entry.writtenToken &&
        (await instanceToken(entry.instancePath)) === entry.writtenToken
      ) {
        await rm(entry.instancePath, { force: true });
        await rm(entry.statusPath, { force: true });
      }
    }).catch(() => undefined);
    const token = entry.mintedToken;
    entry.mintedToken = undefined;
    if (token) await this.#revoke(entry.workspaceId, token);
    await this.#revokeRetiring(entry, Number.POSITIVE_INFINITY);
  }

  async #revoke(workspaceId: string, token: string) {
    const credential = this.#acquireCredential();
    if (!credential) return;
    try {
      await this.#api(credential).revokeConnectorToken(workspaceId, {
        token,
        timeoutMs: CONNECTOR_REVOKE_TIMEOUT_MS,
      });
    } catch (error) {
      // Its own short life bounds an unrevoked credential.
      this.#log.warn(
        `workspace connector token revocation failed: workspace=${workspaceId} ${errorText(error)}`
      );
    }
  }

  /** Connection files an earlier run of the app left: removed, their credentials revoked. */
  async #retireLeftovers() {
    const dir = this.#options.station?.instancesDir;
    if (!dir) return;
    let names: string[];
    try {
      names = await readdir(dir);
    } catch {
      return;
    }
    for (const name of names) {
      if (!name.endsWith(".json") || name.endsWith(".status.json")) continue;
      const path = join(dir, name);
      await this.#onInstance(path, async () => {
        if ([...this.#entries.values()].some((entry) => entry.instancePath === path))
          return;
        const parsed = instanceFileSchema.safeParse(
          JSON.parse(await readFile(path, "utf8"))
        );
        // A Workspace's connection only: the static connector's is the user's (../../connector).
        if (!parsed.success) return;
        await rm(path, { force: true });
        await rm(`${path}.status.json`, { force: true });
        await this.#revoke(
          parsed.data.comma.workspace_id,
          parsed.data.connector.connector_token
        );
      }).catch(() => undefined);
    }
  }

  #evictBeyondCapacity() {
    while (this.#entries.size >= this.#maxWorkspaces) {
      const oldest = [...this.#entries.values()].toSorted(
        (left, right) => left.lastUsedAtMs - right.lastUsedAtMs
      )[0];
      if (!oldest) return;
      this.#entries.delete(oldest.workspaceId);
      this.#forgetScopeState(oldest.workspaceId);
      void this.#stop(oldest);
    }
  }

  /** Acquires a Main-held product credential for the current signed-in generation. */
  #acquireCredential(): MainProductCredentialLease | null {
    const snapshot = this.#options.session.authority.getSnapshot();
    if (snapshot.phase !== "signed_in") return null;
    return this.#options.session.authority.acquireProductCredential(
      sessionExpectation(snapshot)
    );
  }

  /** The Connector's credential requests, made by the client core for `credential`'s session. */
  #api(credential: MainProductCredentialLease) {
    const lease = {
      audience: credential.audience,
      authorityInstanceId: credential.authorityInstanceId,
      generation: credential.generation,
      sessionId: credential.sessionId,
    };
    const call = async (name: string, params: Record<string, unknown>) => {
      const client = this.#options.core();
      if (!client) throw new Error("The client core is not running.");
      return client.call(name, { ...params, lease });
    };
    return {
      createConnectorToken: async (
        workspaceId: string,
        attrs: { expiresInSeconds?: number; stableDeviceId?: string }
      ) =>
        (await call("connector.createToken", {
          workspaceId,
          ...attrs,
        })) as CommaConnectorToken,
      revokeConnectorToken: async (
        workspaceId: string,
        attrs: { token: string; timeoutMs?: number }
      ) => {
        await call("connector.revokeToken", { workspaceId, ...attrs });
      },
      createDeviceInstall: async (
        workspaceId: string,
        attrs: { name: string; alias: string }
      ) =>
        (await call("connector.deviceInstall", {
          workspaceId,
          ...attrs,
        })) as CommaDeviceInstall,
    };
  }

  /**
   * Mints a full, short-lived connector credential re-attached to this
   * workspace's stable device identity. Only the server's typed
   * `403 stable_device_unavailable` refusal discards that identity.
   */
  async #mintConnectorToken(entry: WorkspaceConnectorEntry) {
    const api = this.#api(entry.credential);
    const stableDeviceId = await this.#readDeviceId(entry);
    const attrs = {
      expiresInSeconds: this.#tokenTtlSeconds,
      ...(stableDeviceId ? { stableDeviceId } : {}),
    } as const;
    try {
      return requireCompleteToken(
        await api.createConnectorToken(entry.workspaceId, attrs)
      );
    } catch (error) {
      if (
        stableDeviceId &&
        (error as { status?: unknown }).status === 403 &&
        (error as { code?: unknown }).code === "stable_device_unavailable"
      ) {
        await rm(join(entry.workspaceDir, "device.json"), { force: true }).catch(
          () => undefined
        );
        return requireCompleteToken(
          await api.createConnectorToken(entry.workspaceId, {
            expiresInSeconds: this.#tokenTtlSeconds,
          })
        );
      }
      throw error;
    }
  }

  async #readDesiredScope(workspaceDir: string): Promise<ConnectorScope> {
    try {
      const parsed = connectorScopePreferenceSchema.safeParse(
        JSON.parse(await readFile(join(workspaceDir, "scope.json"), "utf8"))
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
      this.#options.connectorsRootDir,
      workspaceStateDirName(workspaceId)
    );
    await writePrivate(
      join(workspaceDir, "scope.json"),
      `${JSON.stringify({ scope, version: 1 })}\n`
    );
  }

  async #readDeviceId(entry: WorkspaceConnectorEntry): Promise<string | undefined> {
    try {
      const parsed = connectorDeviceFileSchema.safeParse(
        JSON.parse(await readFile(join(entry.workspaceDir, "device.json"), "utf8"))
      );
      return parsed.success ? parsed.data.deviceId : undefined;
    } catch {
      return undefined;
    }
  }

  async #persistDeviceId(entry: WorkspaceConnectorEntry, deviceId: string | undefined) {
    // Serialized per WORKSPACE: a replaced entry and its successor share device.json.
    const previous =
      this.#devicePersistChains.get(entry.workspaceDir) ?? Promise.resolve();
    const chained = previous.then(async () => {
      if (!deviceId || entry.stopped) return;
      if ((await this.#readDeviceId(entry)) === deviceId) return;
      await writePrivate(
        join(entry.workspaceDir, "device.json"),
        `${JSON.stringify({ deviceId })}\n`
      );
    });
    this.#devicePersistChains.set(
      entry.workspaceDir,
      chained.catch(() => undefined)
    );
    return chained;
  }

  /** The connection's file in the station's instances directory (a desktop connector config). */
  async #writeInstance(
    entry: WorkspaceConnectorEntry,
    token: string,
    minted?: MintedConnector
  ) {
    if (minted) entry.minted = minted;
    if (!entry.minted) return;
    const clientControl = this.#options.clientControl?.();
    if (this.#options.clientControl && !clientControl) {
      throw new Error("The client control endpoint is not ready yet.");
    }
    const binDir = await this.#writeClientCLIs(entry);
    const config = {
      comma: { workspace_id: entry.workspaceId },
      connector: {
        alias: entry.minted.alias ?? "comma",
        connector_token: token,
        name: entry.minted.name ?? "Comma Desktop",
        reconnect: true,
        root: this.#options.connectorFileRoot,
        scope: entry.desiredScope,
        device: true,
        device_state_root: entry.workspaceDir,
        workspace_id: entry.workspaceId,
        server: entry.minted.server,
      },
      electron: {
        local_file_index_root: this.#options.localFileIndexRoot,
        bin_dir: binDir,
        env: {
          ...(clientControl
            ? {
                COMMA_CLIENT_CONTROL_TOKEN: clientControl.token,
                COMMA_CLIENT_CONTROL_URL: clientControl.endpoint,
              }
            : {}),
          ...(this.#options.synchDataDir
            ? { SYNCH_DATA_DIR: this.#options.synchDataDir }
            : {}),
        },
        ...(this.#options.runtimeNamespace
          ? { runtime_namespace: this.#options.runtimeNamespace }
          : {}),
        ...(this.#options.runtimeRoot
          ? { runtime_root: this.#options.runtimeRoot }
          : {}),
        ...(this.#options.computerUseHelperApp
          ? { computer_use_helper_app: this.#options.computerUseHelperApp }
          : {}),
      },
    };
    await this.#onInstance(entry.instancePath, async () => {
      if (entry.stopped) return;
      await writePrivate(entry.instancePath, `${JSON.stringify(config, null, 2)}\n`);
      entry.writtenToken = token;
    });
  }

  #onInstance(path: string, operation: () => Promise<void>): Promise<void> {
    const run = (this.#instanceChains.get(path) ?? Promise.resolve()).then(operation);
    const tail = run.catch(() => undefined);
    this.#instanceChains.set(path, tail);
    void tail.then(() => {
      if (this.#instanceChains.get(path) === tail) this.#instanceChains.delete(path);
    });
    return run;
  }

  /** The agents' `comma` (the station's comma-client) and `synch`, first on the connection's PATH. */
  async #writeClientCLIs(entry: WorkspaceConnectorEntry) {
    const binDir = join(entry.workspaceDir, "bin");
    await mkdir(binDir, { mode: 0o700, recursive: true });
    const command = this.#options.station?.commandPath;
    if (command) {
      await writeFile(
        join(binDir, "comma"),
        `#!/bin/sh\nexec ${shellQuote(command)} comma-client "$@"\n`,
        { mode: 0o700 }
      );
    }
    if (this.#options.synchBinaryPath) {
      if (!existsSync(this.#options.synchBinaryPath)) {
        throw new Error(
          `synch binary was not found at ${this.#options.synchBinaryPath}; env.exec cannot be started safely.`
        );
      }
      await writeFile(
        join(binDir, "synch"),
        `#!/bin/sh\nexec ${shellQuote(this.#options.synchBinaryPath)} "$@"\n`,
        { mode: 0o700 }
      );
    }
    return binDir;
  }
}

async function instanceToken(path: string): Promise<string | undefined> {
  try {
    const parsed = instanceFileSchema.safeParse(
      JSON.parse(await readFile(path, "utf8"))
    );
    return parsed.success ? parsed.data.connector.connector_token : undefined;
  } catch {
    return undefined;
  }
}

async function writePrivate(path: string, content: string) {
  await mkdir(join(path, ".."), { mode: 0o700, recursive: true });
  const temporary = `${path}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  try {
    await writeFile(temporary, content, { mode: 0o600 });
    await rename(temporary, path);
  } finally {
    await rm(temporary, { force: true });
  }
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

function isNotFoundError(error: unknown) {
  return (error as NodeJS.ErrnoException)?.code === "ENOENT";
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
  setTimer: (ms: number, run: () => void) => () => void,
  signal?: AbortSignal
): Promise<void> {
  return new Promise((resolve) => {
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      cancel();
      entry.waiters.delete(finish);
      signal?.removeEventListener("abort", finish);
      resolve();
    };
    const cancel = setTimer(timeoutMs, finish);
    entry.waiters.add(finish);
    signal?.addEventListener("abort", finish, { once: true });
  });
}

function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function shellQuote(value: string) {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}
