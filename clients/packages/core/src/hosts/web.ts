// The core on the web, in a dedicated worker per tab: the worker holding the Web Lock runs it, the others relay to it
// (@comma/core-kernel/web-worker). Its requests carry the session cookie (httpOnly: JavaScript never reads it) and
// the session headers that bind each to the session it was made for. Its databases are SQLite's WASM build on OPFS
// (`opfs-sahpool`: synchronous access handles, which only a dedicated worker has); a browser without them keeps this
// run's data in memory. Small values for the device go in a database of their own. The core runs the session lifecycle
// here (`sessionSource: "core"`): it has `authFetch`, the auth endpoints with the Cookie, and the worker's Web Locks,
// BroadcastChannels and SubtleCrypto (`webSession`).
import {
  CoreError,
  HostError,
  sqlError,
  SqlError,
  type ClientId,
  type CoreMessage,
  type Sql,
  type SqlRow,
  type SqlValue,
} from "@comma/core-kernel";
import { runCoreWorker } from "@comma/core-kernel/web-worker";
import { Effect, type Scope } from "effect";
import { Core } from "../core.ts";
import {
  authHeaders,
  HostUnsupported,
  type ApiRequest,
  type ApiResponse,
  type AuthRequest,
  type HintChannel,
  type Host,
  type ImageBytes,
  type Pull,
  type StreamResponse,
  type WebSessionPorts,
} from "../host.ts";
import { renderWebChatImagePreview } from "./web-image-preview.ts";

type WasmStmt = {
  bind(params: readonly SqlValue[]): WasmStmt;
  step(): boolean;
  get(into: unknown[]): unknown[];
  reset(clearBindings?: boolean): WasmStmt;
  finalize(): void;
};
type WasmDb = {
  exec(sql: string): unknown;
  prepare(sql: string): WasmStmt;
  changes(): number;
  close(): void;
};

/** What the core uses of SQLite's WASM build: files in the OPFS pool, or (no pool here) databases in memory. */
export interface WasmSqlite {
  open(path: string): WasmDb;
  memory(): WasmDb;
  unlink(path: string): boolean;
  reserve(files: number): Promise<void>;
  /** Whether the files are kept on the device (an OPFS pool), or only this run. */
  persistent: boolean;
}

/** A write OPFS refused (SQLITE_IOERR: the origin's quota is used up, as a rule) is taken for no room left. */
function webSqlError(e: unknown): SqlError {
  const err = sqlError(e);
  const code = (e as { resultCode?: unknown } | null)?.resultCode;
  if (err.kind === "other" && typeof code === "number" && (code & 0xff) === 10)
    return new SqlError(err.message, "full");
  return err;
}

/** A database of SQLite's WASM build: statements prepared once and kept. */
class WasmSql implements Sql {
  readonly #db: WasmDb;
  readonly #statements = new Map<string, WasmStmt>();
  #closed = false;

  constructor(db: WasmDb) {
    this.#db = db;
  }

  #prepare(sql: string): WasmStmt {
    let s = this.#statements.get(sql);
    if (!s) {
      s = this.#db.prepare(sql);
      this.#statements.set(sql, s);
    }
    return s;
  }

  exec(sql: string): void {
    try {
      this.#db.exec(sql);
    } catch (e) {
      throw webSqlError(e);
    }
  }

  run(sql: string, params: readonly SqlValue[] = []): number {
    const s = this.#prepare(sql);
    try {
      if (params.length > 0) s.bind(params);
      s.step();
      return this.#db.changes();
    } catch (e) {
      throw webSqlError(e);
    } finally {
      s.reset(true);
    }
  }

  all(sql: string, params: readonly SqlValue[] = []): SqlRow[] {
    const s = this.#prepare(sql);
    const rows: SqlRow[] = [];
    try {
      if (params.length > 0) s.bind(params);
      while (s.step()) rows.push(s.get([]) as SqlRow);
      return rows;
    } catch (e) {
      throw webSqlError(e);
    } finally {
      s.reset(true);
    }
  }

  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    for (const s of this.#statements.values()) s.finalize();
    this.#statements.clear();
    this.#db.close();
  }
}

/** SQLite's WASM build and its pool of OPFS files, loaded by the worker running the core alone (the pool holds every file). */
export async function loadWasmSqlite(): Promise<WasmSqlite> {
  const { default: init } = await import("@sqlite.org/sqlite-wasm");
  const sqlite3 = await init();
  const pool = await sqlite3
    .installOpfsSAHPoolVfs({
      name: "comma",
      directory: "/comma-core",
      initialCapacity: 6,
    })
    .catch((error: unknown) => {
      console.error(
        "comma core: no OPFS pool here; this run's data stays in memory",
        error
      );
      return null;
    });
  return {
    persistent: pool !== null,
    open: (path) =>
      pool
        ? (new pool.OpfsSAHPoolDb(path) as unknown as WasmDb)
        : (new sqlite3.oo1.DB(":memory:") as unknown as WasmDb),
    memory: () => new sqlite3.oo1.DB(":memory:") as unknown as WasmDb,
    unlink: (path) => pool?.unlink(path) ?? false,
    reserve: async (files) => {
      if (pool) await pool.reserveMinimumCapacity(pool.getFileCount() + files);
    },
  };
}

