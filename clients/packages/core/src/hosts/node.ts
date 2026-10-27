// The core in Electron's utility process. Main starts it with its data directory and where Main's session gate is,
// and hands it a port for each window that opens a channel. The core runs the session lifecycle
// (session/electron-lifecycle.ts) against Main's ports, over the parent port: the auth requests (Main attaches the
// credential they name and keeps any bearer an answer carries), Main's credential store by reference, the gate (told
// each snapshot before anything acts on it) and the Google window. Its product requests go to Main too: Main sends
// them through its `/v1` proxy, which adds the bearer only Main holds and refuses one made for a lease its gate does
// not hold, and streams the answer back. Its databases are SQLite files (node:sqlite) in the directory Main gives it,
// one per account, and a device database for small values.
//
// Main → core: `{type: "start", dataDir, session}`, `{type: "client"}` with a port, each request's answer:
// `{type: "head", id, status, headers}`, `{type: "chunk", id, bytes}`, `{type: "end", id}`, `{type: "fail", id,
// message}`, each session port's `{type: "session-done", id, value | error}`, `{type: "rejected", lease, status}`, each
// meeting command's `{type: "meeting-done", id, answer | error}` and what Main's meeting parts saw (`meeting-event`).
// Core → Main: `{type: "fetch", id, method, path, headers, body, lease}`, `{type: "session", id, op, input}`,
// `{type: "gate", snapshot, lease}`, `{type: "abort", id}`, `{type: "session-dropped", id}`, `{type: "meeting", id, op,
// input}`, and `{type: "reset"}` once the core cleared what it keeps (`app.reset`: Main resets the app and starts a new
// core). When Main runs the Drive node: `{type: "drive", id, op, input}` from the core, `{type: "drive-done", id,
// value | error}` and `{type: "drive-changed"}` from Main.
//
// The desktop ports (`DesktopPorts`): the person's presence, the system browser, the app's return and the chat file
// picker are Main's (`session` ops `presence`, `openExternal`, `returnToApp`, `chatPick`); the loopback listener a browser returns to
// (hosts/loopback.ts, with the pages Main rendered at the start), a provider's request and SHA-256 are this process's.
import {
  HostError,
  type ClientId,
  type CoreMessage,
  type Sql,
} from "@comma/core-kernel";
import { NodeSql } from "@comma/core-kernel/node-sql";
import { settle, TestTime } from "@comma/core-kernel/testing";
import { Effect, type Scope } from "effect";
import { createHash, randomFillSync } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { join as joinPath } from "node:path";
import { Core } from "../core.ts";
import { createDarwinImageTranscoder } from "./image-transcoder.ts";
import { listenLoopback } from "./loopback.ts";
import { meshStationLinks } from "./mesh.ts";
import {
  CORE_START,
  type CoreToMain,
  type MainToCore,
  type MeetingAnswer,
  type MeetingEvent,
  type VoiceCallSocketEvent,
  type UtilitySessionAnswer,
  type UtilityDesktopStart,
  type UtilitySessionCall,
  type UtilitySessionStart,
} from "./utility-protocol.ts";

export { CORE_START, type CoreToMain, type MainToCore };
import type {
  ApiRequest,
  ApiResponse,
  AuthRequest,
  BearerSessionPorts,
  ClientIdentity,
  DesktopPorts,
  Host,
  LegacyWorkspaceTasks,
  LocalDriveListInput,
  LocalDriveListResult,
  LocalDriveOp,
  LocalDrivePorts,
  LocalDriveState,
  MeetingPorts,
  VoiceCallPorts,
  Pull,
  ResetPorts,
  StreamResponse,
  ImageBytes,
  NamedImageBytes,
  ProviderRequest,
  StationMeshPorts,
} from "../host.ts";

/** A port as the utility process has it (Electron's MessagePortMain). */
export interface UtilityPort {
  on(event: "message", listener: (event: { data: unknown }) => void): unknown;
  on(event: "close", listener: () => void): unknown;
  postMessage(message: unknown): void;
  start(): void;
  close(): void;
}

export interface ParentPort {
  on(
    event: "message",
    listener: (event: { data: unknown; ports: UtilityPort[] }) => void
  ): unknown;
  postMessage(message: unknown): void;
}

