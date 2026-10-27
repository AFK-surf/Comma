// What a core was told, in order, so a run can be read back and played again. A core's only inputs are its UIs'
// messages, the session, the server's answers (auth requests' too) and stream pieces, the host's random bytes and its
// legacy lists, the session hints of other contexts, Main's answers about its credential store and Google window
// (by reference: no bearer is ever among them) and the refusals it saw, the web's Web Lock grants and digests, the desktop
// ports' answers (`HOST` requests: a chat pick's too, its uploads' bytes as base64), the
// operations its embedder ran on its session lifecycle, and the Clock's timers firing; each is noted here with a
// sequence number and the Clock's time. What the core sent its UIs, the requests it made, the locks it let go, and what
// it told Main's gate are noted beside them as outputs. What the core gave up itself (a request or a lock it stopped
// waiting for) is no input: the replayed core gives it up again. `testing/replay.ts` feeds a log to a new core on a
// TestClock: the same inputs at the same times give the same outputs.
import type {
  ClientId,
  CoreMessage,
  HostError,
  Sql,
  SqlValue,
} from "@comma/core-kernel";
import { Cause, Duration, Effect, Exit, type Clock, type Scope } from "effect";
import { utf8 } from "@comma/core-kernel";
import {
  HostUnsupported,
  type ApiResponse,
  type BearerSessionPorts,
  type ChatPickAnswer,
  type ClientIdentity,
  type DesktopPorts,
  type Host,
  type LegacyWorkspaceTasks,
  type DownloadPorts,
  type LocalDrivePorts,
  type Loopback,
  type LoopbackVisit,
  type MeetingEvent,
  type MeetingPorts,
  type VoiceCallPorts,
  type VoiceCallSocketEvent,
  type VoiceCallSocketOp,
  type Pull,
  type ResetPorts,
  type SessionAuthorityResume,
  type SessionLease,
  type StationLinks,
  type StationMeshPorts,
  type StationRelayTicket,
  type StreamResponse,
  type WebSessionPorts,
} from "./host.ts";

/** A request as the log names it: method, path, and which of that method and path's requests it was (from 0). */
export interface RequestRef {
  method: string;
  path: string;
  n: number;
}