const failed = (e: unknown) =>
  new HostError(e instanceof Error ? e.message : String(e));

/** A product request as the worker's `fetch` sends it: the Cookie, and the session it was made for. */
export function apiRequestInit(request: ApiRequest, signal: AbortSignal): RequestInit {
  const headers = new Headers(request.headers);
  // The cookie names the session; these bind the request to the one it was made for (a tab signed in as another is refused).
  headers.set("x-comma-expected-auth-session-id", request.lease.sessionId);
  headers.set("x-comma-session-lifecycle-version", "1");
  headers.set("x-comma-session-transport", "cookie");
  return {
    method: request.method,
    headers,
    credentials: "include",
    cache: "no-store",
    redirect: "error",
    signal,
    ...(request.body ? { body: request.body as BodyInit } : {}),
  };
}

/** An auth request as the worker's `fetch` sends it: the Cookie included, the session headers added. */
export function authRequestInit(
  request: AuthRequest,
  signal: AbortSignal
): RequestInit {
  return {
    method: request.method,
    headers: new Headers(authHeaders(request)),
    credentials: "include",
    keepalive: false,
    signal,
    ...(request.body ? { body: request.body as BodyInit } : {}),
  };
}

/** The worker's Web Locks, BroadcastChannels and SubtleCrypto, for the session lifecycle. */
export function workerSessionPorts(apiOrigin: string): WebSessionPorts {
  return {
    apiOrigin,
    userAgent: typeof navigator === "undefined" ? "" : navigator.userAgent,
    lock: (name) =>
      Effect.callback<() => void, HostError>((resume) => {
        const locks = typeof navigator === "undefined" ? undefined : navigator.locks;
        if (!locks) {
          resume(Effect.fail(new HostUnsupported("Web Locks are not available")));
          return;
        }
        const controller = new AbortController();
        let release: (() => void) | null = null;
        let gone = false;
        locks
          .request(name, { mode: "exclusive", signal: controller.signal }, (lock) => {
            if (!lock) throw new Error("The Web Session coordination lock was denied.");
            if (gone) return undefined;
            return new Promise<void>((done) => {
              release = done;
              resume(Effect.succeed(() => done()));
            });
          })
          .catch((error: unknown) => {
            if (!gone) resume(Effect.fail(failed(error)));
          });
        return Effect.sync(() => {
          gone = true;
          controller.abort();
          (release as (() => void) | null)?.();
        });
      }),
    channel: (name): HintChannel => {
      const channel = new BroadcastChannel(name);
      return {
        // oxlint-disable-next-line unicorn/require-post-message-target-origin -- BroadcastChannel.postMessage has no targetOrigin.
        post: (message) => channel.postMessage(message),
        listen: (listener) => {
          const onMessage = (event: MessageEvent<unknown>) => listener(event.data);
          channel.addEventListener("message", onMessage);
          return () => channel.removeEventListener("message", onMessage);
        },
        close: () => channel.close(),
      };
    },
    sha256: (inputs) =>
      Effect.tryPromise({
        try: async () => {
          const encoder = new TextEncoder();
          const digests = await Promise.all(
            inputs.map((input) =>
              crypto.subtle.digest("SHA-256", encoder.encode(input))
            )
          );
          return digests.map((digest) => new Uint8Array(digest));
        },
        catch: failed,
      }),
  };
}

export class WebHost implements Host {
  readonly sessionSource = "core" as const;
  readonly #apiBase: string;
  readonly #emit: (client: ClientId, message: CoreMessage) => void;
  readonly #fetch: typeof fetch;
  readonly #sqlite: WasmSqlite;
  readonly #device: Sql;
  readonly #open = new Map<string, Sql>();
  readonly webSession: WebSessionPorts;

  private constructor(
    apiBase: string,
    emit: (client: ClientId, message: CoreMessage) => void,
    sqlite: WasmSqlite,
    device: Sql,
    fetchImpl: typeof fetch
  ) {
    this.#apiBase = apiBase.replace(/\/+$/, "");
    this.#emit = emit;
    this.#sqlite = sqlite;
    this.#device = device;
    this.#fetch = fetchImpl;
    this.webSession = workerSessionPorts(
      new URL(this.#apiBase, globalThis.location?.href ?? undefined).origin
    );
  }

  static async start(
    apiBase: string,
    emit: (client: ClientId, message: CoreMessage) => void,
    sqlite: WasmSqlite,
    // Called as a plain function: the worker's own `fetch` needs its global as `this`.
    fetchImpl: typeof fetch = (input, init) => fetch(input, init)
  ): Promise<WebHost> {
    await sqlite.reserve(2);
    const device = new WasmSql(sqlite.open("/device.sqlite3"));
    device.exec(
      "PRAGMA journal_mode = TRUNCATE; CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL)"
    );
    return new WebHost(apiBase, emit, sqlite, device, fetchImpl);
  }

  fetch(request: ApiRequest): Effect.Effect<ApiResponse, HostError> {
    return Effect.tryPromise({
      try: async (signal) => {
        const response = await this.#fetch(
          `${this.#apiBase}${request.path}`,
          apiRequestInit(request, signal)
        );
        return {
          status: response.status,
          headers: [...response.headers],
          body: new Uint8Array(await response.arrayBuffer()),
        };
      },
      catch: failed,
    });
  }

