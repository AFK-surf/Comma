// The core under test: a host with storage and databases in memory, a fake Comma API answering by route (the auth
// endpoints too), time on a TestClock the test moves (or the real clock, for a UI test), Web Locks and a hint channel
// in memory (two hosts given the same share them, as two tabs' workers would), and a channel a CoreClient opens to it
// in this thread.
import {
  HostError,
  type ClientId,
  type CoreMessage,
  type Sql,
  toJsonBytes,
} from "@comma/core-kernel";
import { NodeSql } from "@comma/core-kernel/node-sql";
import { TestTime } from "@comma/core-kernel/testing";
import { createHash } from "node:crypto";
import type { CoreClient, CoreError } from "@comma/core-kernel/client";
import { Deferred, Effect, Result, type Scope } from "effect";
import type { DriveEntry } from "../contract.ts";
import { Core } from "../core.ts";
import type { CoreLimits } from "../limits.ts";
import { base64, fromBase64, Recorder } from "../record.ts";
import { expect, onTestFailed, onTestFinished } from "vitest";
import { mkdirSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import {
  authHeaders,
  HostUnsupported,
  type ApiRequest,
  type ApiResponse,
  type AuthRequest,
  type BearerSessionPorts,
  type DesktopPorts,
  type DownloadPorts,
  type HintChannel,
  type Host,
  type LocalDriveListInput,
  type LocalDriveListResult,
  type LocalDriveOp,
  type LocalDriveOps,
  type LocalDrivePorts,
  type LocalDriveSpace,
  type LocalDriveState,
  type LocalDriveVersion,
  type MeetingPorts,
  type ResetPorts,
  type Pull,
  type SessionLease,
  type StationMeshPorts,
  type StreamResponse,
  type WebSessionPorts,
} from "../host.ts";

export { TestTime, flush } from "@comma/core-kernel/testing";
export { FakeMeetingMain, meetingFixture } from "./meeting.ts";
export { FakeDesktop, FakeUpdates } from "./fake-desktop.ts";
export { FakeStation, FakeStations, fakeCredential } from "./stations.ts";
export { Recorder } from "../record.ts";
export { DELIVERY_GRACE_MS, msUntilDailyDelivery } from "../recommendations.ts";
/** What the core sends Settings › Model & API for a catalog and profiles: a UI test scripts the topic with it. */
export { modelsView } from "../model-view.ts";

/** A request as the fake API saw it: its body parsed. */
export type SeenRequest = {
  method: string;
  path: string;
  /** A JSON body as its value; any other body as its bytes. */
  body: unknown;
  headers?: [string, string][];
  /** The session the request was made for; an auth request has none (`NO_LEASE`), and says `expected` instead. */
  lease: SessionLease;
  /** An auth request's expected session (`none`, `unknown` or an id). */
  expected?: string;
};

/** The lease an auth request is seen with: it has none. */
export const NO_LEASE: SessionLease = {
  audience: "",
  authorityInstanceId: "",
  generation: 0,
  sessionId: "",
};

type Answer = ApiResponse | HostError;
/** Answers a request; `signal` aborts when the core gives the request up (a timeout, a cancel, another account). */
type Handler = (request: SeenRequest, signal: AbortSignal) => Answer | Promise<Answer>;

export function json(status: number, value: unknown): ApiResponse {
  return {
    status,
    headers: [["content-type", "application/json"]],
    body: value === undefined ? new Uint8Array() : toJsonBytes(value),
  };
}

/** No answer at all: the network is down (or whatever else `message` says kept the answer away). */
export function offline(message = "network unreachable"): HostError {
  return new HostError(message);
}

/**
 * The Comma API as a test scripts it: handlers by method and path (a path ending in `*` matches what starts so), the
 * newest first; what no handler answers is a 404. `hold` keeps the next answer to a route until it is let go.
 */
/** An event stream the test feeds: `event` sends one, `end` ends it, `fail` breaks it. */
export class FakeStream implements Pull<Uint8Array> {
  readonly path: string;
  readonly #queue: (Uint8Array | null | HostError)[] = [];
  #waiting: ((piece: Uint8Array | null | HostError) => void) | null = null;
  closed = false;

  constructor(path: string) {
    this.path = path;
  }

  #push(piece: Uint8Array | null | HostError): void {
    if (this.closed) return;
    const waiting = this.#waiting;
    if (waiting) {
      this.#waiting = null;
      waiting(piece);
    } else this.#queue.push(piece);
  }

  /** A piece of the body as it came. */
  chunk(bytes: Uint8Array): void {
    this.#push(bytes);
  }

  /** One event with `data` as its JSON. */
  event(data: unknown): void {
    this.#push(new TextEncoder().encode(`data: ${JSON.stringify(data)}\n\n`));
  }

  /** One event named `name` (`event:`), with `data` as its JSON. */
  named(name: string, data: unknown): void {
    this.#push(
      new TextEncoder().encode(`event: ${name}\ndata: ${JSON.stringify(data)}\n\n`)
    );
  }

  end(): void {
    this.#push(null);
    this.closed = true;
  }

  fail(message = "stream broke"): void {
    this.#push(new HostError(message));
    this.closed = true;
  }

  get take(): Effect.Effect<Uint8Array | null, HostError> {
    return Effect.callback<Uint8Array | null, HostError>((resume) => {
      const deliver = (piece: Uint8Array | null | HostError) =>
        resume(piece instanceof HostError ? Effect.fail(piece) : Effect.succeed(piece));
      if (this.#queue.length > 0) deliver(this.#queue.shift()!);
      else this.#waiting = deliver;
    });
  }
}

