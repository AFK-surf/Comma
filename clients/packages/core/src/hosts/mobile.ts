// The core in the phone apps (apps/android/core, apps/apple/iOS/Core): one script (scripts/mobile-bundle.ts) run by
// Hermes on a thread of its own, the engine the two share (native/engine.cpp). The engine gives the script `commaNative`; the script gives the engine `commaCore`: `start(config)`, then
// `receive(json)` for what the app's UI says, `rejected(lease, status)` when the app saw the server refuse a request
// of its own, and `complete(id, json, error, bytes)` with the app's answers. What the core says to the UI goes out
// through `commaNative.emit`.
//
// Each app is to this core what Main is to Electron's: it keeps the bearer (the core names credentials by reference),
// makes every request (adding the credential of the lease a request names, refusing one whose lease its gate does not
// hold) and keeps the files. The core runs the session lifecycle against it (session/electron-lifecycle.ts).
//
// Operations the script asks of the app (`op`, its JSON → its answer):
//   fetch {method, path, headers, lease, localFileRef?} + body → {status, headers} + body (with `localFileRef`, the
//     body is that file the app holds, read as it is sent; asked only of an app that `uploadsLocalFiles`)
//   localFiles.read {ref, offset, length} → bytes: a part of a file the app holds, as a station takes it (asked only
//     of an app that `readsLocalFiles`)
//   stream.open {method, path, headers, lease} + body → {id, status, headers}; stream.read {id} → bytes, or {end};
//     stream.close {id}
//   auth.fetch {method, path, headers, credential?} + body → {status, headers} + body
//   download.open {method, path, headers, lease, target} + body → {id, status, total}; download.step {id} →
//     {received}, or {size, sha256} once the file is in place; download.create {target} → {id}, a file the core reads
//     itself, then download.append {id} + body → {received} each part and download.finish {id} → {size, sha256} once
//     it is in place; download.close {id}; download.remove {path}; download.retain {keep}
//   session.vault {} → the vault; session.change {change} → {value}; session.google {clientId, nonce} → the grant;
//     session.googleDone {grant, ok} (Android); session.apple {clientId, nonce} → {identityToken} (iOS); abort {id}
//     (an operation given up: never answered)
//   mesh.* (mobile-mesh.ts): this phone's iroh, which the engine answers itself where the app carries it
//     (`commaNative.mesh`); the app never sees them
// And at once (`callSync`, answering {value} or {error}): session.gate {snapshot, lease}; sql.open {name} → id
//   (`:memory:` one in memory); sql.exec {id, sql}; sql.run {id, sql, params} → changes; sql.all {id, sql, params} →
//   rows; sql.close {id}; sql.delete {name}. A blob goes as {"$bytes": base64}, as bytes do in what the UI says and hears.
import "./mobile-globals.ts";
import {
  HostError,
  SqlError,
  type ClientId,
  type CoreMessage,
  type Sql,
  type SqlRow,
  type SqlValue,
} from "@comma/core-kernel";
import type { SessionLifecycleSnapshot } from "@comma/session-contract";
import { Effect, type Scope } from "effect";
import { Core } from "../core.ts";
import { base64, fromBase64 } from "../record.ts";
import type {
  ApiRequest,
  ApiResponse,
  AuthRequest,
  BearerSessionPorts,
  ClientIdentity,
  DownloadPorts,
  Host,
  Pull,
  SessionLease,
  StationMeshPorts,
  StreamResponse,
} from "../host.ts";
import type { MobileNative } from "./mobile-globals.ts";
import { mobileStations } from "./mobile-mesh.ts";
import type {
  AppleGrant,
  BearerVault,
  BearerVaultChange,
  GoogleGrant,
  SessionAuthorityResume,
} from "./utility-protocol.ts";

type Answer = { json: unknown; bytes: Uint8Array | null };
type Waiting = { resolve(answer: Answer): void; reject(error: HostError): void };

/** The script's end of the bridge: what waits on the app, by id. */
class Bridge {
  readonly native: MobileNative;
  #next = 1;
  readonly #waiting = new Map<number, Waiting>();

  constructor(native: MobileNative) {
    this.native = native;
  }