  fetchStream(
    request: ApiRequest
  ): Effect.Effect<StreamResponse, HostError, Scope.Scope> {
    return Effect.acquireRelease(
      Effect.tryPromise({
        try: async () => {
          const controller = new AbortController();
          const response = await this.#fetch(
            `${this.#apiBase}${request.path}`,
            apiRequestInit(request, controller.signal)
          );
          return { response, controller, reader: response.body?.getReader() ?? null };
        },
        catch: failed,
      }),
      ({ controller }) => Effect.sync(() => controller.abort())
    ).pipe(
      Effect.map(({ response, reader }) => {
        const body: Pull<Uint8Array> = {
          take: reader
            ? Effect.tryPromise({
                try: async () => {
                  const next = await reader.read();
                  return next.done ? null : next.value;
                },
                catch: failed,
              })
            : Effect.succeed(null),
        };
        return {
          status: response.status,
          headers: [...response.headers] as [string, string][],
          body,
        };
      })
    );
  }

  authFetch(request: AuthRequest): Effect.Effect<ApiResponse, HostError> {
    return Effect.tryPromise({
      try: async (signal) => {
        const response = await this.#fetch(
          `${this.#apiBase}${request.path}`,
          authRequestInit(request, signal)
        );
        return {
          status: response.status,
          headers: [...response.headers],
          body: new Uint8Array(await response.arrayBuffer()),
        };
      },
      catch: failed,
    });
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
    return Effect.tryPromise({
      try: async () => {
        await this.#sqlite.reserve(2);
        const db = new WasmSql(this.#sqlite.open(`/${name}.sqlite3`));
        // One worker holds the pool's files: the lock is its alone; no WAL (no shared memory here).
        db.exec(
          "PRAGMA locking_mode = EXCLUSIVE; PRAGMA journal_mode = TRUNCATE; PRAGMA synchronous = NORMAL;"
        );
        this.#open.get(name)?.close();
        this.#open.set(name, db);
        return db as Sql;
      },
      catch: (e) => webSqlError(e),
    });
  }

  get memoryDb(): Effect.Effect<Sql, HostError> {
    return Effect.try({
      try: () => new WasmSql(this.#sqlite.memory()) as Sql,
      catch: failed,
    });
  }

  deleteDb(name: string): Effect.Effect<void, HostError> {
    return Effect.try({
      try: () => {
        this.#open.get(name)?.close();
        this.#open.delete(name);
        for (const end of ["", "-journal", "-wal"])
          this.#sqlite.unlink(`/${name}.sqlite3${end}`);
      },
      catch: failed,
    });
  }

  /** A workspace image drawn again by this worker's decoder (createImageBitmap): the preview a tab may show. */
  renderImagePreview(input: ImageBytes): Effect.Effect<Uint8Array, HostError> {
    return Effect.tryPromise({
      try: () => renderWebChatImagePreview(input),
      catch: (e) => new HostError(e instanceof Error ? e.message : String(e)),
    });
  }

  randomBytes(buf: Uint8Array): void {
    crypto.getRandomValues(buf as Uint8Array<ArrayBuffer>);
  }

  get yieldTurn(): Effect.Effect<void> {
    return Effect.callback<void>((resume) => {
      // The host is where the core meets the browser's event loop.
      // @effect-diagnostics-next-line globalTimersInEffect:off
      const handle = setTimeout(() => resume(Effect.void), 0);
      return Effect.sync(() => clearTimeout(handle));
    });
  }

  emit(client: ClientId, message: CoreMessage): void {
    this.#emit(client, message);
  }
}

/**
 * Runs this dedicated worker as one of the tabs' workers: the one that gets the lock starts the core for `apiBase`.
 * `build` is this build's number: a worker of an older build retires when it hears of a newer one.
 */
export function runWebCoreWorker(options: {
  apiBase: string;
  build: number;
  loadSqlite?: () => Promise<WasmSqlite>;
}): void {
  runCoreWorker({
    name: "comma-core",
    build: options.build,
    start: async (emit) =>
      new Core(
        await WebHost.start(
          options.apiBase,
          emit,
          await (options.loadSqlite ?? loadWasmSqlite)()
        )
      ),
  });
}

export { CoreError };