export class FakeCommaApi {
  readonly requests: SeenRequest[] = [];
  /** Event streams opened, in order. */
  readonly streams: FakeStream[] = [];
  readonly #streamPaths = new Map<string, number>();
  readonly #handlers: [string, string, Handler][] = [];
  readonly #holds: [string, string, Deferred.Deferred<void>][] = [];
  readonly #bodyHolds: [string, string, Deferred.Deferred<void>][] = [];

  on(method: string, path: string, handler: Handler): this;
  /** A fixed answer: a response, no answer (`offline()`), or a value answered as JSON with 200. */
  on(method: string, path: string, answer: unknown): this;
  on(method: string, path: string, handler: unknown): this {
    const run: Handler =
      typeof handler === "function"
        ? (handler as Handler)
        : handler instanceof HostError || isResponse(handler)
          ? () => handler as Answer
          : () => json(200, handler);
    this.#handlers.unshift([method, path, run]);
    return this;
  }

  /** Answers GET `path` as an event stream the test feeds (`open`), or refuses it with `status`. */
  onStream(path: string, status = 200): this {
    this.#streamPaths.set(path, status);
    return this;
  }

  /** The stream open now on `path`, if one is. */
  open(path: string): FakeStream | undefined {
    return this.streams.findLast((s) => s.path === path && !s.closed);
  }

  /** Opens a stream on `request`'s path; null when the path is no stream. */
  stream(
    request: ApiRequest
  ): Effect.Effect<{ status: number; body: FakeStream } | null, never, Scope.Scope> {
    return Effect.gen({ self: this }, function* () {
      const bare = request.path.split("?")[0]!;
      const status = this.#streamPaths.get(bare);
      if (status === undefined) return null;
      this.requests.push({
        method: request.method,
        path: request.path,
        headers: request.headers,
        body: undefined,
        lease: request.lease,
      });
      const stream = new FakeStream(bare);
      if (status !== 200) stream.end();
      this.streams.push(stream);
      yield* Effect.addFinalizer(() => Effect.sync(() => (stream.closed = true)));
      return { status, body: stream };
    });
  }

  /** Holds the next answer to `method path` until the returned function is called. */
  hold(method: string, path: string): () => void {
    const d = Deferred.makeUnsafe<void>();
    this.#holds.push([method, path, d]);
    return () => Deferred.doneUnsafe(d, Effect.void);
  }

  /**
   * Holds the body of the next answer to `method path` until the returned function is called: the server has
   * answered (its handler ran), the body has not all arrived.
   */
  holdBody(method: string, path: string): () => void {
    const d = Deferred.makeUnsafe<void>();
    this.#bodyHolds.push([method, path, d]);
    return () => Deferred.doneUnsafe(d, Effect.void);
  }

  /** The requests made to `method path` (the path without its query). */
  seen(method: string, path: string): SeenRequest[] {
    return this.requests.filter(
      (r) => r.method === method && matches(path, r.path.split("?")[0]!)
    );
  }

  /** Answers an auth request (the Cookie's): seen with its expected session, its headers as the host sends them. */
  answerAuth(request: AuthRequest): Effect.Effect<ApiResponse, HostError> {
    return this.answer(
      { ...request, headers: authHeaders(request), lease: NO_LEASE },
      request.expectedSessionId
    );
  }

  answer(
    request: ApiRequest,
    expected?: string
  ): Effect.Effect<ApiResponse, HostError> {
    return Effect.gen({ self: this }, function* () {
      const isJson = request.headers.some(
        ([k, v]) => k === "content-type" && v.startsWith("application/json")
      );
      const text = request.body && isJson ? new TextDecoder().decode(request.body) : "";
      const seen: SeenRequest = {
        method: request.method,
        path: request.path,
        body: isJson
          ? text
            ? JSON.parse(text)
            : undefined
          : (request.body ?? undefined),
        headers: request.headers,
        lease: request.lease,
        ...(expected !== undefined ? { expected } : {}),
      };
      this.requests.push(seen);
      const bare = request.path.split("?")[0]!;
      const at = this.#holds.findIndex(
        ([m, p]) => m === request.method && matches(p, bare)
      );
      if (at >= 0) yield* Deferred.await(this.#holds.splice(at, 1)[0]![2]);
      const handler = this.#handlers.find(
        ([m, p]) => m === request.method && matches(p, bare)
      )?.[2];
      const answer = handler
        ? yield* Effect.promise(async (signal) => handler(seen, signal))
        : json(404, { error: "not_found" });
      if (answer instanceof HostError) return yield* answer;
      const body = this.#bodyHolds.findIndex(
        ([m, p]) => m === request.method && matches(p, bare)
      );
      if (body >= 0) yield* Deferred.await(this.#bodyHolds.splice(body, 1)[0]![2]);
      return answer;
    });
  }
}

/**
 * A Comma API answered by this thread's `fetch` at `origin` (a UI test that stubs `fetch`, as its UI's own requests
 * were stubbed before the core made them).
 */