  /** Operation `op`; interrupted, its answer is no longer waited for. */
  call(
    op: string,
    json: unknown,
    bytes: Uint8Array | null = null
  ): Effect.Effect<Answer, HostError> {
    return Effect.callback<Answer, HostError>((resume) => {
      const id = this.#next++;
      this.#waiting.set(id, {
        resolve: (answer) => resume(Effect.succeed(answer)),
        reject: (error) => resume(Effect.fail(error)),
      });
      this.native.call(
        id,
        op,
        JSON.stringify(json ?? {}),
        bytes === null
          ? undefined
          : (bytes.buffer as ArrayBuffer).slice(
              bytes.byteOffset,
              bytes.byteOffset + bytes.byteLength
            )
      );
      return Effect.sync(() => {
        if (this.#waiting.delete(id))
          this.native.call(0, "abort", `{"id":${id}}`, undefined);
      });
    });
  }

  /** An operation the app answers at once. */
  sync(op: string, json: unknown): unknown {
    const parsed = JSON.parse(this.native.callSync(op, JSON.stringify(json ?? {}))) as {
      error?: string;
      kind?: string;
      value?: unknown;
    };
    if (typeof parsed.error === "string") {
      if (op.startsWith("sql."))
        throw new SqlError(
          parsed.error,
          parsed.kind === "full" || parsed.kind === "busy" ? parsed.kind : "other"
        );
      throw new HostError(parsed.error);
    }
    return parsed.value;
  }

  complete(
    id: number,
    json: string | null,
    error: string | null,
    bytes: Uint8Array | null
  ): void {
    const waiting = this.#waiting.get(id);
    if (!waiting) return;
    this.#waiting.delete(id);
    if (error !== null) waiting.reject(new HostError(error));
    else
      waiting.resolve({
        json: json === null || json === "" ? null : JSON.parse(json),
        bytes,
      });
  }
}

type Head = { id: number; status: number; headers: [string, string][] };
type Encoded = null | number | string | { $bytes: string };

const encodeValue = (value: SqlValue): Encoded =>
  value instanceof Uint8Array ? { $bytes: base64(value) } : value;
const decodeValue = (value: Encoded): SqlValue =>
  value !== null && typeof value === "object" ? fromBase64(value.$bytes) : value;

/** A database the app keeps (the platform's SQLite), used at once from the core's thread. */
class MobileSql implements Sql {
  readonly #bridge: Bridge;
  readonly #id: number;
  #closed = false;

  constructor(bridge: Bridge, name: string) {
    this.#bridge = bridge;
    this.#id = bridge.sync("sql.open", { name }) as number;
  }

  exec(sql: string): void {
    this.#bridge.sync("sql.exec", { id: this.#id, sql });
  }

  run(sql: string, params: readonly SqlValue[] = []): number {
    return this.#bridge.sync("sql.run", {
      id: this.#id,
      sql,
      params: params.map(encodeValue),
    }) as number;
  }

  all(sql: string, params: readonly SqlValue[] = []): SqlRow[] {
    const rows = this.#bridge.sync("sql.all", {
      id: this.#id,
      sql,
      params: params.map(encodeValue),
    }) as Encoded[][];
    return rows.map((row) => row.map(decodeValue));
  }

  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#bridge.sync("sql.close", { id: this.#id });
  }
}

/** Bytes in what the app's UI says and hears cross the bridge as `{"$bytes": base64}` (a file to attach, an image read). */
function bytesOut(_key: string, value: unknown): unknown {
  return value instanceof Uint8Array ? { $bytes: base64(value) } : value;
}

function bytesIn(_key: string, value: unknown): unknown {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return value;
  const keys = Object.keys(value);
  const encoded = (value as { $bytes?: unknown }).$bytes;
  return keys.length === 1 && typeof encoded === "string" ? fromBase64(encoded) : value;
}

const failed = (e: unknown) =>
  e instanceof HostError
    ? e
    : new HostError(e instanceof Error ? e.message : String(e));

export interface MobileStart {
  /** Which app runs the core: what its sign-ins name, and whether it signs in with Google or Apple. */
  platform: "android" | "ios";
  /** The Comma API's origin: the only audience whose credentials are used. */
  apiOrigin: string;
  /** Where the app's gate is: the core continues its authority (the gate follows no other). */
  resumed: SessionAuthorityResume;
  /** The app sends a file it holds as a request's body (`localFileRef`): its picks upload from where they are. */
  uploadsLocalFiles?: boolean;
  /** The app reads a part of a file it holds (`localFiles.read`): its picks go up to a station a part at a time. */
  readsLocalFiles?: boolean;
  /** The app's version, as the core's requests report it (`Host.client`). */
  version?: string;
}