export type Input =
  | {
      kind: "connect";
      client: ClientId;
      surface?: string;
      session?: false;
      host?: true;
    }
  | { kind: "ui"; client: ClientId; message: unknown }
  | { kind: "disconnect"; client: ClientId }
  | { kind: "session"; snapshot: unknown }
  | {
      kind: "response";
      request: RequestRef;
      status: number;
      headers: [string, string][];
      body: string;
      /** It came at once, in the turn the core asked (a free Web Lock, a digest): a replay answers it so too. */
      sync?: true;
    }
  /** No answer: the host failed (`defect`: its port threw instead, a bug of the host's). */
  | {
      kind: "failure";
      request: RequestRef;
      message: string;
      sync?: true;
      defect?: true;
    }
  | {
      kind: "stream";
      request: RequestRef;
      stream: number;
      status: number;
      headers: [string, string][];
    }
  | { kind: "piece"; stream: number; body: string }
  | { kind: "end"; stream: number }
  | { kind: "broken"; stream: number; message: string }
  | { kind: "random"; bytes: string }
  | { kind: "legacy"; tasks: LegacyWorkspaceTasks[] }
  | { kind: "legacyFailure"; message: string }
  /**
   * What the host can do besides requests (its image capabilities, Main's meeting parts, sending a file it holds as a
   * request's body), as the core was made.
   */
  | {
      kind: "capabilities";
      preview: boolean;
      transcode: boolean;
      meeting?: boolean;
      /** Main's voice call socket (`VoiceCallPorts`). */
      voiceCall?: boolean;
      localFiles?: boolean;
      /** The app reads parts of its picks (`Host.readLocalFile`): each part read is an answer (`HOST localFile:…`). */
      readsLocalFiles?: boolean;
      /** The app the core's requests report (`Host.client`). */
      client?: ClientIdentity;
    }
  /** What Main's meeting recorder parts saw (`MeetingPorts.listen`). */
  | { kind: "meeting"; event: MeetingEvent }
  /** What Main's voice call socket did (`VoiceCallPorts.listen`). */
  | { kind: "voiceCall"; event: VoiceCallSocketEvent }
  /** An image capability's answer: its bytes (and name and media type for a transcode), or why it failed. */
  | {
      kind: "image";
      op: "preview" | "transcode";
      bytes?: string;
      name?: string;
      mediaType?: string;
      failure?: string;
    }
  /** Another context's session hint (the web session lifecycle's channel). */
  | { kind: "hint"; message: unknown }
  /** The Electron session ports' fixed values, as the core was made (Main's origin, platform and gate). */
  | {
      kind: "bearer";
      apiOrigin: string;
      clientPlatform: BearerSessionPorts["clientPlatform"];
      clientKind?: BearerSessionPorts["clientKind"];
      showsKeptAccount?: true;
      resumed?: SessionAuthorityResume;
    }
  /** The web session ports' fixed values, as the core was made (the API's origin and the browser's user agent). */
  | { kind: "web"; apiOrigin: string; userAgent: string }
  /**
   * An operation the core's embedder ran on its session lifecycle (`Core.webSession` / `Core.electronSession`), as it
   * began: its name and arguments.
   */
  | { kind: "operation"; name: string; args: unknown[] }
  /** The core's embedder closed it (`Core.close`: its tab went, another core took over). */
  | { kind: "close" }
  /** The desktop ports' fixed values, as the core was made (their answers are noted as `HOST` requests'). */
  | {
      kind: "desktop";
      app: { urlScheme: string; productName: string };
      /** It had the app's update ports (`update.*`). */
      updates?: true;
    }
  /** Main refused a UI's own request for `lease` (`Core.hostRejected`). */
  | { kind: "rejected"; lease: SessionLease; status: 401 | 409 }
  /** The host has a local Drive node (its answers are noted as requests' answers, `HOST localDrive.*`). */
  | { kind: "localDrive" }
  /** The host downloads files to its storage (their answers are noted as requests' answers, `HOST downloads.*`). */
  | { kind: "downloads" }
  /** The host reaches stations (its answers are noted as requests' answers, `MESH` requests). */
  | { kind: "stationMesh"; alwaysLinked?: true }
  /** The host can reset the app (its answers are noted as requests' answers, `HOST reset.*`). */
  | { kind: "reset" }
  /** The local Drive node said its files changed. */
  | { kind: "localDriveChanged" }
  /** Device storage answered: a read's value (base64; null: none), or a write's or read's failure. */
  | {
      kind: "storage";
      op: "get" | "set" | "delete";
      key: string;
      value?: string | null;
      failure?: string;
    }
  /** A database as it opened: its schema and every table's rows (blobs as `{"$b": base64}`). */
  | { kind: "db"; name: string; tables: DbDump }
  | { kind: "dbFailure"; name: string; message: string }
  /** A timer of the core's fired (it slept `ms`). */
  | { kind: "tick"; ms: number };

export type Output =
  | { kind: "emit"; client: ClientId; message: CoreMessage }
  | { kind: "request"; request: RequestRef; stream: boolean }
  | { kind: "hint"; message: unknown }
  /** What the core told Main's gate (`BearerSessionPorts.gate`). */
  | { kind: "gate"; snapshot: unknown; lease: SessionLease | null }
  /** The core let go of the Web Lock it was granted (its request `LOCK <name>`). */
  | { kind: "unlock"; request: RequestRef }
  /** What the core asked of Main's voice call socket (`VoiceCallPorts.command`). */
  | { kind: "voiceCall"; op: VoiceCallSocketOp };

export type Entry<T> = T & { seq: number; at: number };

/**
 * The core gave the call up (its fiber was interrupted: a timeout, a cancel, a scope that closed): no answer came, so
 * nothing is noted. Played again, the core gives it up the same way.
 */
const interrupted = (exit: Exit.Exit<unknown, unknown>) =>
  Exit.isFailure(exit) && Cause.hasInterruptsOnly(exit.cause);

/** Bytes as the log keeps them. */
export function base64(bytes: Uint8Array): string {
  let text = "";
  for (const b of bytes) text += String.fromCharCode(b);
  return btoa(text);
}