export function fetchedApi(origin = "https://api.comma.test"): FakeCommaApi {
  const api = new FakeCommaApi();
  for (const method of ["GET", "POST", "PUT", "PATCH", "DELETE"]) {
    api.on(
      method,
      "/*",
      async (request: SeenRequest, signal: AbortSignal): Promise<Answer> => {
        try {
          const bytes = request.body instanceof Uint8Array;
          const type = request.headers?.find(([k]) => k === "content-type")?.[1];
          const response = await globalThis.fetch(`${origin}${request.path}`, {
            method,
            headers:
              request.body === undefined
                ? {}
                : { "content-type": bytes && type ? type : "application/json" },
            ...(request.body === undefined
              ? {}
              : {
                  body: bytes
                    ? (request.body as Uint8Array<ArrayBuffer>)
                    : JSON.stringify(request.body),
                }),
            signal,
          });
          return {
            status: response.status,
            headers: [...response.headers],
            body: new Uint8Array(await response.arrayBuffer()),
          };
        } catch (error) {
          return new HostError(error instanceof Error ? error.message : String(error));
        }
      }
    );
  }
  return api;
}

function matches(pattern: string, path: string): boolean {
  return pattern.endsWith("*")
    ? path.startsWith(pattern.slice(0, -1))
    : pattern === path;
}

function isResponse(v: unknown): v is ApiResponse {
  return (
    typeof v === "object" &&
    v !== null &&
    "status" in v &&
    "body" in v &&
    (v as { body: unknown }).body instanceof Uint8Array
  );
}

/**
 * Web Locks in memory: exclusive, granted in the order asked. `hold` takes one as another context would (a page on
 * the adapter); `unsupported` makes them missing (a browser without Web Locks).
 */
export class FakeLocks {
  /** Every lock asked for, by name, in order. */
  readonly requests: string[] = [];
  unsupported = false;
  readonly #held = new Set<string>();
  readonly #waiting = new Map<string, (() => void)[]>();

  /** How many locks are held now. */
  get active(): number {
    return this.#held.size;
  }

  lock(name: string): Effect.Effect<() => void, HostError> {
    return Effect.callback<() => void, HostError>((resume) => {
      this.requests.push(name);
      if (this.unsupported) {
        resume(Effect.fail(new HostUnsupported("Web Locks are not available")));
        return;
      }
      const grant = () => resume(Effect.succeed(this.#releaser(name)));
      if (!this.#held.has(name)) {
        this.#held.add(name);
        grant();
        return;
      }
      const queue = this.#waiting.get(name) ?? [];
      this.#waiting.set(name, queue);
      queue.push(grant);
      return Effect.sync(() => {
        const at = queue.indexOf(grant);
        if (at >= 0) queue.splice(at, 1);
      });
    });
  }

  /** Takes `name` as another context would, until the function returned is called. */
  hold(name: string): () => void {
    let release: (() => void) | null = null;
    Effect.runFork(this.lock(name).pipe(Effect.map((r) => (release = r))));
    return () => release?.();
  }

  #releaser(name: string): () => void {
    let done = false;
    return () => {
      if (done) return;
      done = true;
      const next = this.#waiting.get(name)?.shift();
      if (next) next();
      else this.#held.delete(name);
    };
  }
}

/** BroadcastChannels in memory: a post reaches the other endpoints of its name (not its own), at once. */
export class FakeHints {
  /** What the core posted, in order. */
  readonly posted: unknown[] = [];
  readonly #listeners = new Map<
    string,
    Set<{ from: object; listener: (m: unknown) => void }>
  >();

  open(name: string): HintChannel {
    const self = {};
    const listeners = this.#listeners.get(name) ?? new Set();
    this.#listeners.set(name, listeners);
    const mine = new Set<{ from: object; listener: (m: unknown) => void }>();
    return {
      post: (message) => {
        this.posted.push(structuredClone(message));
        for (const entry of listeners)
          if (entry.from !== self) entry.listener(structuredClone(message));
      },
      listen: (listener) => {
        const entry = { from: self, listener };
        listeners.add(entry);
        mine.add(entry);
        return () => {
          listeners.delete(entry);
          mine.delete(entry);
        };
      },
      close: () => {
        for (const entry of mine) listeners.delete(entry);
        mine.clear();
      },
    };
  }