class MobileHost implements Host {
  readonly sessionSource = "core" as const;
  readonly uploadsLocalFiles: boolean;
  readonly bearerSession: BearerSessionPorts;
  readonly client: ClientIdentity;
  readonly deviceSetup?: import("../host.ts").DeviceSetupPort;
  readonly downloads: DownloadPorts;
  readonly stationMesh?: StationMeshPorts;
  readonly readLocalFile?: NonNullable<Host["readLocalFile"]>;
  readonly #bridge: Bridge;
  readonly #device: Sql;

  constructor(bridge: Bridge, start: MobileStart) {
    this.#bridge = bridge;
    this.uploadsLocalFiles = start.uploadsLocalFiles === true;
    this.client = {
      kind: start.platform,
      platform: start.platform,
      version: typeof start.version === "string" ? start.version : undefined,
    };
    if (start.platform === "ios")
      this.deviceSetup = {
        call: (op, input) =>
          bridge
            .call(`deviceSetup.${op}`, input)
            .pipe(Effect.map((answer) => (answer.json as { value: unknown }).value)),
      };
    if (bridge.native.mesh === true) this.stationMesh = mobileStations(bridge);
    if (start.readsLocalFiles === true)
      this.readLocalFile = (ref, offset, length) =>
        Effect.map(
          bridge.call("localFiles.read", { ref, offset, length }),
          (answer) => answer.bytes ?? new Uint8Array()
        );
    this.#device = new MobileSql(bridge, "device");
    this.#device.exec(
      "CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL)"
    );
    this.downloads = {
      open: (request, path) =>
        Effect.map(
          bridge.call(
            "download.open",
            { ...this.#head(request), target: path },
            request.body
          ),
          (a) => a.json as { id: number; status: number; total: number | null }
        ),
      step: (id) =>
        Effect.map(
          bridge.call("download.step", { id }),
          (a) => a.json as { received: number } | { size: number; sha256: string }
        ),
      close: (id) => Effect.asVoid(bridge.call("download.close", { id })),
      create: (path) =>
        Effect.map(
          bridge.call("download.create", { target: path }),
          (a) => a.json as { id: number }
        ),
      append: (id, bytes) =>
        Effect.map(
          bridge.call("download.append", { id }, bytes),
          (a) => a.json as { received: number }
        ),
      finish: (id) =>
        Effect.map(
          bridge.call("download.finish", { id }),
          (a) => a.json as { size: number; sha256: string }
        ),
      remove: (path) => Effect.asVoid(bridge.call("download.remove", { path })),
      retain: (keep) => Effect.asVoid(bridge.call("download.retain", { keep })),
    };
    const ios = start.platform === "ios";
    this.bearerSession = {
      apiOrigin: start.apiOrigin,
      clientKind: start.platform,
      clientPlatform: start.platform,
      showsKeptAccount: true,
      resumed: start.resumed,
      vault: Effect.map(bridge.call("session.vault", {}), (a) => a.json as BearerVault),
      change: (change: BearerVaultChange) =>
        Effect.map(
          bridge.call("session.change", { change }),
          (a) => (a.json as { value: BearerVault | boolean | null }).value
        ),
      gate: (snapshot: SessionLifecycleSnapshot, lease: SessionLease | null) =>
        void bridge.sync("session.gate", { snapshot, lease }),
      ...(ios
        ? {
            apple: (input: { clientId: string; nonce: string }) =>
              Effect.map(
                bridge.call("session.apple", input),
                (a) => a.json as AppleGrant
              ),
          }
        : {
            google: (input: { clientId: string; nonce: string }) =>
              Effect.map(
                bridge.call("session.google", input),
                (a) => a.json as GoogleGrant
              ),
            googleDone: (grant: string, ok: boolean) =>
              Effect.ignore(bridge.call("session.googleDone", { grant, ok })),
          }),
    };
  }