export function fromBase64(text: string): Uint8Array {
  const raw = atob(text);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

/** A pick's answer as the log keeps it: each upload's bytes as base64. */
export type RecordedChatPick = Omit<ChatPickAnswer, "items"> & {
  items: (
    | Exclude<ChatPickAnswer["items"][number], { kind: "upload" }>
    | { kind: "upload"; name: string; size: number; bytes: string }
  )[];
};

export function recordChatPick(answer: ChatPickAnswer): RecordedChatPick {
  return {
    ...answer,
    items: answer.items.map((item) =>
      item.kind === "upload" ? { ...item, bytes: base64(item.bytes) } : item
    ),
  };
}

export function chatPickOf(recorded: RecordedChatPick): ChatPickAnswer {
  return {
    ...recorded,
    items: recorded.items.map((item) =>
      item.kind === "upload" ? { ...item, bytes: fromBase64(item.bytes) } : item
    ),
  };
}

/** The log of one core's run, in memory. */
export class Recorder {
  readonly inputs: Entry<Input>[] = [];
  readonly outputs: Entry<Output>[] = [];
  #seq = 0;
  #now: () => number = () => 0;
  readonly #requests = new Map<string, number>();
  #streams = 0;

  /** The core's time: set by the core it records, from its Clock. */
  useClock(now: () => number): void {
    this.#now = now;
  }

  input(entry: Input): void {
    this.inputs.push({ ...entry, seq: this.#seq++, at: this.#now() });
  }

  output(entry: Output): void {
    this.outputs.push({ ...entry, seq: this.#seq++, at: this.#now() });
  }

  /** The log as text, for a failed test to show. */
  dump(): string {
    return JSON.stringify({ inputs: this.inputs, outputs: this.outputs }, null, 1);
  }

  #ref(request: { method: string; path: string }): RequestRef {
    const key = `${request.method} ${request.path}`;
    const n = this.#requests.get(key) ?? 0;
    this.#requests.set(key, n + 1);
    return { method: request.method, path: request.path, n };
  }

  /** `clock`, its timers noted as they fire. */
  clock(clock: Clock.Clock): Clock.Clock {
    return {
      ...clock,
      currentTimeMillisUnsafe: () => clock.currentTimeMillisUnsafe(),
      sleep: (duration: Duration.Duration) => {
        const ms = Duration.toMillis(duration);
        return clock
          .sleep(duration)
          .pipe(Effect.tap(() => Effect.sync(() => this.input({ kind: "tick", ms }))));
      },
    } as Clock.Clock;
  }

  /** `host`, what it answers noted as inputs and what the core sends through it as outputs. */
  host(host: Host): Host {
    const answered = <R = never>(
      request: { method: string; path: string },
      send: Effect.Effect<ApiResponse, HostError, R>,
      ref: RequestRef = this.#ref(request)
    ) => {
      this.output({ kind: "request", request: ref, stream: false });
      return Effect.suspend(() => {
        // Whether the answer comes before any other task of this turn could run: at once, or later.
        let sync = true;
        queueMicrotask(() => (sync = false));
        return send.pipe(
          Effect.onExit((exit) =>
            Effect.sync(() => {
              if (interrupted(exit)) return;
              const at = sync ? { sync: true as const } : {};
              if (Exit.isSuccess(exit)) {
                const r: ApiResponse = exit.value;
                this.input({
                  kind: "response",
                  request: ref,
                  status: r.status,
                  headers: r.headers,
                  body: base64(r.body),
                  ...at,
                });
              } else
                this.input({
                  kind: "failure",
                  request: ref,
                  message: failureMessage(exit.cause),
                  ...defect(exit.cause),
                  ...at,
                });
            })
          )
        );
      });
    };
    const storageWrite = (
      op: "set" | "delete",
      key: string,
      send: Effect.Effect<void, HostError>
    ) =>
      send.pipe(
        Effect.onExit((exit) =>
          interrupted(exit)
            ? Effect.void
            : Effect.sync(() =>
                this.input({
                  kind: "storage",
                  op,
                  key,
                  ...(Exit.isSuccess(exit)
                    ? {}
                    : { failure: failureMessage(exit.cause) }),
                })
              )
        )
      );
    // A host port's answer as JSON: noted as the answer to a request `<method> <path>`, and read back as one.
    // `R`: what answering needs (a loopback listener's Scope).
    const port = <A, R = never>(
      method: string,
      path: string,
      send: Effect.Effect<A, HostError, R>,
      json: (a: A) => unknown = (a) => a,
      ref?: RequestRef
    ): Effect.Effect<A, HostError, R> => {
      let value!: A;
      return answered(
        { method, path },
        send.pipe(
          Effect.map((out): ApiResponse => {
            value = out;
            return {
              status: 200,
              headers: [],
              body: utf8(JSON.stringify(json(out) ?? null)),
            };
          })
        ),
        ref
      ).pipe(Effect.map(() => value));
    };
    // A response whose body arrives in pieces: its head and each piece (or how it broke) noted as they come.
    const streamed = (
      request: { method: string; path: string },
      send: Effect.Effect<StreamResponse, HostError, Scope.Scope>
    ): Effect.Effect<StreamResponse, HostError, Scope.Scope> => {
      const ref = this.#ref(request);
      this.output({ kind: "request", request: ref, stream: true });
      return send.pipe(
        Effect.onExit((exit) =>
          Effect.sync(() => {
            if (!Exit.isSuccess(exit) && !interrupted(exit))
              this.input({
                kind: "failure",
                request: ref,
                message: failureMessage(exit.cause),
                ...defect(exit.cause),
              });
          })
        ),
        Effect.map((response) => {
          const stream = this.#streams++;
          this.input({
            kind: "stream",
            request: ref,
            stream,
            status: response.status,
            headers: response.headers,
          });
          const body: Pull<Uint8Array> = {
            take: response.body.take.pipe(
              Effect.onExit((exit) =>
                Effect.sync(() => {
                  if (interrupted(exit)) return;
                  if (!Exit.isSuccess(exit))
                    this.input({
                      kind: "broken",
                      stream,
                      message: failureMessage(exit.cause),
                    });
                  else if (exit.value === null) this.input({ kind: "end", stream });
                  else this.input({ kind: "piece", stream, body: base64(exit.value) });
                })
              )
            ),
          };
          return { ...response, body };
        })
      );
    };
    const recorded: Host = {
      sessionSource: host.sessionSource,
      ...(host.deviceSetup ? { deviceSetup: host.deviceSetup } : {}),
      ...(host.uploadsLocalFiles ? { uploadsLocalFiles: true } : {}),
      ...(host.client ? { client: host.client } : {}),
      fetch: (request) => answered(request, host.fetch(request)),
      fetchStream: (request) => streamed(request, host.fetchStream(request)),
      // Device storage and databases are what the core finds of earlier runs: inputs too. Each storage read's value
      // (and whether each write took) is noted as it is answered; a database is noted as its rows when it opens.
      storageGet: (key) =>
        host.storageGet(key).pipe(
          Effect.onExit((exit) =>
            interrupted(exit)
              ? Effect.void
              : Effect.sync(() =>
                  this.input({
                    kind: "storage",
                    op: "get",
                    key,
                    ...(Exit.isSuccess(exit)
                      ? { value: exit.value ? base64(exit.value) : null }
                      : { failure: failureMessage(exit.cause) }),
                  })
                )
          )
        ),
      storageSet: (key, value) => storageWrite("set", key, host.storageSet(key, value)),
      storageDelete: (key) => storageWrite("delete", key, host.storageDelete(key)),
      openDb: (name) =>
        host.openDb(name).pipe(
          Effect.tap((db) =>
            Effect.sync(() => this.input({ kind: "db", name, tables: dumpDb(db) }))
          ),
          Effect.tapError((e) =>
            Effect.sync(() =>
              this.input({ kind: "dbFailure", name, message: e.message })
            )
          )
        ),
      memoryDb: Effect.suspend(() => host.memoryDb),
      deleteDb: (name) => host.deleteDb(name),
      // Each turn the host gave is noted as an answer (`HOST turn`): replayed, it comes where the log has it.
      yieldTurn: Effect.suspend(() =>
        answered(
          { method: "HOST", path: "turn" },
          host.yieldTurn.pipe(
            Effect.as({ status: 200, headers: [], body: new Uint8Array() })
          )
        ).pipe(Effect.asVoid, Effect.orDie)
      ),
      randomBytes: (buf) => {
        host.randomBytes(buf);
        this.input({ kind: "random", bytes: base64(buf) });
      },
      emit: (client, message) => {
        this.output({ kind: "emit", client, message: structuredClone(message) });
        host.emit(client, message);
      },
    };
    this.input({
      kind: "capabilities",
      preview: Boolean(host.renderImagePreview),
      transcode: Boolean(host.transcodeImage),
      ...(host.meeting ? { meeting: true } : {}),
      ...(host.voiceCall ? { voiceCall: true } : {}),
      ...(host.uploadsLocalFiles ? { localFiles: true } : {}),
      ...(host.readLocalFile ? { readsLocalFiles: true } : {}),
      ...(host.client ? { client: host.client } : {}),
    });
    const readLocal = host.readLocalFile?.bind(host);
    if (readLocal)
      (recorded as { readLocalFile?: Host["readLocalFile"] }).readLocalFile = (
        ref,
        offset,
        length
      ) =>
        port(
          "HOST",
          `localFile:${ref}:${offset}:${length}`,
          readLocal(ref, offset, length),
          (bytes) => base64(bytes)
        );
    const meeting = host.meeting;
    if (meeting)
      (recorded as { meeting?: MeetingPorts }).meeting = {
        // Main's answers are noted as requests' answers (`HOST meeting:<op>`).
        command: (op, input) =>
          port("HOST", `meeting:${op}`, meeting.command(op, input)),
        listen: (listener) =>
          meeting.listen((event) => {
            this.input({ kind: "meeting", event: structuredClone(event) });
            listener(event);
          }),
      };
    const voiceCall = host.voiceCall;
    if (voiceCall)
      (recorded as { voiceCall?: VoiceCallPorts }).voiceCall = {
        command: (op) => {
          this.output({ kind: "voiceCall", op: structuredClone(op) });
          voiceCall.command(op);
        },
        listen: (listener) =>
          voiceCall.listen((event) => {
            this.input({ kind: "voiceCall", event: structuredClone(event) });
            listener(event);
          }),
      };
    const preview = host.renderImagePreview?.bind(host);
    if (preview)
      recorded.renderImagePreview = (input) =>
        preview(input).pipe(
          Effect.onExit((exit) =>
            interrupted(exit)
              ? Effect.void
              : Effect.sync(() =>
                  this.input(
                    Exit.isSuccess(exit)
                      ? { kind: "image", op: "preview", bytes: base64(exit.value) }
                      : {
                          kind: "image",
                          op: "preview",
                          failure: failureMessage(exit.cause),
                        }
                  )
                )
          )
        );
    const transcode = host.transcodeImage?.bind(host);
    if (transcode)
      recorded.transcodeImage = (input) =>
        transcode(input).pipe(
          Effect.onExit((exit) =>
            interrupted(exit)
              ? Effect.void
              : Effect.sync(() =>
                  this.input(
                    Exit.isSuccess(exit)
                      ? {
                          kind: "image",
                          op: "transcode",
                          bytes: base64(exit.value.bytes),
                          name: exit.value.name,
                          mediaType: exit.value.mediaType,
                        }
                      : {
                          kind: "image",
                          op: "transcode",
                          failure: failureMessage(exit.cause),
                        }
                  )
                )
          )
        );
    const authFetch = host.authFetch?.bind(host);
    if (authFetch)
      recorded.authFetch = (request) => answered(request, authFetch(request));
    const ports = host.webSession;
    if (ports) {
      this.input({
        kind: "web",
        apiOrigin: ports.apiOrigin,
        userAgent: ports.userAgent,
      });
      (recorded as { webSession?: WebSessionPorts }).webSession = {
        apiOrigin: ports.apiOrigin,
        userAgent: ports.userAgent,
        // A grant is the answer to `LOCK <name>` (`{"granted":true}`, or `{"unsupported":...}` where there are no Web
        // Locks); letting it go is an output.
        lock: (name) => {
          const ref = this.#ref({ method: "LOCK", path: name });
          let release: (() => void) | null = null;
          return port(
            "LOCK",
            name,
            ports.lock(name).pipe(
              Effect.map((r): LockAnswer => ((release = r), { granted: true })),
              Effect.catchIf(
                (e) => e instanceof HostUnsupported,
                (e): Effect.Effect<LockAnswer> =>
                  Effect.succeed({ unsupported: e.message })
              )
            ),
            (a) => a,
            ref
          ).pipe(
            Effect.flatMap((answer) =>
              "unsupported" in answer
                ? Effect.fail(new HostUnsupported(answer.unsupported))
                : Effect.succeed(() => {
                    const held = release;
                    if (!held) return;
                    release = null;
                    this.output({ kind: "unlock", request: ref });
                    held();
                  })
            )
          );
        },
        // Digests as base64, in order.
        sha256: (inputs) =>
          port("HOST", "sha256", ports.sha256(inputs), (digests) =>
            digests.map(base64)
          ),
        channel: (name) => {
          const channel = ports.channel(name);
          return {
            post: (message) => {
              this.output({ kind: "hint", message: structuredClone(message) });
              channel.post(message);
            },
            listen: (listener) =>
              channel.listen((message) => {
                this.input({ kind: "hint", message: structuredClone(message) });
                listener(message);
              }),
            close: () => channel.close(),
          };
        },
      };
    }
    const bearer = host.bearerSession;
    if (bearer) {
      this.input({
        kind: "bearer",
        apiOrigin: bearer.apiOrigin,
        clientPlatform: bearer.clientPlatform,
        ...(bearer.clientKind ? { clientKind: bearer.clientKind } : {}),
        ...(bearer.showsKeptAccount ? { showsKeptAccount: true as const } : {}),
        ...(bearer.resumed ? { resumed: structuredClone(bearer.resumed) } : {}),
      });
      // Main's answers are JSON: each is noted as a request's answer (`HOST <port>`), and read back as one.
      const main = <A>(path: string, send: Effect.Effect<A, HostError>) =>
        port("HOST", path, send);
      (recorded as { bearerSession?: BearerSessionPorts }).bearerSession = {
        apiOrigin: bearer.apiOrigin,
        clientPlatform: bearer.clientPlatform,
        ...(bearer.clientKind ? { clientKind: bearer.clientKind } : {}),
        ...(bearer.showsKeptAccount ? { showsKeptAccount: true } : {}),
        ...(bearer.resumed ? { resumed: bearer.resumed } : {}),
        vault: Effect.suspend(() => main("vault", bearer.vault)),
        change: (change) => main(`change:${change.kind}`, bearer.change(change)),
        ...(bearer.google
          ? { google: (input) => main("google", bearer.google!(input)) }
          : {}),
        ...(bearer.googleDone
          ? {
              googleDone: (grant, ok) =>
                Effect.ignore(main("googleDone", bearer.googleDone!(grant, ok))),
            }
          : {}),
        ...(bearer.apple
          ? { apple: (input) => main("apple", bearer.apple!(input)) }
          : {}),
        gate: (snapshot, lease) => {
          this.output({
            kind: "gate",
            snapshot: structuredClone(snapshot),
            lease: lease ? { ...lease } : null,
          });
          bearer.gate(snapshot, lease);
        },
      };
    }
    const drive = host.localDrive;
    if (drive) {
      this.input({ kind: "localDrive" });
      (recorded as { localDrive?: LocalDrivePorts }).localDrive = {
        // The node's answers are noted as requests' answers (`HOST localDrive.<op>`).
        state: Effect.suspend(() => port("HOST", "localDrive.state", drive.state)),
        list: (input) =>
          port("HOST", `localDrive.list:${input.space}`, drive.list(input)),
        // A read's bytes are noted as base64.
        run: (name, input) =>
          port("HOST", `localDrive.${name}`, drive.run(name, input), (out) =>
            name === "read" &&
            out !== null &&
            typeof out === "object" &&
            "content" in out
              ? { ...out, content: base64((out as { content: Uint8Array }).content) }
              : out
          ),
        onChange: (listener) =>
          drive.onChange(() => {
            this.input({ kind: "localDriveChanged" });
            listener();
          }),
      };
    }
    const downloads = host.downloads;
    if (downloads) {
      this.input({ kind: "downloads" });
      (recorded as { downloads?: DownloadPorts }).downloads = {
        open: (request, path) =>
          port("HOST", "downloads.open", downloads.open(request, path)),
        step: (id) => port("HOST", "downloads.step", downloads.step(id)),
        close: (id) => port("HOST", "downloads.close", downloads.close(id)),
        create: (path) => port("HOST", "downloads.create", downloads.create(path)),
        append: (id, bytes) =>
          port("HOST", "downloads.append", downloads.append(id, bytes)),
        finish: (id) => port("HOST", "downloads.finish", downloads.finish(id)),
        remove: (path) => port("HOST", "downloads.remove", downloads.remove(path)),
        retain: (keep) => port("HOST", "downloads.retain", downloads.retain(keep)),
      };
    }
    const reset = host.reset;
    if (reset) {
      this.input({ kind: "reset" });
      (recorded as { reset?: ResetPorts }).reset = {
        clear: Effect.suspend(() => port("HOST", "reset.clear", reset.clear)),
        restart: Effect.suspend(() => port("HOST", "reset.restart", reset.restart)),
      };
    }
    const mesh = host.stationMesh;
    if (mesh) {
      this.input(
        mesh.alwaysLinked
          ? { kind: "stationMesh", alwaysLinked: true }
          : { kind: "stationMesh" }
      );
      (recorded as { stationMesh?: StationMeshPorts }).stationMesh = {
        ...(mesh.alwaysLinked ? { alwaysLinked: true } : {}),
        // The endpoint's id (and whether it is reached through Salix), each connection and relay socket opened and
        // closed, and each request's answer are noted as `MESH` requests'.
        open: (input) => {
          let links: StationLinks;
          return port(
            "MESH",
            "open",
            mesh.open(input).pipe(
              Effect.map((opened): { id: string; salix?: true } => {
                links = opened;
                return opened.relay
                  ? { id: opened.id, salix: true }
                  : { id: opened.id };
              })
            )
          ).pipe(
            Effect.map(
              (opened): StationLinks => ({
                id: opened.id,
                credential: (station, credential) =>
                  links.credential(station, credential),
                reach: (station, reach) => links.reach(station, reach),
                nextVia: (station, last) =>
                  port("MESH", `via:${station}`, links.nextVia(station, last)),
                connect: (station) => {
                  let closed: Effect.Effect<void>;
                  return port(
                    "MESH",
                    `connect:${station}`,
                    links.connect(station).pipe(
                      Effect.map((ended) => {
                        closed = ended;
                        return null;
                      })
                    )
                  ).pipe(
                    Effect.map(() =>
                      Effect.ignore(
                        port("MESH", `closed:${station}`, closed.pipe(Effect.as(null)))
                      )
                    )
                  );
                },
                request: (station, request) =>
                  streamed(
                    {
                      method: `MESH ${request.method}`,
                      path: `${station}${request.path}`,
                    },
                    links.request(station, request)
                  ),
                ...(opened.salix
                  ? {
                      relay: (workspace: string, ticket: StationRelayTicket) => {
                        let closed: Effect.Effect<void>;
                        return port(
                          "MESH",
                          `relay:${workspace}`,
                          links.relay!(workspace, ticket).pipe(
                            Effect.map((ended) => {
                              closed = ended;
                              return null;
                            })
                          )
                        ).pipe(
                          Effect.map(() =>
                            Effect.ignore(
                              port(
                                "MESH",
                                `relayed:${workspace}`,
                                closed.pipe(Effect.as(null))
                              )
                            )
                          )
                        );
                      },
                    }
                  : {}),
              })
            )
          );
        },
      };
    }
    const desktop = host.desktop;
    if (desktop) {
      const updates = desktop.updates;
      this.input({
        kind: "desktop",
        app: { ...desktop.app },
        ...(updates ? { updates: true as const } : {}),
      });
      (recorded as { desktop?: DesktopPorts }).desktop = {
        app: desktop.app,
        presence: Effect.suspend(() => port("HOST", "presence", desktop.presence)),
        openExternal: (url) => port("HOST", "openExternal", desktop.openExternal(url)),
        returnToApp: Effect.suspend(() =>
          Effect.ignore(port("HOST", "returnToApp", desktop.returnToApp))
        ),
        // Each upload's bytes as base64.
        pickAttachments: (request) =>
          port("HOST", "chatPick", desktop.pickAttachments(request), recordChatPick),
        saveDownload: (fileName, content) =>
          port("HOST", "saveDownload", desktop.saveDownload(fileName, content)),
        saveOpen: (fileName) => port("HOST", "saveOpen", desktop.saveOpen(fileName)),
        saveWrite: (id, bytes) =>
          Effect.asVoid(port("HOST", "saveWrite", desktop.saveWrite(id, bytes))),
        saveClose: (id, keep) => port("HOST", "saveClose", desktop.saveClose(id, keep)),
        openStream: (input) => port("HOST", "openStream", desktop.openStream(input)),
        closeStream: (url) =>
          Effect.asVoid(port("HOST", "closeStream", desktop.closeStream(url))),
        saveStream: (input) => port("HOST", "saveStream", desktop.saveStream(input)),
        // The port it took is noted; each visit's address too, and the page it was shown as what the core sent.
        listen: (input) => {
          let open: Loopback;
          return port(
            "HOST",
            `listen:${input.port}`,
            desktop.listen(input).pipe(
              Effect.map((loopback) => {
                open = loopback;
                return { port: loopback.port };
              })
            )
          ).pipe(
            Effect.map(
              (opened): Loopback => ({
                port: opened.port,
                // Taken again for each visit: noted as each is.
                next: Effect.suspend(() => {
                  let visit: LoopbackVisit;
                  return port(
                    "HOST",
                    "visit",
                    open.next.pipe(
                      Effect.map((taken) => {
                        visit = taken;
                        return { url: taken.url };
                      })
                    )
                  ).pipe(
                    Effect.map(
                      (answer): LoopbackVisit => ({
                        url: answer.url,
                        reply: (page) =>
                          Effect.ignore(
                            port("HOST", `reply:${page}`, visit.reply(page))
                          ),
                      })
                    )
                  );
                }),
              })
            )
          );
        },
        providerFetch: (request) =>
          answered(
            { method: request.method, path: request.url },
            desktop.providerFetch(request)
          ),
        sha256: (input) =>
          port("HOST", "sha256", desktop.sha256(input), (bytes) => base64(bytes)),
        ...(updates
          ? {
              updates: {
                status: Effect.suspend(() =>
                  port("HOST", "update.status", updates.status)
                ),
                check: Effect.suspend(() =>
                  port("HOST", "update.check", updates.check)
                ),
                download: (release) =>
                  port("HOST", "update.download", updates.download(release)),
                apply: (release) =>
                  port("HOST", "update.apply", updates.apply(release)),
              },
            }
          : {}),
      };
    }
    const legacy = host.legacyTasks?.bind(host);
    if (legacy)
      recorded.legacyTasks = (audience, userId) =>
        legacy(audience, userId).pipe(
          Effect.onExit((exit) =>
            interrupted(exit)
              ? Effect.void
              : Effect.sync(() => {
                  if (Exit.isSuccess(exit))
                    this.input({ kind: "legacy", tasks: structuredClone(exit.value) });
                  else
                    this.input({
                      kind: "legacyFailure",
                      message: failureMessage(exit.cause),
                    });
                })
          )
        );
    return recorded;
  }

  /**
   * `lifecycle` as the core's embedder sees it: each of its operations (`LIFECYCLE_OPERATIONS`) noted as an input as it
   * begins. The core's own calls of them (its UIs' `session.*` calls, its refused requests) are not: their causes are.
   */
  lifecycle<T extends object>(lifecycle: T): T {
    return new Proxy(lifecycle, {
      get: (target, name) => {
        const value: unknown = Reflect.get(target, name, target);
        if (typeof value !== "function") return value;
        if (typeof name !== "string" || !LIFECYCLE_OPERATIONS.has(name))
          return (value as (...args: unknown[]) => unknown).bind(target);
        return (...args: unknown[]) => {
          const note = () =>
            this.input({ kind: "operation", name, args: structuredClone(args) });
          if (LIFECYCLE_EFFECTS.has(name)) {
            const effect = (
              value as (...args: unknown[]) => Effect.Effect<unknown>
            ).apply(target, args);
            return Effect.suspend(() => (note(), effect));
          }
          note();
          return (value as (...args: unknown[]) => unknown).apply(target, args);
        };
      },
    });
  }
}

/** The session lifecycles' operations that run as effects: noted when one is run. */
const LIFECYCLE_EFFECTS = new Set([
  "reconcile",
  "recover",
  "requestEmailLogin",
  "verifyEmailLogin",
  "verifyGoogleLink",
  "signInWithGoogle",
  "cancelAuthAttempt",
  "signOut",
  "retryPendingRevocations",
  "beginGoogleLogin",
  "completeGoogleLogin",
  "guestAvailability",
  "startGuestSession",
  "beginGuestSignUp",
  "handOverGuestImport",
  "telegram",
]);
/** Every operation on a session lifecycle that changes it: the effects, and what it is told at once. */
const LIFECYCLE_OPERATIONS = new Set([
  ...LIFECYCLE_EFFECTS,
  "productUnauthorized",
  "productSessionChanged",
]);

type LockAnswer = { granted: true } | { unsupported: string };

/** A port that threw (died) rather than failed: the core handles that otherwise, so a replay must too. */
function defect(cause: Cause.Cause<unknown>): { defect?: true } {
  return !Cause.hasFails(cause) && Cause.hasDies(cause) ? { defect: true } : {};
}

function failureMessage(cause: Cause.Cause<unknown>): string {
  const error = Cause.squash(cause);
  return error instanceof Error ? error.message : String(error);
}

/** A database's schema and rows, in the order they were made. */
export type DbDump = {
  version?: number;
  schema: string[];
  rows: Record<string, unknown[][]>;
};

const quote = (name: string) => `"${name.replaceAll('"', '""')}"`;
const toJson = (v: SqlValue): unknown =>
  v instanceof Uint8Array ? { $b: base64(v) } : v;
const fromJson = (v: unknown): SqlValue =>
  v !== null && typeof v === "object" && "$b" in v
    ? fromBase64((v as { $b: string }).$b)
    : (v as SqlValue);

/** What `db` holds now. */
export function dumpDb(db: Sql): DbDump {
  const objects = db.all(
    "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY rowid"
  );
  const version = Number(db.all("PRAGMA user_version")[0]?.[0] ?? 0);
  const dump: DbDump = { ...(version ? { version } : {}), schema: [], rows: {} };
  for (const [type, name, sql] of objects) {
    dump.schema.push(String(sql));
    if (type === "table")
      dump.rows[String(name)] = db
        .all(`SELECT * FROM ${quote(String(name))}`)
        .map((row) => row.map(toJson));
  }
  return dump;
}

/** `dump` made again in `db` (empty). */
export function restoreDb(db: Sql, dump: DbDump): void {
  for (const sql of dump.schema) db.exec(sql);
  if (dump.version) db.exec(`PRAGMA user_version = ${Math.trunc(dump.version)}`);
  for (const [table, rows] of Object.entries(dump.rows))
    for (const row of rows)
      db.run(
        `INSERT INTO ${quote(table)} VALUES (${row.map(() => "?").join(", ")})`,
        row.map(fromJson)
      );
}