  /** A hint from another context (a page on the adapter): every endpoint of `name` hears it (of any name, with none). */
  send(name: string | null, message: unknown): void {
    const all =
      name === null
        ? [...this.#listeners.values()].flatMap((set) => [...set])
        : [...(this.#listeners.get(name) ?? [])];
    for (const entry of all) entry.listener(structuredClone(message));
  }
}

/**
 * The host's download storage in memory (`DownloadPorts`): each download is the fake API's answer to its request, kept
 * by path once it is whole.
 */
export class FakeDownloads implements DownloadPorts {
  readonly files = new Map<string, Uint8Array>();
  readonly #api: FakeCommaApi;
  readonly #open = new Map<number, { path: string; body: Uint8Array; told: boolean }>();
  #next = 1;

  constructor(api: FakeCommaApi) {
    this.#api = api;
  }

  open(request: ApiRequest, path: string) {
    return Effect.map(this.#api.answer(request), (response) => {
      if (response.status !== 200)
        return { id: 0, status: response.status, total: null };
      const id = this.#next++;
      this.#open.set(id, { path, body: response.body, told: false });
      return { id, status: 200, total: response.body.length };
    });
  }

  /** The whole body arrived at once: told once, then put in place. */
  step(id: number) {
    return Effect.sync(() => {
      const open = this.#open.get(id);
      if (!open) throw new HostError("no such download");
      if (!open.told) {
        open.told = true;
        return { received: open.body.length };
      }
      this.#open.delete(id);
      this.files.set(open.path, open.body);
      return {
        size: open.body.length,
        sha256: createHash("sha256").update(open.body).digest("hex"),
      };
    });
  }

  close(id: number) {
    return Effect.sync(() => void this.#open.delete(id));
  }

  remove(path: string): Effect.Effect<void, HostError> {
    return Effect.sync(() => {
      for (const file of this.files.keys())
        if (file === path || file.startsWith(`${path}/`)) this.files.delete(file);
    });
  }

  retain(keep: string | null): Effect.Effect<void, HostError> {
    return Effect.sync(() => {
      for (const file of this.files.keys())
        if (keep === null || !file.startsWith(`${keep}/`)) this.files.delete(file);
    });
  }
}

export class FakeHost implements Host {
  /** This installation's Drive node, when a test gives one (`FakeLocalDrive`). */
  localDrive?: LocalDrivePorts;
  /** Direct connections to stations, when a test gives them (`FakeStations`). */
  stationMesh?: StationMeshPorts;
  readonly sessionSource: "host" | "core";
  readonly api: FakeCommaApi;
  readonly time: TestTime | null;
  readonly storage: Map<string, Uint8Array>;
  /** What fails in device storage now (a full or broken store). */
  readonly storageFails = { reads: false, writes: false };
  readonly locks: FakeLocks;
  readonly hints: FakeHints;
  /** The web session's ports: Web Locks and hints in memory (a replay serves them from its log). */
  webSession: WebSessionPorts;
  /** Main's session ports (Electron): a test gives them (`FakeMain`) to run the Electron session lifecycle. */
  bearerSession?: BearerSessionPorts;
  /** The desktop app's ports: a test gives them (`FakeDesktop`). */
  desktop?: DesktopPorts;
  /** Downloads to the device's storage: a test gives them (`FakeDownloads`). */
  downloads?: DownloadPorts;
  /** The accounts' databases, in memory, by name: a core started again on this host opens the same. */
  readonly dbs = new Map<string, NodeSql>();
  readonly deleted: string[] = [];
  /** What opening a database does instead (a file another app holds). */
  openDbHook: ((name: string) => Error | null) | null = null;
  /** How long opening a database takes (the web's takes a moment). */
  openDbMs = 0;
  #listeners = new Map<ClientId, (message: CoreMessage) => void>();
  emitted: [ClientId, CoreMessage][] = [];
  /** The lists a host kept before the core: a fake host has none unless a test gives them. */
  legacyTasks?: NonNullable<Host["legacyTasks"]>;
  /** Main's meeting recorder parts: a fake host has none unless a test gives them (`FakeMeetingMain`). */
  meeting?: MeetingPorts;
  /** How many times the app's reset asked this host for a new core (`ResetPorts.restart`). */
  restarts = 0;
  /**
   * The app reset: its storage and databases cleared as Electron's host clears its directory, and a new core asked
   * for (counted: a test starts it).
   */
  reset: ResetPorts | undefined = {
    clear: Effect.sync(() => {
      this.storage.clear();
      for (const [name, db] of this.dbs) {
        db.db.close();
        this.deleted.push(name);
      }
      this.dbs.clear();
    }),
    restart: Effect.sync(() => {
      this.restarts += 1;
    }),
  };
  /** A host's image capabilities: a fake host has none unless a test gives them. */
  renderImagePreview?: NonNullable<Host["renderImagePreview"]>;
  transcodeImage?: NonNullable<Host["transcodeImage"]>;

  /** `time`: a TestTime the test moves; null runs on the real clock (a UI test). */
  constructor(
    options: {
      time?: TestTime | null;
      api?: FakeCommaApi;
      sessionSource?: "host" | "core";
      /** Device storage, locks and hints another host has too (the next tab's worker). */
      storage?: Map<string, Uint8Array>;
      locks?: FakeLocks;
      hints?: FakeHints;
      /** Where its random bytes start (another tab's worker draws other bytes than this one's). */
      randomFrom?: number;
    } = {}
  ) {
    this.#randomCalls = options.randomFrom ?? 0;
    this.time = options.time === undefined ? new TestTime() : options.time;
    this.api = options.api ?? new FakeCommaApi();
    this.sessionSource = options.sessionSource ?? "host";
    this.storage = options.storage ?? new Map();
    this.locks = options.locks ?? new FakeLocks();
    this.hints = options.hints ?? new FakeHints();
    this.webSession = {
      apiOrigin: "https://api.comma.test",
      userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
      lock: (name) => this.locks.lock(name),
      channel: (name) => this.hints.open(name),
      sha256: (inputs) =>
        Effect.sync(() =>
          inputs.map(
            (input) =>
              new Uint8Array(createHash("sha256").update(input, "utf8").digest())
          )
        ),
    };
  }

  authFetch(request: AuthRequest): Effect.Effect<ApiResponse, HostError> {
    return this.api.answerAuth(request);
  }

  fetch(request: ApiRequest): Effect.Effect<ApiResponse, HostError> {
    return this.api.answer(request);
  }

  fetchStream(
    request: ApiRequest
  ): Effect.Effect<StreamResponse, HostError, Scope.Scope> {
    return this.api.stream(request).pipe(
      Effect.flatMap((open) =>
        open
          ? Effect.succeed({
              status: open.status,
              headers: [["content-type", "text/event-stream"]] as [string, string][],
              body: open.body as Pull<Uint8Array>,
            })
          : this.#answerAsStream(request)
      )
    );
  }

  #answerAsStream(request: ApiRequest): Effect.Effect<StreamResponse, HostError> {
    return this.api.answer(request).pipe(
      Effect.map((response) => {
        let sent = false;
        return {
          status: response.status,
          headers: response.headers,
          body: {
            take: Effect.sync(() => (sent ? null : ((sent = true), response.body))),
          },
        };
      })
    );
  }

  storageGet(key: string): Effect.Effect<Uint8Array | null, HostError> {
    return this.storageFails.reads
      ? Effect.fail(new HostError("the device storage cannot be read"))
      : Effect.sync(() => this.storage.get(key) ?? null);
  }
  storageSet(key: string, value: Uint8Array): Effect.Effect<void, HostError> {
    return this.storageFails.writes
      ? Effect.fail(new HostError("the device storage is full"))
      : Effect.sync(() => void this.storage.set(key, value));
  }
  storageDelete(key: string): Effect.Effect<void, HostError> {
    return this.storageFails.writes
      ? Effect.fail(new HostError("the device storage is full"))
      : Effect.sync(() => void this.storage.delete(key));
  }

  openDb(name: string): Effect.Effect<Sql, HostError> {
    const open = Effect.suspend(() => {
      const refused = this.openDbHook?.(name);
      if (refused) return Effect.fail(new HostError(refused.message));
      let db = this.dbs.get(name);
      if (!db) {
        db = NodeSql.memory(true);
        this.dbs.set(name, db);
      }
      return Effect.succeed(db as Sql);
    });
    return this.openDbMs > 0 ? Effect.andThen(Effect.sleep(this.openDbMs), open) : open;
  }

  get memoryDb(): Effect.Effect<Sql, HostError> {
    return Effect.sync(() => NodeSql.memory() as Sql);
  }

  deleteDb(name: string): Effect.Effect<void, HostError> {
    return Effect.sync(() => {
      this.dbs.get(name)?.db.close();
      this.dbs.delete(name);
      this.deleted.push(name);
    });
  }

  /** Calls so far: each asks for different bytes, the same ones every run. */
  #randomCalls: number;

  get yieldTurn(): Effect.Effect<void> {
    return Effect.callback<void>((resume) => {
      const handle = setImmediate(() => resume(Effect.void));
      return Effect.sync(() => clearImmediate(handle));
    });
  }

  randomBytes(buf: Uint8Array): void {
    const call = this.#randomCalls++;
    for (let i = 0; i < buf.length; i++) buf[i] = (i * 31 + 7 + call * 101) & 0xff;
  }

  emit(client: ClientId, message: CoreMessage): void {
    // As a port or a worker carries it: a structured clone (bytes stay bytes).
    const copy = structuredClone(message);
    this.emitted.push([client, copy]);
    this.#listeners.get(client)?.(copy);
  }

  /** Where a client's messages go (the in-process channel). */
  listen(client: ClientId, listener: ((message: CoreMessage) => void) | null): void {
    if (listener) this.#listeners.set(client, listener);
    else this.#listeners.delete(client);
  }
}

/** A session as Electron's Main or the web's adapter says it: signed in as `userId`. */
export function signedIn(
  userId = "user-1",
  options: { sessionId?: string; generation?: number; audience?: string } = {}
) {
  const audience = options.audience ?? "https://api.comma.test";
  const generation = options.generation ?? 1;
  return {
    authority: { authorityInstanceId: "authority-1", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation,
    revision: generation,
    phase: "signed_in",
    principal: { email: `${userId}@example.test`, userId },
    session: {
      audience,
      expiresAtEpochSeconds: 4_000_000_000,
      sessionId: options.sessionId ?? `session-${userId}`,
    },
  };
}

export function signedOut(generation = 2) {
  return {
    authority: { authorityInstanceId: "authority-1", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation,
    revision: generation,
    phase: "signed_out",
    principal: null,
    reason: "user_signed_out",
    session: null,
  };
}

/** The product request `productCall` makes: a POST to the account's workspace `ws-1` (its browser storage cleared). */
export const PRODUCT_PATH = "/v1/comma/workspaces/ws-1/browsers/clear-storage";

/**
 * A product request a UI asks the core for (`browser.clearStorage`): made with the session's account and the lease
 * given now, as any topic's. Its outcome as a Result: the core's answer, or the error it answered.
 */
export function productCall(
  client: CoreClient
): Promise<Result.Result<unknown, CoreError>> {
  return client.call("browser.clearStorage", { workspace: "ws-1" }).then(
    (value) => Result.succeed(value),
    (error: CoreError) => Result.fail(error)
  );
}

/**
 * A core on a fake host; `coalesceMs` 0 sends each change at once (a UI test, which moves time only when it says);
 * `limits` lowers a read limit, so a test reaches it in a few reads.
 */
export function startTestCore(
  host: FakeHost = new FakeHost(),
  options: {
    coalesceMs?: number;
    limits?: Partial<CoreLimits>;
    /**
     * false: a UI test's core, whose inputs come as the page's real timers and renders bring them (the test does not
     * move time for them): its run is not played again.
     */
    replays?: boolean;
  } = {}
): Core {
  // Every test core records what it is told; a failed test shows the log, which `replay` can play again.
  const recorder = new Recorder();
  try {
    onTestFailed(() => {
      console.error(
        `The core's log (replay it with testing/replay.ts):\n${recorder.dump()}`
      );
    });
    if (options.replays !== false) {
      if (process.env.CORE_GOLDEN_WRITE) keepGolden(recorder, host, options);
      playsAgain(recorder, host, options);
    }
  } catch {
    // Not inside a test (a helper made at load): nothing to show it on.
  }
  const { replays: _replays, ...coreOptions } = options;
  const core = new Core(host, {
    ...(host.time ? { clock: host.time.clock } : {}),
    recorder,
    ...coreOptions,
  });
  // A fiber that ends in a failure is a bug (a native host starts the core anew for it): the test fails.
  const defects: unknown[] = [];
  const told = core.runner.onDefect;
  core.runner.onDefect = (error) => {
    defects.push(error);
    told(error);
  };
  try {
    // A test that timed out runs on: its clock stops, so it does not slow the tests after it.
    if (host.time) onTestFinished(() => host.time?.end());
    onTestFinished(() => {
      if (defects.length > 0)
        throw new Error(`The core's fibers failed: ${defects.map(String).join("; ")}`);
    });
  } catch {
    // Not inside a test.
  }
  return core;
}

/**
 * A channel to `core` in this thread, for a CoreClient (`new CoreClient(inProcessOpener(core, host))`): messages go
 * both ways on the next turn, cloned, as they would through a port.
 */
export function inProcessOpener(
  core: Core,
  host: FakeHost,
  surface?: string,
  options: { host?: boolean } = {}
) {
  return (onMessage: (data: unknown) => void) => {
    // `surface`: a window's channel, as Electron's Main hands it over (it acts only as that window). `host`: Main's own.
    const client = core.connect(surface, options.host ? { host: true } : {});
    let open = true;
    host.listen(client, (message) => queueMicrotask(() => open && onMessage(message)));
    return {
      post(message: unknown) {
        const copy = structuredClone(message);
        queueMicrotask(() => {
          if (!open) return;
          if (typeof copy === "object" && copy !== null && "bye" in copy)
            core.disconnect(client);
          else core.receive(client, copy);
        });
      },
      close() {
        open = false;
        host.listen(client, null);
        core.disconnect(client);
      },
    };
  };
}

/** A space of a `FakeLocalDrive`: its entries and how this install holds it. */
export interface FakeDriveSpace extends Omit<LocalDriveSpace, "id"> {
  entries: DriveEntry[];
}

/**
 * A local Drive node in memory: spaces of entries a test sets (this install's origin is `here`), listed in pages, and
 * `change` to say they changed. Its operations do what the node would to the entries and the bytes (`contents`, by
 * `<space>/<path>`), and each is noted in `ran`; an op in `refuse` fails. `reads` counts state reads and `pages` the
 * listings asked for; `hold` keeps answers until `release`.
 */
export class FakeLocalDrive implements LocalDrivePorts {
  status: LocalDriveState["status"] = "ready";
  reason: string | undefined;
  defaultSpace = "drive";
  origin = "here";
  origins: string[] = ["here"];
  deviceName = "This test";
  domain = "";
  localRoot = "~/Drive";
  readonly pins = new Set<string>();
  readonly spaces = new Map<string, FakeDriveSpace>();
  /** The bytes of each path, by `<space>/<path>`; a path without any reads as zeros of its size. */
  readonly contents = new Map<string, Uint8Array>();
  /** The versions of a path that has more than one, by `<space>/<path>`. */
  readonly versions = new Map<string, LocalDriveVersion[]>();
  /** What the person picks in the folder dialog. */
  picked: string | null = null;
  /** The files windows staged with Main, by reference. */
  readonly staged = new Map<string, Uint8Array>();
  /** What was saved into Downloads, in order. */
  readonly downloaded: { fileName: string; content: Uint8Array }[] = [];
  /** The operations asked for, in order. */
  readonly ran: [LocalDriveOp, unknown][] = [];
  readonly refuse = new Set<LocalDriveOp>();
  pageSize = 500;
  reads = 0;
  pages = 0;
  #held: (() => void)[] | null = null;
  readonly #listeners = new Set<() => void>();

  /** A file entry at `path`, modified at `mtimeMs`. */
  static file(
    path: string,
    mtimeMs: number,
    extra: Partial<DriveEntry> = {}
  ): DriveEntry {
    return {
      contentRoot: `root-${path}`,
      kind: "file",
      mtimeMs,
      origin: "here",
      path,
      size: 1,
      versions: 1,
      ...extra,
    };
  }

  /** A space this install publishes (the default one at `~/Drive`), unless `space` says otherwise. */
  put(
    space: string,
    entries: DriveEntry[],
    label?: string,
    settings: Partial<FakeDriveSpace> = {}
  ): void {
    this.spaces.set(space, {
      label: label ?? "",
      autoAdopt: false,
      checkoutPath: "",
      sourcePath: space === this.defaultSpace ? this.localRoot : "",
      replica: false,
      writable: true,
      ...settings,
      entries,
    });
  }

  change(): void {
    for (const listener of this.#listeners) listener();
  }

  /** Answers wait from now until `release`. */
  hold(): void {
    this.#held ??= [];
  }

  /** How many answers wait for `release`. */
  get waiting(): number {
    return this.#held?.length ?? 0;
  }

  release(): void {
    const held = this.#held ?? [];
    this.#held = null;
    for (const go of held) go();
  }

  #answer<A>(make: () => A): Effect.Effect<A, HostError> {
    return Effect.callback<A, HostError>((resume) => {
      const go = () => {
        try {
          const value = make();
          resume(Effect.succeed(value));
        } catch (error) {
          resume(
            Effect.fail(
              error instanceof HostError ? error : new HostError(String(error))
            )
          );
        }
      };
      if (this.#held) this.#held.push(go);
      else go();
    });
  }

  #state(): LocalDriveState {
    return {
      status: this.status,
      ...(this.reason ? { reason: this.reason } : {}),
      defaultSpace: this.defaultSpace,
      spaces: [...this.spaces].map(([id, { entries: _entries, ...space }]) => ({
        id,
        ...space,
      })),
      origin: this.origin,
      origins: this.origins,
      deviceName: this.deviceName,
      domain: this.domain,
      localRoot: this.localRoot,
      pins: [...this.pins],
    };
  }

  get state(): Effect.Effect<LocalDriveState, HostError> {
    return this.#answer(() => {
      this.reads += 1;
      return this.#state();
    });
  }

  list(input: LocalDriveListInput): Effect.Effect<LocalDriveListResult, HostError> {
    return this.#answer(() => {
      this.pages += 1;
      const entries = (this.spaces.get(input.space)?.entries ?? []).filter(
        (entry) => !input.prefix || entry.path.startsWith(input.prefix)
      );
      const from = input.cursor ? Number(input.cursor) : 0;
      const to = from + Math.min(input.limit, this.pageSize);
      return {
        entries: entries.slice(from, to),
        nextCursor: to < entries.length ? String(to) : "",
      };
    });
  }