/** A body arriving in pieces: what came, and who waits for the next. */
class Pieces implements Pull<Uint8Array> {
  readonly #queue: (Uint8Array | null | HostError)[] = [];
  #waiting: ((piece: Uint8Array | null | HostError) => void) | null = null;

  push(piece: Uint8Array | null | HostError): void {
    const waiting = this.#waiting;
    if (waiting) {
      this.#waiting = null;
      waiting(piece);
    } else this.#queue.push(piece);
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

type Pending = {
  head: (response: { status: number; headers: [string, string][] } | HostError) => void;
  body: Pieces;
};

/** Main's Tasks cache from before the core (`comma.sqlite`, schema 10): an account's workspaces and rows, newest first. */
function readLegacyTasks(
  path: string,
  audience: string,
  userId: string
): LegacyWorkspaceTasks[] {
  if (!existsSync(path)) return [];
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    if (
      Number(
        (db.prepare("PRAGMA user_version").get() as { user_version: number })
          .user_version
      ) !== 10
    )
      return [];
    const workspaces = db
      .prepare(
        "SELECT id, group_id, name FROM product_workspaces WHERE principal_id = ? AND audience = ?"
      )
      .all(userId, audience) as { id: string; group_id: string; name: string }[];
    return workspaces.map((workspace) => ({
      workspace,
      conversations: (
        db
          .prepare(
            "SELECT raw_json FROM product_conversations WHERE principal_id = ? AND audience = ? AND workspace_id = ? ORDER BY updated_at DESC LIMIT 50"
          )
          .all(userId, audience, workspace.id) as { raw_json: string }[]
      ).flatMap((row) => {
        try {
          return [JSON.parse(row.raw_json) as unknown];
        } catch {
          return [];
        }
      }),
    }));
  } finally {
    db.close();
  }
}

/** Main's meeting journal from before the core (`meeting-tasks.json`): its text, or null when there is none. */
function readLegacyMeetingTasks(path: string | undefined): string | null {
  if (!path || !existsSync(path)) return null;
  return readFileSync(path, "utf8");
}

class UtilityHost implements Host {
  readonly sessionSource = "core" as const;
  readonly uploadsLocalFiles = true;
  readonly stationMesh: StationMeshPorts;
  /**
   * The core's data is this process's directory: every value of the device database and every account database. Main
   * resets the rest and starts a new core process; this one's ends with it, so `restart` does not return.
   */
  readonly reset: ResetPorts = {
    clear: Effect.try({
      try: () => {
        this.#device.run("DELETE FROM kv");
        for (const file of readdirSync(this.#dataDir))
          if (/\.sqlite(-wal|-shm)?$/.test(file) && !file.startsWith("device.sqlite"))
            rmSync(joinPath(this.#dataDir, file), { force: true });
      },
      catch: (e) => new HostError(e instanceof Error ? e.message : String(e)),
    }),
    restart: Effect.callback<void, HostError>(() => {
      this.#send({ type: "reset" });
    }),
  };
  readonly bearerSession: BearerSessionPorts;
  readonly client: ClientIdentity;
  readonly desktop?: DesktopPorts;
  readonly deviceSetup?: import("../host.ts").DeviceSetupPort;
  readonly #deviceSetupCalls = new Map<
    number,
    (value: unknown, error?: string) => void
  >();
  readonly meeting: MeetingPorts;
  /** Meeting commands waiting for Main's answer, by id. */
  readonly #meetingCalls = new Map<
    number,
    (answer: MeetingAnswer | HostError) => void
  >();
  #meetingListener: ((event: MeetingEvent) => void) | null = null;
  readonly #meetingEarly: MeetingEvent[] = [];
  readonly voiceCall: VoiceCallPorts;
  #voiceCallListener: ((event: VoiceCallSocketEvent) => void) | null = null;
  /** Session ports waiting for Main's answer, by id. */
  readonly #calls = new Map<number, (value: unknown, error?: string) => void>();
  readonly #parent: ParentPort;
  readonly #dataDir: string;
  readonly #legacyTasksPath: string | undefined;
  readonly #device: NodeSql;
  readonly #pending = new Map<number, Pending>();
  readonly #clients = new Map<ClientId, UtilityPort>();
  #nextRequest = 0;
  /** What the core asked Main that Main has not answered yet, by id (a stream until it opened). */
  readonly #unanswered = new Set<number>();
  /** Told each time Main answers one. */
  readonly #answers = new Set<() => void>();
  /** The last id asked before the test clock's current move (`advance`). */
  #movedAfter = 0;

  #asked(): number {
    const id = ++this.#nextRequest;
    this.#unanswered.add(id);
    return id;
  }

  #answered(id: number): void {
    if (!this.#unanswered.delete(id)) return;
    for (const answered of this.#answers) answered();
    this.#answers.clear();
  }

  /**
   * Lets `ms` of a test clock's time pass (an Electron e2e's, `testClock`): the clock stops at each timer due on the
   * way, and moves on once what woke has run and Main has answered all it asked since the move began. Main's answers
   * are what the next timer waits on, so a move ends the same however fast Main answers. A stream counts as answered
   * once it opened.
   */
  advance(time: TestTime, ms: number): Promise<void> {
    this.#movedAfter = this.#nextRequest;
    return time.pass(ms);
  }

  /** Runs what is ready, until nothing asked of Main since the move began waits for its answer (`advance`). */
  async settled(): Promise<void> {
    for (;;) {
      await settle();
      if (![...this.#unanswered].some((id) => id > this.#movedAfter)) return;
      await new Promise<void>((answered) => this.#answers.add(answered));
    }
  }

  constructor(
    parent: ParentPort,
    dataDir: string,
    legacyTasksPath: string | undefined,
    session: UtilitySessionStart,
    desktop: UtilityDesktopStart | undefined,
    localDrive = false,
    legacyMeetingTasksPath?: string,
    stationPeers: Record<string, string[]> = {},
    meshAddon?: string
  ) {
    this.#parent = parent;
    this.stationMesh = nativeStations(meshAddon, stationPeers);
    if (localDrive)
      this.localDrive = {
        state: this.#drive<LocalDriveState>({ op: "state" }),
        list: (input) => this.#drive<LocalDriveListResult>({ op: "list", input }),
        run: (name, input) => this.#drive({ op: "run", name, input }),
        onChange: (listener) => {
          this.#driveListeners.add(listener);
          return () => void this.#driveListeners.delete(listener);
        },
      };
    if (session.clientPlatform === "macos")
      this.deviceSetup = {
        call: (op, input) =>
          Effect.callback<unknown, HostError>((resume) => {
            const id = this.#asked();
            this.#deviceSetupCalls.set(id, (value, error) =>
              resume(error ? Effect.fail(new HostError(error)) : Effect.succeed(value))
            );
            this.#send({ type: "device-setup", id, op, input });
            return Effect.sync(() => {
              this.#deviceSetupCalls.delete(id);
              this.#answered(id);
            });
          }),
      };
    this.meeting = {
      command: (op, input) => {
        // Main's journal from before the core is read here, where its file is.
        if (op === "legacy")
          return Effect.try({
            try: () => ({ ok: readLegacyMeetingTasks(legacyMeetingTasksPath) }),
            catch: (e) => new HostError(String(e)),
          }) as never;
        return Effect.callback<MeetingAnswer, HostError>((resume) => {
          const id = this.#asked();
          this.#meetingCalls.set(id, (answer) =>
            resume(
              answer instanceof HostError ? Effect.fail(answer) : Effect.succeed(answer)
            )
          );
          this.#send({ type: "meeting", id, op, input } as CoreToMain);
          return Effect.sync(() => {
            this.#meetingCalls.delete(id);
            this.#answered(id);
          });
        }) as never;
      },
      listen: (listener) => {
        this.#meetingListener = listener;
        for (const event of this.#meetingEarly.splice(0)) listener(event);
      },
    };
    this.voiceCall = {
      command: (op) => this.#send({ type: "voice-call", ...op } as CoreToMain),
      listen: (listener) => {
        this.#voiceCallListener = listener;
      },
    };
    this.#dataDir = dataDir;
    this.#legacyTasksPath = legacyTasksPath;
    this.client = {
      kind: "electron",
      platform: session.clientPlatform,
      version: session.appVersion,
    };
    this.bearerSession = {
      apiOrigin: session.apiOrigin,
      clientPlatform: session.clientPlatform,
      resumed: session.resumed,
      vault: this.#call({ op: "vault", input: null }),
      change: (change) => this.#call({ op: "change", input: change }),
      gate: (snapshot, lease) => this.#send({ type: "gate", snapshot, lease }),
      google: (input) => this.#call({ op: "google", input }),
      googleDone: (grant, ok) =>
        Effect.ignore(this.#call({ op: "googleDone", input: { grant, ok } })),
    };
    if (desktop)
      this.desktop = {
        app: desktop.app,
        presence: this.#call({ op: "presence", input: null }),
        openExternal: (url) =>
          Effect.asVoid(this.#call({ op: "openExternal", input: { url } })),
        returnToApp: Effect.ignore(this.#call({ op: "returnToApp", input: null })),
        pickAttachments: (request) => this.#call({ op: "chatPick", input: request }),
        saveDownload: (fileName, content) =>
          this.#call({ op: "saveDownload", input: { fileName, content } }),
        saveOpen: (fileName) => this.#call({ op: "saveOpen", input: { fileName } }),
        saveWrite: (id, bytes) =>
          Effect.asVoid(this.#call({ op: "saveWrite", input: { id, bytes } })),
        saveClose: (id, keep) => this.#call({ op: "saveClose", input: { id, keep } }),
        openStream: (input) => this.#call({ op: "openStream", input }),
        closeStream: (url) =>
          Effect.asVoid(this.#call({ op: "closeStream", input: { url } })),
        saveStream: (input) => this.#call({ op: "saveStream", input }),
        listen: (input) =>
          listenLoopback({
            port: input.port,
            path: input.path,
            pages: desktop.pages[input.source],
            csp: desktop.csp,
          }),
        providerFetch: (request) => providerFetch(request),
        sha256: (input) =>
          Effect.sync(
            () => new Uint8Array(createHash("sha256").update(input, "utf8").digest())
          ),
        ...(desktop.updates
          ? {
              updates: {
                status: this.#call({ op: "updateStatus", input: null }),
                check: this.#call({ op: "updateCheck", input: null }),
                download: (release) =>
                  this.#call({ op: "updateDownload", input: release }),
                apply: (release) => this.#call({ op: "updateApply", input: release }),
              },
            }
          : {}),
      };
    const transcoder = this.#transcoder;
    if (transcoder)
      this.transcodeImage = (input) =>
        Effect.tryPromise({
          try: async (signal) => {
            const out = await transcoder(
              {
                data: new Blob([input.bytes as Uint8Array<ArrayBuffer>], {
                  type: input.mediaType,
                }),
                name: input.name,
                size: input.bytes.length,
              },
              signal
            );
            return {
              bytes: new Uint8Array(await out.data.arrayBuffer()),
              name: out.name,
              mediaType: out.data.type,
            };
          },
          catch: (e) => new HostError(e instanceof Error ? e.message : String(e)),
        });
    mkdirSync(dataDir, { recursive: true });
    this.#device = NodeSql.file(joinPath(dataDir, "device.sqlite"));
    this.#device.exec(
      "CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL)"
    );
  }

  readonly #previews = new Map<number, (out: Uint8Array | HostError) => void>();
  readonly #transcoder = createDarwinImageTranscoder();
  readonly #localReads = new Map<number, (out: Uint8Array | HostError) => void>();

  /** A part of a local file a pick left with Main, read there: what goes up to a station a part at a time. */
  readLocalFile(
    ref: string,
    offset: number,
    length: number
  ): Effect.Effect<Uint8Array, HostError> {
    return Effect.callback<Uint8Array, HostError>((resume) => {
      const id = this.#asked();
      this.#localReads.set(id, (out) =>
        resume(out instanceof HostError ? Effect.fail(out) : Effect.succeed(out))
      );
      this.#send({ type: "local-read", id, localFileRef: ref, offset, length });
      return Effect.sync(() => {
        this.#localReads.delete(id);
        this.#answered(id);
      });
    });
  }

  /** A workspace image drawn again by Main (Electron's nativeImage): the preview a window may show. */
  renderImagePreview(input: ImageBytes): Effect.Effect<Uint8Array, HostError> {
    return Effect.callback<Uint8Array, HostError>((resume) => {
      const id = this.#asked();
      this.#previews.set(id, (out) =>
        resume(out instanceof HostError ? Effect.fail(out) : Effect.succeed(out))
      );
      this.#send({
        type: "preview",
        id,
        bytes: input.bytes,
        mediaType: input.mediaType,
      });
      return Effect.sync(() => {
        this.#previews.delete(id);
        this.#answered(id);
      });
    });
  }

  /** HEIC/HEIF as JPEG, by macOS's `sips` (this process can run it); none elsewhere. */
  readonly transcodeImage?: (
    input: NamedImageBytes
  ) => Effect.Effect<NamedImageBytes, HostError>;

  /** An auth request through Main: the credential it names attached there, a bearer in the answer kept there. */
  authFetch(request: AuthRequest): Effect.Effect<ApiResponse, HostError> {
    return this.#call({
      op: "auth",
      input: {
        method: request.method,
        path: request.path,
        headers: request.headers,
        body: request.body,
        ...(request.credential ? { credential: request.credential } : {}),
      },
    });
  }

  /** A session port Main answers; interrupted, Main gives it up (and keeps what a late answer carried). */
  #call<C extends UtilitySessionCall>(
    call: C
  ): Effect.Effect<UtilitySessionAnswer[C["op"]], HostError> {
    return Effect.callback<UtilitySessionAnswer[C["op"]], HostError>((resume) => {
      const id = this.#asked();
      this.#calls.set(id, (value, error) =>
        resume(
          error !== undefined
            ? Effect.fail(new HostError(error))
            : Effect.succeed(value as UtilitySessionAnswer[C["op"]])
        )
      );
      this.#send({ type: "session", id, ...call } as CoreToMain);
      return Effect.sync(() => {
        this.#answered(id);
        if (this.#calls.delete(id)) this.#send({ type: "abort", id });
      });
    });
  }

  /** This installation's Drive node, read through Main (`drive`). */
  readonly localDrive?: LocalDrivePorts;
  readonly #driveCalls = new Map<
    number,
    (value: unknown, error: string | undefined) => void
  >();
  readonly #driveListeners = new Set<() => void>();

  #drive<A>(
    call:
      | { op: "state" }
      | { op: "list"; input: LocalDriveListInput }
      | { op: "run"; name: LocalDriveOp; input: unknown }
  ): Effect.Effect<A, HostError> {
    return Effect.callback<A, HostError>((resume) => {
      const id = this.#asked();
      this.#driveCalls.set(id, (value, error) =>
        resume(
          error !== undefined
            ? Effect.fail(new HostError(error))
            : Effect.succeed(value as A)
        )
      );
      this.#send({ type: "drive", id, ...call } as CoreToMain);
      return Effect.sync(() => {
        this.#driveCalls.delete(id);
        this.#answered(id);
      });
    });
  }

  /** The Drive node's files changed. */
  driveChanged(): void {
    for (const listener of this.#driveListeners) listener();
  }

  /** What the voice call socket did (none before the core listens: there is no call then). */
  voiceCallEvent(event: VoiceCallSocketEvent): void {
    this.#voiceCallListener?.(event);
  }

  /** What Main's meeting parts saw. */
  meetingEvent(event: MeetingEvent): void {
    if (this.#meetingListener) this.#meetingListener(event);
    else this.#meetingEarly.push(event);
  }

  /** Main's answer to a request. */
  answer(message: Extract<MainToCore, { id: number }>): void {
    if (message.type !== "head" && message.type !== "chunk") this.#answered(message.id);
    if (message.type === "drive-done") {
      const done = this.#driveCalls.get(message.id);
      this.#driveCalls.delete(message.id);
      done?.(message.value ?? null, message.error);
      return;
    }
    if (message.type === "device-setup-done") {
      const done = this.#deviceSetupCalls.get(message.id);
      this.#deviceSetupCalls.delete(message.id);
      done?.(message.value ?? null, message.error);
      return;
    }
    if (message.type === "meeting-done") {
      const done = this.#meetingCalls.get(message.id);
      this.#meetingCalls.delete(message.id);
      done?.(message.answer ?? new HostError(message.error ?? "no answer"));
      return;
    }
    if (message.type === "session-done") {
      const done = this.#calls.get(message.id);
      if (!done) {
        // The core gave the request up before its answer came: Main settles what it carried.
        this.#send({ type: "session-dropped", id: message.id });
        return;
      }
      this.#calls.delete(message.id);
      done(message.value ?? null, message.error);
      return;
    }
    if (message.type === "preview-done") {
      const done = this.#previews.get(message.id);
      this.#previews.delete(message.id);
      done?.(message.bytes ?? new HostError(message.error ?? "no preview"));
      return;
    }
    if (message.type === "local-read-done") {
      const done = this.#localReads.get(message.id);
      this.#localReads.delete(message.id);
      done?.(message.bytes ?? new HostError(message.error ?? "no part of the file"));
      return;
    }
    const pending = this.#pending.get(message.id);
    if (!pending) return;
    switch (message.type) {
      case "head":
        pending.head({ status: message.status, headers: message.headers });
        return;
      case "chunk":
        pending.body.push(message.bytes);
        return;
      case "end":
        this.#pending.delete(message.id);
        pending.body.push(null);
        return;
      case "fail": {
        this.#pending.delete(message.id);
        const error = new HostError(message.message);
        pending.head(error);
        pending.body.push(error);
      }
    }
  }

  #send(message: CoreToMain): void {
    // oxlint-disable-next-line unicorn/require-post-message-target-origin -- a port has no target origin
    this.#parent.postMessage(message);
  }

  /** A request through Main: its head once Main has it, its body as it comes; interrupted, Main lets it go. */
  #request(
    request: ApiRequest,
    stream: boolean
  ): Effect.Effect<
    { status: number; headers: [string, string][]; body: Pieces; id: number },
    HostError
  > {
    return Effect.callback((resume) => {
      const id = this.#asked();
      const body = new Pieces();
      this.#pending.set(id, {
        head: (head) => {
          // A stream is answered once it opened: what it carries comes when the server says.
          if (stream) this.#answered(id);
          resume(
            head instanceof HostError
              ? Effect.fail(head)
              : Effect.succeed({ ...head, body, id })
          );
        },
        body,
      });
      this.#send({
        type: "fetch",
        id,
        method: request.method,
        path: request.path,
        headers: request.headers,
        body: request.body,
        ...(request.localFileRef !== undefined
          ? { localFileRef: request.localFileRef }
          : {}),
        lease: request.lease,
      });
      return Effect.sync(() => this.#abort(id));
    });
  }

  #abort(id: number): void {
    this.#answered(id);
    if (!this.#pending.delete(id)) return;
    this.#send({ type: "abort", id });
  }

  fetch(request: ApiRequest): Effect.Effect<ApiResponse, HostError> {
    return Effect.gen({ self: this }, function* () {
      const head = yield* this.#request(request, false);
      const parts: Uint8Array[] = [];
      for (;;) {
        const piece = yield* head.body.take.pipe(
          Effect.onInterrupt(() => Effect.sync(() => this.#abort(head.id)))
        );
        if (piece === null) break;
        parts.push(piece);
      }
      return { status: head.status, headers: head.headers, body: concat(parts) };
    });
  }

  fetchStream(
    request: ApiRequest
  ): Effect.Effect<StreamResponse, HostError, Scope.Scope> {
    return Effect.acquireRelease(
      this.#request(request, true),
      (head) => Effect.sync(() => this.#abort(head.id)),
      // Waiting for response headers is part of the caller's deadline, and a closed lease cancels it too.
      { interruptible: true }
    ).pipe(
      Effect.map((head) => ({
        status: head.status,
        headers: head.headers,
        body: head.body as Pull<Uint8Array>,
      }))
    );
  }

  storageGet(key: string) {
    return Effect.try({
      try: () =>
        (this.#device.all("SELECT value FROM kv WHERE key = ?", [key])[0]?.[0] as
          | Uint8Array
          | undefined) ?? null,
      catch: (e) => new HostError(String(e)),
    });
  }

  storageSet(key: string, value: Uint8Array) {
    return Effect.try({
      try: () =>
        void this.#device.run(
          "INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
          [key, value]
        ),
      catch: (e) => new HostError(String(e)),
    });
  }

  storageDelete(key: string) {
    return Effect.try({
      try: () => void this.#device.run("DELETE FROM kv WHERE key = ?", [key]),
      catch: (e) => new HostError(String(e)),
    });
  }

  openDb(name: string): Effect.Effect<Sql, HostError> {
    return Effect.try({
      try: () => NodeSql.file(joinPath(this.#dataDir, `${name}.sqlite`)),
      catch: (e) => new HostError(e instanceof Error ? e.message : String(e)),
    });
  }

  get memoryDb(): Effect.Effect<Sql, HostError> {
    return Effect.sync(() => NodeSql.memory());
  }

  deleteDb(name: string): Effect.Effect<void, HostError> {
    return Effect.try({
      try: () => {
        for (const suffix of ["", "-wal", "-shm"])
          rmSync(joinPath(this.#dataDir, `${name}.sqlite${suffix}`), { force: true });
      },
      catch: (e) => new HostError(String(e)),
    });
  }

  legacyTasks(
    audience: string,
    userId: string
  ): Effect.Effect<LegacyWorkspaceTasks[], HostError> {
    const path = this.#legacyTasksPath;
    return path
      ? Effect.try({
          try: () => readLegacyTasks(path, audience, userId),
          catch: (e) => new HostError(String(e)),
        })
      : Effect.succeed([]);
  }

  randomBytes(buf: Uint8Array): void {
    randomFillSync(buf);
  }

  get yieldTurn(): Effect.Effect<void> {
    return Effect.callback<void>((resume) => {
      const handle = setImmediate(() => resume(Effect.void));
      return Effect.sync(() => clearImmediate(handle));
    });
  }

  emit(client: ClientId, message: CoreMessage): void {
    // oxlint-disable-next-line unicorn/require-post-message-target-origin -- a port has no target origin
    this.#clients.get(client)?.postMessage(message);
  }

  /** A window's port: its messages go to the core as that client's, until it closes. */
  attach(
    core: Core,
    port: UtilityPort,
    surface?: string,
    options: { session?: boolean; host?: boolean } = {}
  ): void {
    const client = core.connect(surface, options);
    this.#clients.set(client, port);
    port.on("message", (event) => {
      const data = event.data;
      if (typeof data === "object" && data !== null && "bye" in data)
        core.disconnect(client);
      else core.receive(client, data);
    });
    port.on("close", () => {
      this.#clients.delete(client);
      core.disconnect(client);
    });
    port.start();
  }
}

/**
 * This device's endpoint on the station's native addon (`@comma/mesh/station-native`), loaded from `meshAddon` (the
 * station the app carries, as Main says) when Stations first needs it, with the relays the control plane named (none:
 * direct addresses only), and Salix as the relay of last resort when the addon has it. `peers`: where stations are, when Main knows (an Electron e2e's loopback station).
 */
function nativeStations(
  meshAddon: string | undefined,
  peers: Record<string, string[]>
): StationMeshPorts {
  return {
    // The desktop app keeps its stations linked while it carries a station to reach them with.
    alwaysLinked: meshAddon !== undefined,
    open: ({ secretKey, relays }) =>
      Effect.acquireRelease(
        Effect.tryPromise({
          try: async () => {
            if (!meshAddon || !existsSync(meshAddon))
              throw new Error(
                `the station's mesh addon is not there (${meshAddon ?? "no station"})`
              );
            const { bindNativeEndpoint, loadNativeMesh } =
              await import("@comma/mesh/station-native");
            return bindNativeEndpoint(loadNativeMesh(meshAddon), {
              secretKey,
              relays,
              salixRelay: true,
            });
          },
          catch: (e) => new HostError(e instanceof Error ? e.message : String(e)),
        }),
        (endpoint) => Effect.promise(() => endpoint.close().catch(() => undefined))
      ).pipe(
        Effect.flatMap((endpoint) =>
          Effect.acquireRelease(
            Effect.sync(() => meshStationLinks(endpoint, peers, endpoint.relay)),
            (links) => Effect.sync(() => links.close())
          )
        )
      ),
  };
}

/** A provider's request from this process (no cookie, no redirect), its answer read up to `maxBytes`. */
function providerFetch(
  request: ProviderRequest
): Effect.Effect<ApiResponse, HostError> {
  return Effect.tryPromise({
    try: async (signal) => {
      const response = await fetch(request.url, {
        method: request.method,
        headers: request.headers,
        body: request.body as Uint8Array<ArrayBuffer>,
        credentials: "omit",
        redirect: "error",
        signal,
      });
      const reader = response.body?.getReader();
      const parts: Uint8Array[] = [];
      let size = 0;
      try {
        for (;;) {
          if (!reader) break;
          const next = await reader.read();
          if (next.done) break;
          size += next.value.byteLength;
          if (size > request.maxBytes) throw new Error("the answer is too large");
          parts.push(next.value);
        }
      } finally {
        await reader?.cancel().catch(() => undefined);
      }
      return {
        status: response.status,
        headers: [...response.headers],
        body: concat(parts),
      };
    },
    catch: (e) => new HostError(e instanceof Error ? e.message : String(e)),
  });
}

function concat(parts: Uint8Array[]): Uint8Array {
  if (parts.length === 1) return parts[0]!;
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

/** Runs the core in this utility process once Main says where its data goes. */
export function startCoreUtility(parent: ParentPort): void {
  let host: UtilityHost | null = null;
  let core: Core | null = null;
  /** The clock an Electron e2e moves (`testClock`); none otherwise. */
  let time: TestTime | null = null;
  /** One move of the test clock at a time, in the order Main asked. */
  let moving = Promise.resolve();
  const early: { data: unknown; ports: UtilityPort[] }[] = [];
  const handle = (event: { data: unknown; ports: UtilityPort[] }) => {
    const message = event.data as MainToCore;
    if (message.type === CORE_START) {
      if (host) return;
      host = new UtilityHost(
        parent,
        message.dataDir,
        message.legacyTasksPath,
        message.session,
        message.desktop,
        message.localDrive === true,
        message.legacyMeetingTasksPath,
        message.stationPeers,
        message.meshAddon
      );
      if (message.testClock) {
        const settling = host;
        // Starts where Main's test clock is (TestTime's zero when Main gives none), so the two read one time and
        // what the e2e sees never depends on when it ran.
        time = new TestTime(message.testClockStart, () => settling.settled());
      }
      // A test clock's core sends each change at once: gathering them would wait on the clock too.
      core = new Core(host, time ? { clock: time.clock, coalesceMs: 0 } : {});
      core.runner.onDefect = (error) =>
        console.error("comma core: a fiber failed", error);
      for (const queued of early.splice(0)) handle(queued);
      return;
    }
    if (!host || !core) {
      early.push(event);
      return;
    }
    switch (message.type) {
      case "rejected":
        core.hostRejected(message.lease, message.status);
        return;
      case "drive-changed":
        host.driveChanged();
        return;
      case "meeting-event":
        host.meetingEvent(message.event);
        return;
      case "voice-call-event":
        host.voiceCallEvent(message.event);
        return;
      case "clock": {
        const { id, ms } = message;
        const moved = host;
        const clock = time;
        const done = (error?: string) => {
          const out: CoreToMain = { type: "clock-done", id };
          if (error !== undefined) out.error = error;
          if (clock) {
            out.now = clock.now();
            const next = clock.nextDue();
            if (next !== undefined) out.nextDue = next;
          }
          // oxlint-disable-next-line unicorn/require-post-message-target-origin -- a port has no target origin
          parent.postMessage(out);
        };
        moving = moving.then(() =>
          (clock
            ? moved.advance(clock, ms)
            : Promise.reject(new Error("no test clock"))
          ).then(
            () => done(),
            (error: unknown) =>
              done(error instanceof Error ? error.message : String(error))
          )
        );
        return;
      }
      case "client":
        if (event.ports[0])
          host.attach(core, event.ports[0], message.surface, {
            ...(message.session === false ? { session: false } : {}),
            ...(message.host ? { host: true } : {}),
          });
        return;
      default:
        host.answer(message);
    }
  };
  parent.on("message", handle);
}