  #head(request: ApiRequest) {
    return {
      method: request.method,
      path: request.path,
      headers: request.headers,
      lease: request.lease,
      ...(request.localFileRef !== undefined
        ? { localFileRef: request.localFileRef }
        : {}),
    };
  }

  fetch(request: ApiRequest): Effect.Effect<ApiResponse, HostError> {
    return Effect.map(
      this.#bridge.call("fetch", this.#head(request), request.body),
      (a) => ({
        status: (a.json as Head).status,
        headers: (a.json as Head).headers,
        body: a.bytes ?? new Uint8Array(0),
      })
    );
  }

  fetchStream(
    request: ApiRequest
  ): Effect.Effect<StreamResponse, HostError, Scope.Scope> {
    const bridge = this.#bridge;
    return Effect.map(
      Effect.acquireRelease(
        bridge.call("stream.open", this.#head(request), request.body),
        (opened) =>
          Effect.ignore(bridge.call("stream.close", { id: (opened.json as Head).id }))
      ),
      (opened) => {
        const head = opened.json as Head;
        const body: Pull<Uint8Array> = {
          take: Effect.map(bridge.call("stream.read", { id: head.id }), (a) =>
            (a.json as { end?: boolean } | null)?.end === true
              ? null
              : (a.bytes ?? new Uint8Array(0))
          ),
        };
        return { status: head.status, headers: head.headers, body };
      }
    );
  }

  authFetch(request: AuthRequest): Effect.Effect<ApiResponse, HostError> {
    return Effect.map(
      this.#bridge.call(
        "auth.fetch",
        {
          method: request.method,
          path: request.path,
          headers: request.headers,
          ...(request.credential ? { credential: request.credential } : {}),
        },
        request.body
      ),
      (a) => ({
        status: (a.json as Head).status,
        headers: (a.json as Head).headers,
        body: a.bytes ?? new Uint8Array(0),
      })
    );
  }

  storageGet(key: string) {
    return Effect.try({
      try: () =>
        (this.#device.all("SELECT value FROM kv WHERE key = ?", [key])[0]?.[0] as
          | Uint8Array
          | undefined) ?? null,
      catch: failed,
    });
  }

  storageSet(key: string, value: Uint8Array) {
    return Effect.try({
      try: () =>
        void this.#device.run(
          "INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
          [key, value]
        ),
      catch: failed,
    });
  }

  storageDelete(key: string) {
    return Effect.try({
      try: () => void this.#device.run("DELETE FROM kv WHERE key = ?", [key]),
      catch: failed,
    });
  }

  openDb(name: string): Effect.Effect<Sql, HostError | SqlError> {
    return Effect.try({
      try: () => new MobileSql(this.#bridge, name) as Sql,
      catch: (e) => (e instanceof SqlError ? e : failed(e)),
    });
  }

  get memoryDb(): Effect.Effect<Sql, HostError | SqlError> {
    return Effect.try({
      try: () => new MobileSql(this.#bridge, ":memory:") as Sql,
      catch: (e) => (e instanceof SqlError ? e : failed(e)),
    });
  }

  deleteDb(name: string): Effect.Effect<void, HostError> {
    return Effect.try({
      try: () => void this.#bridge.sync("sql.delete", { name }),
      catch: failed,
    });
  }

  randomBytes(buf: Uint8Array): void {
    buf.set(new Uint8Array(this.#bridge.native.random(buf.length)));
  }

  get yieldTurn(): Effect.Effect<void> {
    return Effect.callback<void>((resume) => {
      // The host is where the core meets the platform's event loop.
      // @effect-diagnostics-next-line globalTimersInEffect:off
      const handle = setTimeout(() => resume(Effect.void), 0);
      return Effect.sync(() => clearTimeout(handle));
    });
  }

  emit(_client: ClientId, message: CoreMessage): void {
    this.#bridge.native.emit(JSON.stringify(message, bytesOut));
  }
}

// oxlint-disable-next-line typescript/no-explicit-any -- the engine's global object
const g = globalThis as any;
const native = g.commaNative as MobileNative;
const bridge = new Bridge(native);
let core: Core | null = null;
/**
 * The app is one UI to the core: its screens share this channel, each request by its own id. It is the host's own
 * channel too (no untrusted page shares the process), so it may make the calls that answer credentials.
 */
let app: ClientId = 0;

g.commaCore = {
  start(config: string): void {
    core = new Core(new MobileHost(bridge, JSON.parse(config) as MobileStart));
    // A fiber that failed with a bug leaves the core in a state nobody chose: the app starts another.
    core.runner.onDefect = (error) =>
      native.fatal(
        error instanceof Error
          ? `${error.message}\n${error.stack ?? ""}`
          : String(error)
      );
    app = core.connect(undefined, { host: true });
  },
  receive(json: string): void {
    core!.receive(app, JSON.parse(json, bytesIn));
  },
  rejected(lease: string, status: 401 | 409): void {
    core!.hostRejected(JSON.parse(lease) as SessionLease, status);
  },
  complete(
    id: number,
    json: string | null,
    error: string | null,
    bytes: ArrayBuffer | undefined
  ): void {
    bridge.complete(
      id,
      json,
      error,
      bytes === undefined ? null : new Uint8Array(bytes)
    );
  },
};