  #space(id: string): FakeDriveSpace {
    const space = this.spaces.get(id);
    if (!space) throw new HostError(`no space ${id}`);
    return space;
  }

  #entry(space: string, path: string): DriveEntry {
    const entry = this.#space(space).entries.find((e) => e.path === path);
    if (!entry) throw new HostError(`no file ${space}/${path}`);
    return entry;
  }

  run<O extends LocalDriveOp>(
    op: O,
    input: LocalDriveOps[O]["input"]
  ): Effect.Effect<LocalDriveOps[O]["result"], HostError> {
    return this.#answer(() => {
      this.ran.push([op, input]);
      if (this.refuse.has(op)) throw new HostError(`${op} refused`);
      return this.#run(op, input as never) as LocalDriveOps[O]["result"];
    });
  }

  #run(op: LocalDriveOp, input: Record<string, unknown>): unknown {
    const space = String(input.space ?? "");
    const path = String(input.path ?? "");
    switch (op) {
      case "versions": {
        const entry = this.#entry(space, path);
        return (
          this.versions.get(`${space}/${path}`) ?? [
            {
              attestors: [entry.origin],
              kind: "file",
              root: entry.contentRoot,
              seq: 1,
              size: entry.size,
            },
          ]
        );
      }
      case "read": {
        const entry = this.#entry(space, path);
        const bytes =
          this.contents.get(`${space}/${path}`) ?? new Uint8Array(entry.size);
        const offset = Number(input.offset);
        const content = bytes.slice(offset, offset + Number(input.length));
        return {
          content,
          contentRoot: entry.contentRoot,
          size: bytes.length,
          offset,
          eof: offset + content.length >= bytes.length,
        };
      }
      case "write": {
        const content = input.content as Uint8Array;
        const entries = this.#space(space).entries.filter((e) => e.path !== path);
        entries.push(
          FakeLocalDrive.file(path, 0, {
            contentRoot: `root-${path}-${content.length}`,
            origin: this.origin,
            size: content.length,
          })
        );
        this.#space(space).entries = entries;
        this.contents.set(`${space}/${path}`, content);
        return null;
      }
      case "delete":
        this.#entry(space, path);
        this.#space(space).entries = this.#space(space).entries.filter(
          (e) => e.path !== path
        );
        return null;
      case "adopt": {
        const entry = this.#entry(space, path);
        const at = this.#space(space).entries.indexOf(entry);
        this.#space(space).entries[at] = { ...entry, origin: this.origin, versions: 1 };
        this.versions.delete(`${space}/${path}`);
        return { skipped: false };
      }
      case "adoptTree": {
        const counts = { adopt: 0, current: 0, differing: 0, skipped: 0 };
        for (const entry of this.#space(space).entries)
          if (entry.versions > 1) counts.differing += 1;
          else if (entry.origin === this.origin) counts.current += 1;
          else counts.adopt += 1;
        return counts;
      }
      case "pin":
        if (input.action === "add") this.pins.add(`${space}/${path}`);
        else this.pins.delete(`${space}/${path}`);
        return null;
      case "sourceAdd":
        this.put(space, [], "", { sourcePath: path });
        return null;
      case "sourceRemove":
        this.spaces.delete(space);
        return null;
      case "replicaSet":
        Object.assign(this.#space(space), {
          checkoutPath: input.checkoutPath,
          replica: input.checkoutPath !== "",
        });
        return null;
      case "setSpaceSettings":
        Object.assign(this.#space(space), {
          ...(input.label === undefined ? {} : { label: input.label }),
          ...(input.syncEnabled === undefined
            ? {}
            : { autoAdopt: input.syncEnabled, sourcePaused: !input.syncEnabled }),
        });
        return this.#state();
      case "restart":
        this.status = "ready";
        this.reason = undefined;
        return this.#state();
      case "setDomain":
        this.domain = String(input.domain);
        this.origin = `here@${this.domain}`;
        this.origins = [this.origin];
        return this.#state();
      case "pickFolder":
        return this.picked;
      case "saveDownload": {
        const entry = this.#entry(space, path);
        const fileName = String(input.fileName);
        this.downloaded.push({
          fileName,
          content: this.contents.get(`${space}/${path}`) ?? new Uint8Array(entry.size),
        });
        return { downloadRef: `download:${fileName}`, fileName };
      }
      case "importStaged": {
        const content = this.staged.get(String(input.ref));
        if (!content) throw new HostError("The staged file is no longer kept.");
        return this.#run("write", { space, path, content });
      }
      case "releaseStaged":
        for (const ref of input.refs as string[]) this.staged.delete(ref);
        return null;
    }
  }

  onChange(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => void this.#listeners.delete(listener);
  }
}

const goldenCounts = new Map<string, number>();

/**
 * With `CORE_GOLDEN_WRITE` set, a passing test's log is kept as a golden run under `test/golden/<file>/`: what the core
 * was told and what it did, which `test/golden.test.ts` plays again on every change to the core. A refactor that keeps
 * the core's behavior plays every golden run to the same outputs at the same times.
 */
function keepGolden(
  recorder: Recorder,
  host: FakeHost,
  options: { coalesceMs?: number; limits?: Partial<CoreLimits> }
): void {
  const state = expect.getState();
  const file = state.testPath;
  const name = state.currentTestName;
  if (!file || !name) return;
  onTestFinished((context) => {
    if (context.task.result?.state !== "pass") return;
    const slug = name
      .replace(/[^\p{L}\p{N}]+/gu, "-")
      .replace(/^-|-$/g, "")
      .slice(0, 120);
    const key = `${file}\n${slug}`;
    const n = goldenCounts.get(key) ?? 0;
    goldenCounts.set(key, n + 1);
    const dir = join(
      dirname(file),
      "golden",
      basename(file).replace(/\.test\.ts$/, "")
    );
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, `${slug}${n ? `-${n}` : ""}.json`),
      `${JSON.stringify(
        {
          test: name,
          sessionSource: host.sessionSource,
          ...(options.coalesceMs !== undefined
            ? { coalesceMs: options.coalesceMs }
            : {}),
          ...(options.limits ? { limits: options.limits } : {}),
          until: host.time?.now() ?? 0,
          inputs: recorder.inputs,
          outputs: recorder.outputs,
        },
        goldenBytes
      )}\n`
    );
  });
}

/** Bytes in a golden run's JSON: `{"$u8": base64}` (a UI's message may carry them). */
export function goldenBytes(_key: string, value: unknown): unknown {
  return value instanceof Uint8Array ? { $u8: base64(value) } : value;
}

export function goldenBytesBack(_key: string, value: unknown): unknown {
  return value !== null &&
    typeof value === "object" &&
    "$u8" in value &&
    Object.keys(value).length === 1
    ? fromBase64((value as { $u8: string }).$u8)
    : value;
}

/**
 * Test files whose runs do not play again exactly yet: an input reaches their cores unrecorded (each is being fixed).
 * The list only shrinks.
 */
const REPLAY_GAPS = new Set([
  // Two tests call TaskSummaries.invalidate/record directly, not through an input the core takes.
  "task-summaries.test.ts",
]);

/**
 * After a passing test, its core's log is played again on a new core: the same inputs at the same times must give the
 * same outputs, or the test fails. An input the core takes unrecorded (a direct call, the wall clock, a host answer
 * the recorder misses) shows here, in the test that brought it.
 */
function playsAgain(
  recorder: Recorder,
  host: FakeHost,
  options: { coalesceMs?: number; limits?: Partial<CoreLimits> }
): void {
  const file = expect.getState().testPath;
  if (!host.time || !file || REPLAY_GAPS.has(basename(file))) return;
  onTestFinished(async (context) => {
    if (context.task.result?.state !== "pass") return;
    const { comparable, replay } = await import("./replay.ts");
    const log = { inputs: [...recorder.inputs], outputs: [...recorder.outputs] };
    const again = await replay(log, {
      sessionSource: host.sessionSource,
      ...(options.coalesceMs !== undefined ? { coalesceMs: options.coalesceMs } : {}),
      ...(options.limits ? { limits: options.limits } : {}),
      until: host.time?.now() ?? 0,
    });
    expect(comparable(again.outputs), "the core's run, played again").toEqual(
      comparable(log.outputs)
    );
  });
}
