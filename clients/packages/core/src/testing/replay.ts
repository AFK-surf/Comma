// A recorded run (record.ts) played again: a new core on a TestClock and a fresh fake host, told the same inputs at
// the same times. Each request it makes is answered with what the log says that request was answered, when it says;
// a request the log does not have, or an answer to one the core did not make, is a divergence and fails the replay.
import { fromUtf8, HostError, type ClientId, type Sql } from "@comma/core-kernel";
import { NodeSql } from "@comma/core-kernel/node-sql";
import { TestTime } from "@comma/core-kernel/testing";
import { HostUnsupported } from "../host.ts";
import { Effect, type Scope } from "effect";
import { Core } from "../core.ts";
import type { CoreLimits } from "../limits.ts";
import type { StationVia } from "../contract.ts";
import type {
  ApiRequest,
  ApiResponse,
  AppRelease,
  AppUpdateStatus,
  AuthRequest,
  DesktopPorts,
  LegacyWorkspaceTasks,
  Loopback,
  MeetingEvent,
  Pull,
  VoiceCallSocketEvent,
  ResetPorts,
  StationLinks,
  StreamResponse,
} from "../host.ts";
import {
  chatPickOf,
  type Entry,
  fromBase64,
  type RecordedChatPick,
  type Input,
  type Output,
  Recorder,
  type RequestRef,
  type DbDump,
  restoreDb,
} from "../record.ts";
import { FakeHost, FakeStream, flush } from "./index.ts";

type Answer =
  | { response: ApiResponse }
  | { stream: FakeStream; status: number; headers: [string, string][] }
  | { failure: string; defect?: boolean };

const refKey = (r: RequestRef) => `${r.method} ${r.path} #${r.n}`;

/** A fake host whose network, random bytes and legacy lists come from a log. */
class ReplayHost extends FakeHost {
  readonly #waiting = new Map<string, (answer: Answer) => void>();
  /** Answers whose turn in the log has come before the core asked for them: given as soon as it does. */
  readonly #ready = new Map<string, Answer>();
  readonly #counts = new Map<string, number>();
  readonly random: Uint8Array[] = [];
  readonly legacy: (LegacyWorkspaceTasks[] | HostError)[] = [];

  /** Answers the log has as given at once, in the turn the core asked: given so again. */
  readonly atOnce = new Map<string, Answer>();

  #ask(request: { method: string; path: string }): Effect.Effect<Answer> {
    const key = `${request.method} ${request.path}`;
    const n = this.#counts.get(key) ?? 0;
    this.#counts.set(key, n + 1);
    const ref = refKey({ method: request.method, path: request.path, n });
    const now = this.atOnce.get(ref);
    if (now) {
      this.atOnce.delete(ref);
      return Effect.succeed(now);
    }
    const ready = this.#ready.get(ref);
    if (ready) {
      this.#ready.delete(ref);
      return Effect.succeed(ready);
    }
    return Effect.callback<Answer>((resume) => {
      this.#waiting.set(ref, (answer) => resume(Effect.succeed(answer)));
      return Effect.sync(() => void this.#waiting.delete(ref));
    });
  }

  /** Answers the request `ref` names; false when the core has not made it. */
  answer(ref: RequestRef, answer: Answer): boolean {
    const waiting = this.#waiting.get(refKey(ref));
    if (!waiting) return false;
    this.#waiting.delete(refKey(ref));
    waiting(answer);
    return true;
  }

  /** Answers the request `ref` names now if the core has made it, else the moment it does. */
  release(ref: RequestRef, answer: Answer): void {
    if (!this.answer(ref, answer)) this.#ready.set(refKey(ref), answer);
  }

  /** Requests the core made that wait for an answer. */
  waiting(): string[] {
    return [...this.#waiting.keys()];
  }

  /** Answers released that no request took. */
  unasked(): string[] {
    return [...this.#ready.keys(), ...this.atOnce.keys()];
  }

  override fetch(request: ApiRequest): Effect.Effect<ApiResponse, HostError> {
    return this.#answered(request);
  }

  /** A turn of the host's, given where the log has it. */
  override get yieldTurn(): Effect.Effect<void> {
    return this.#answered({ method: "HOST", path: "turn" }).pipe(
      Effect.asVoid,
      Effect.orDie
    );
  }

  override authFetch(request: AuthRequest): Effect.Effect<ApiResponse, HostError> {
    return this.#answered(request);
  }

  #answered(request: {
    method: string;
    path: string;
  }): Effect.Effect<ApiResponse, HostError> {
    return this.#ask(request).pipe(
      Effect.flatMap((answer) =>
        "response" in answer
          ? Effect.succeed(answer.response)
          : "failure" in answer
            ? failed(answer)
            : Effect.fail(new HostError("the log answered with a stream"))
      )
    );
  }

  override fetchStream(
    request: ApiRequest
  ): Effect.Effect<StreamResponse, HostError, Scope.Scope> {
    return this.#streamed(request);
  }

  #streamed(request: {
    method: string;
    path: string;
  }): Effect.Effect<StreamResponse, HostError, Scope.Scope> {
    return this.#ask(request).pipe(
      Effect.flatMap((answer): Effect.Effect<StreamResponse, HostError> => {
        if ("stream" in answer)
          return Effect.succeed({
            status: answer.status,
            headers: answer.headers,
            body: answer.stream,
          });
        if ("failure" in answer) return failed(answer);
        return Effect.succeed({
          status: answer.response.status,
          headers: answer.response.headers,
          body: once(answer.response.body),
        });
      })
    );
  }

  /** Databases as they opened in the recorded run, by name, in order: each given when the log reaches its opening. */
  readonly #openings = new Map<
    string,
    { ready: (DbDump | HostError)[]; waiting: ((d: DbDump | HostError) => void)[] }
  >();

  #opening(name: string) {
    let entry = this.#openings.get(name);
    if (!entry) this.#openings.set(name, (entry = { ready: [], waiting: [] }));
    return entry;
  }

  /** The log reached a database's opening: the core's open that waits for it gets it, or the next one at once. */
  opened(name: string, dump: DbDump | HostError): void {
    const entry = this.#opening(name);
    const waiting = entry.waiting.shift();
    if (waiting) waiting(dump);
    else entry.ready.push(dump);
  }

  override openDb(name: string): Effect.Effect<Sql, HostError> {
    return Effect.callback<DbDump | HostError>((resume) => {
      const entry = this.#opening(name);
      const ready = entry.ready.shift();
      const give = (d: DbDump | HostError) => resume(Effect.succeed(d));
      if (ready !== undefined) give(ready);
      else entry.waiting.push(give);
      return Effect.sync(() => {
        const at = entry.waiting.indexOf(give);
        if (at >= 0) entry.waiting.splice(at, 1);
      });
    }).pipe(
      Effect.flatMap((next) => {
        if (next instanceof HostError) return Effect.fail(next);
        const db = NodeSql.memory(true);
        restoreDb(db, next);
        return Effect.succeed(db as Sql);
      })
    );
  }

  /** Device storage's answers, by operation and key, in the order the log has them (asked synchronously). */
  readonly storageAnswers = new Map<string, Extract<Input, { kind: "storage" }>[]>();

  #storage(
    op: "get" | "set" | "delete",
    key: string
  ): Effect.Effect<string | null, HostError> {
    return Effect.suspend(() => {
      const answer = this.storageAnswers.get(`${op} ${key}`)?.shift();
      if (!answer)
        return Effect.fail(
          new HostError(`replay: the log has no storage ${op} of ${key}`)
        );
      return answer.failure !== undefined
        ? Effect.fail(new HostError(answer.failure))
        : Effect.succeed(answer.value ?? null);
    });
  }

  override storageGet(key: string): Effect.Effect<Uint8Array | null, HostError> {
    return this.#storage("get", key).pipe(
      Effect.map((v) => (v === null ? null : fromBase64(v)))
    );
  }

  override storageSet(key: string): Effect.Effect<void, HostError> {
    return Effect.asVoid(this.#storage("set", key));
  }

  override storageDelete(key: string): Effect.Effect<void, HostError> {
    return Effect.asVoid(this.#storage("delete", key));
  }

  override randomBytes(buf: Uint8Array): void {
    const bytes = this.random.shift();
    if (!bytes || bytes.length !== buf.length)
      throw new Error("replay: the core asked for random bytes the log does not have");
    buf.set(bytes);
  }

  /** Image capability answers, in the order the log has them. */
  readonly images: Extract<Input, { kind: "image" }>[] = [];

  /** The image capabilities the recorded host had, answered from the log. */
  serveImages(preview: boolean, transcode: boolean): void {
    const next = (
      op: "preview" | "transcode"
    ): Effect.Effect<Extract<Input, { kind: "image" }>, HostError> => {
      const at = this.images.findIndex((image) => image.op === op);
      if (at < 0)
        return Effect.fail(new HostError(`replay: no ${op} answer in the log`));
      const [image] = this.images.splice(at, 1);
      return image!.failure !== undefined
        ? Effect.fail(new HostError(image!.failure))
        : Effect.succeed(image!);
    };
    if (preview)
      this.renderImagePreview = () =>
        next("preview").pipe(Effect.map((image) => fromBase64(image.bytes ?? "")));
    if (transcode)
      this.transcodeImage = () =>
        next("transcode").pipe(
          Effect.map((image) => ({
            bytes: fromBase64(image.bytes ?? ""),
            name: image.name ?? "",
            mediaType: image.mediaType ?? "",
          }))
        );
  }

  /** A host port's answer, read back from the log (a `<method> <path>` request answered with JSON). */
  #port<A>(method: string, path: string): Effect.Effect<A, HostError> {
    return this.#answered({ method, path }).pipe(
      Effect.map((response) => JSON.parse(fromUtf8(response.body)) as A)
    );
  }

  /** Main's session ports, answered from the log, when the recorded core ran Electron's session lifecycle. */
  serveBearer(input: Extract<Input, { kind: "bearer" }>): void {
    const port = <A>(path: string) => this.#port<A>("HOST", path);
    this.bearerSession = {
      apiOrigin: input.apiOrigin,
      clientPlatform: input.clientPlatform,
      ...(input.clientKind ? { clientKind: input.clientKind } : {}),
      ...(input.showsKeptAccount ? { showsKeptAccount: true } : {}),
      ...(input.resumed ? { resumed: input.resumed } : {}),
      vault: Effect.suspend(() => port("vault")),
      change: (change: { kind: string }) => port(`change:${change.kind}`),
      // The iPhone signs in with Apple's sheet, the others with Google.
      ...(input.clientKind === "ios"
        ? { apple: () => port("apple") }
        : {
            google: () => port("google"),
            googleDone: () => Effect.ignore(port("googleDone")),
          }),
      gate: () => undefined,
    };
  }

  readonly #driveListeners = new Set<() => void>();

  /** The local Drive node, answered from the log, when the recorded host had one. */
  serveLocalDrive(): void {
    const port = <A>(path: string) => this.#port<A>("HOST", path);
    this.localDrive = {
      state: Effect.suspend(() => port("localDrive.state")),
      list: (input) => port(`localDrive.list:${input.space}`),
      run: (name) =>
        port<never>(`localDrive.${name}`).pipe(
          Effect.map((out) =>
            name === "read"
              ? {
                  ...(out as object),
                  content: fromBase64((out as { content: string }).content),
                }
              : out
          )
        ) as never,
      onChange: (listener) => {
        this.#driveListeners.add(listener);
        return () => void this.#driveListeners.delete(listener);
      },
    };
  }

  /** The host's downloads, answered from the log, when the recorded host had them. */
  serveDownloads(): void {
    const port = <A>(path: string) => this.#port<A>("HOST", path);
    this.downloads = {
      open: () => port("downloads.open"),
      step: () => port("downloads.step"),
      close: () => port("downloads.close"),
      create: () => port("downloads.create"),
      append: () => port("downloads.append"),
      finish: () => port("downloads.finish"),
      remove: () => port("downloads.remove"),
      retain: () => port("downloads.retain"),
    };
  }

  /** The app reset's ports, answered from the log, when the recorded host had them (none otherwise). */
  override reset: ResetPorts | undefined = undefined;

  serveReset(): void {
    this.reset = {
      clear: Effect.suspend(() => this.#port("HOST", "reset.clear")),
      restart: Effect.suspend(() => this.#port("HOST", "reset.restart")),
    };
  }

  /** The station mesh, answered from the log (`MESH` requests), when the recorded host had one. */
  serveStationMesh(alwaysLinked: boolean): void {
    this.stationMesh = {
      ...(alwaysLinked ? { alwaysLinked: true } : {}),
      open: () =>
        this.#port<{ id: string; salix?: true }>("MESH", "open").pipe(
          Effect.map(
            ({ id, salix }): StationLinks => ({
              id,
              credential: () => undefined,
              reach: () => undefined,
              nextVia: (station) =>
                this.#port<{ via: StationVia | null; closed: boolean } | null>(
                  "MESH",
                  `via:${station}`
                ),
              connect: (station) =>
                this.#port("MESH", `connect:${station}`).pipe(
                  Effect.as(Effect.ignore(this.#port("MESH", `closed:${station}`)))
                ),
              request: (station, request) =>
                this.#streamed({
                  method: `MESH ${request.method}`,
                  path: `${station}${request.path}`,
                }),
              ...(salix
                ? {
                    relay: (workspace: string) =>
                      this.#port("MESH", `relay:${workspace}`).pipe(
                        Effect.as(
                          Effect.ignore(this.#port("MESH", `relayed:${workspace}`))
                        )
                      ),
                  }
                : {}),
            })
          )
        ),
    };
  }

  #meetingListener: ((event: MeetingEvent) => void) | null = null;

  /** Main's meeting parts, answered from the log, when the recorded core had them. */
  /** A part of a file a pick left with the app, as the log answered it. */
  override readLocalFile(
    ref: string,
    offset: number,
    length: number
  ): Effect.Effect<Uint8Array, HostError> {
    return this.#port<string>("HOST", `localFile:${ref}:${offset}:${length}`).pipe(
      Effect.map((bytes) => fromBase64(bytes))
    );
  }

  serveMeeting(): void {
    this.meeting = {
      command: (op) =>
        this.#answered({ method: "HOST", path: `meeting:${op}` }).pipe(
          Effect.map((response) => JSON.parse(fromUtf8(response.body)) as never)
        ),
      listen: (listener) => {
        this.#meetingListener = listener;
      },
    };
  }

  #voiceCallListener: ((event: VoiceCallSocketEvent) => void) | null = null;

  /** Main's voice call socket, when the recorded core had it: what the core asks of it is its output. */
  serveVoiceCall(): void {
    this.voiceCall = {
      command: () => undefined,
      listen: (listener) => {
        this.#voiceCallListener = listener;
      },
    };
  }

  /** What the voice call socket did, as the log has it. */
  voiceCallEvent(event: VoiceCallSocketEvent): void {
    this.#voiceCallListener?.(event);
  }

  /** The node said its files changed. */
  driveChanged(): void {
    for (const listener of this.#driveListeners) listener();
  }

  /** What Main's meeting parts saw, as the log has it. */
  meetingEvent(event: MeetingEvent): void {
    this.#meetingListener?.(event);
  }

  /**
   * The web session's ports when the recorded core had them: a Web Lock is granted (or found missing) when the log
   * says, and digests are the log's; hints come as the log's inputs.
   */
  serveWeb(input: Extract<Input, { kind: "web" }>): void {
    const port = <A>(method: string, path: string) => this.#port<A>(method, path);
    this.webSession = {
      apiOrigin: input.apiOrigin,
      userAgent: input.userAgent,
      lock: (name) =>
        port<{ granted: true } | { unsupported: string }>("LOCK", name).pipe(
          Effect.flatMap((answer) =>
            "unsupported" in answer
              ? Effect.fail(new HostUnsupported(answer.unsupported))
              : Effect.succeed(() => undefined)
          )
        ),
      channel: (name) => this.hints.open(name),
      sha256: () =>
        port<string[]>("HOST", "sha256").pipe(
          Effect.map((digests) => digests.map(fromBase64))
        ),
    };
  }

  /** The desktop ports, answered from the log (`HOST` requests), when the recorded core had them. */
  serveDesktop(input: Extract<Input, { kind: "desktop" }>): void {
    const port = <A>(path: string) => this.#port<A>("HOST", path);
    const desktop: DesktopPorts = {
      app: input.app,
      presence: Effect.suspend(() => port("presence")),
      openExternal: () => Effect.asVoid(port("openExternal")),
      returnToApp: Effect.suspend(() => Effect.ignore(port("returnToApp"))),
      pickAttachments: () =>
        port<RecordedChatPick>("chatPick").pipe(Effect.map(chatPickOf)),
      saveDownload: () => port("saveDownload"),
      saveOpen: () => port("saveOpen"),
      saveWrite: () => Effect.asVoid(port("saveWrite")),
      saveClose: () => port("saveClose"),
      openStream: () => port("openStream"),
      closeStream: () => Effect.asVoid(port("closeStream")),
      saveStream: () => port("saveStream"),
      listen: (request) =>
        port<{ port: number }>(`listen:${request.port}`).pipe(
          Effect.map(
            (answer): Loopback => ({
              port: answer.port,
              next: Effect.suspend(() =>
                port<{ url: string }>("visit").pipe(
                  Effect.map((visit) => ({
                    url: visit.url,
                    reply: (page) => Effect.ignore(port(`reply:${page}`)),
                  }))
                )
              ),
            })
          )
        ),
      providerFetch: (request) =>
        this.#answered({ method: request.method, path: request.url }),
      sha256: () => port<string>("sha256").pipe(Effect.map(fromBase64)),
      ...(input.updates
        ? {
            updates: {
              status: Effect.suspend(() => port<AppUpdateStatus>("update.status")),
              check: Effect.suspend(() => port<AppRelease | null>("update.check")),
              download: () => port<boolean>("update.download"),
              apply: () => port<boolean>("update.apply"),
            },
          }
        : {}),
    };
    this.desktop = desktop;
  }

  /** The host's legacy lists, when the log has them (a host without one has none). */
  serveLegacy(): void {
    this.legacyTasks = () => {
      const next = this.legacy.shift();
      if (next === undefined)
        return Effect.fail(new HostError("replay: no legacy lists in the log"));
      return next instanceof HostError ? Effect.fail(next) : Effect.succeed(next);
    };
  }
}

/** A host's failure as the log has it: failed, or (a port that threw) died. */
function failed(answer: {
  failure: string;
  defect?: boolean;
}): Effect.Effect<never, HostError> {
  return answer.defect
    ? Effect.die(new Error(answer.failure))
    : Effect.fail(new HostError(answer.failure));
}

function once(body: Uint8Array): Pull<Uint8Array> {
  let sent = false;
  return { take: Effect.sync(() => (sent ? null : ((sent = true), body))) };
}

export interface Replayed {
  core: Core;
  host: FakeHost;
  recorder: Recorder;
  /** What the replayed core sent and asked for, as the log's outputs are written. */
  outputs: Entry<Output>[];
}

/**
 * Plays `inputs` to a new core (`sessionSource`, `coalesceMs` and `limits` as the recorded one had them). Each input is given
 * when the TestClock reaches its time; then the clock runs on to `until` (the recorded run's last time).
 */
export async function replay(
  log: { inputs: Entry<Input>[]; outputs?: Entry<Output>[] },
  options: {
    sessionSource?: "host" | "core";
    coalesceMs?: number;
    limits?: Partial<CoreLimits>;
    until?: number;
  } = {}
): Promise<Replayed> {
  const { inputs } = log;
  // Where the recorded core sent something to a UI: an answer that came with no such send between it and the input
  // before it came in the same turn as that input (a fake server answers at once), and is given with it.
  const emits = (log.outputs ?? []).filter((o) => o.kind === "emit").map((o) => o.seq);
  const sentBetween = (from: number, to: number) =>
    emits.some((seq) => seq > from && seq < to);
  const outputSeqs = (log.outputs ?? []).map((o) => o.seq);
  const outputsBefore = (seq: number) => {
    // The log's outputs are in sequence order: the first at or after `seq`, by halves.
    let lo = 0;
    let hi = outputSeqs.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (outputSeqs[mid]! < seq) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  };
  // The clock starts where the recorded core's did: its first input came as it was made.
  const host = new ReplayHost({
    ...(options.sessionSource ? { sessionSource: options.sessionSource } : {}),
    time: new TestTime(inputs[0]?.at),
  });
  const time = host.time!;
  // Random bytes and legacy lists are asked for synchronously: queue them up front, in their order.
  for (const input of inputs) {
    if (input.kind === "random") host.random.push(fromBase64(input.bytes));
    if (input.kind === "legacy") host.legacy.push(input.tasks);
    if (input.kind === "legacyFailure") host.legacy.push(new HostError(input.message));
    if (input.kind === "storage") {
      const k = `${input.op} ${input.key}`;
      host.storageAnswers.set(k, [...(host.storageAnswers.get(k) ?? []), input]);
    }
  }
  if (host.legacy.length > 0) host.serveLegacy();
  for (const input of inputs) if (input.kind === "image") host.images.push(input);
  const capabilities = inputs.find((input) => input.kind === "capabilities");
  if (capabilities?.kind === "capabilities") {
    host.serveImages(capabilities.preview, capabilities.transcode);
    if (capabilities.meeting) host.serveMeeting();
    if (capabilities.voiceCall) host.serveVoiceCall();
    if (capabilities.localFiles) host.uploadsLocalFiles = true;
    if (capabilities.client) host.client = capabilities.client;
  }
  const bearer = inputs.find((input) => input.kind === "bearer");
  if (bearer?.kind === "bearer") host.serveBearer(bearer);
  if (inputs.some((input) => input.kind === "localDrive")) host.serveLocalDrive();
  if (inputs.some((input) => input.kind === "downloads")) host.serveDownloads();
  const mesh = inputs.find((input) => input.kind === "stationMesh");
  if (mesh?.kind === "stationMesh") host.serveStationMesh(mesh.alwaysLinked === true);
  if (inputs.some((input) => input.kind === "reset")) host.serveReset();
  const web = inputs.find((input) => input.kind === "web");
  if (web?.kind === "web") host.serveWeb(web);
  // An answer that came at once is given when the core asks (from its first step on), wherever its turn is.
  const atOnce: number[] = [];
  for (const input of inputs) {
    if (input.kind !== "response" && input.kind !== "failure") continue;
    if (!input.sync) continue;
    host.atOnce.set(
      refKey(input.request),
      input.kind === "failure"
        ? { failure: input.message, defect: input.defect === true }
        : {
            response: {
              status: input.status,
              headers: input.headers,
              body: fromBase64(input.body),
            },
          }
    );
    atOnce.push(input.seq);
  }
  const desktop = inputs.find((input) => input.kind === "desktop");
  if (desktop?.kind === "desktop") host.serveDesktop(desktop);
  const recorder = new Recorder();
  const core = new Core(host, {
    clock: time.clock,
    recorder,
    ...(options.coalesceMs !== undefined ? { coalesceMs: options.coalesceMs } : {}),
    ...(options.limits ? { limits: options.limits } : {}),
  });
  const streams = new Map<number, FakeStream>();
  const clients = new Map<ClientId, ClientId>();
  // Whether the core's work had settled when the replay last let it run: the clock can then move at once.
  let settled = false;
  const until = async (at: number) => {
    const ms = at - time.now();
    // Moving the clock lets the core run; an input at the same time goes in the same turn as the one before it.
    if (ms > 0) await (settled ? time.advance(ms) : time.pass(ms, ms));
  };

  const answerOf = (input: Entry<Input>): Answer | null => {
    if (input.kind === "response")
      return {
        response: {
          status: input.status,
          headers: input.headers,
          body: fromBase64(input.body),
        },
      };
    if (input.kind === "failure")
      return { failure: input.message, defect: input.defect === true };
    if (input.kind === "stream") {
      const stream = new FakeStream(input.request.path);
      streams.set(input.stream, stream);
      return { stream, status: input.status, headers: input.headers };
    }
    return null;
  };
  const released = new Set<number>(atOnce);
  /** Releases the answers that follow input `i` in the same turn. */
  const releaseAfter = (i: number) => {
    for (let j = i + 1; j < inputs.length; j++) {
      const next = inputs[j]!;
      if (next.at !== inputs[i]!.at || sentBetween(inputs[j - 1]!.seq, next.seq))
        return;
      // Released already, after an input before this one (random bytes asked between a call and its answer).
      if (released.has(next.seq)) continue;
      if (
        next.kind === "tick" ||
        next.kind === "random" ||
        next.kind === "legacy" ||
        next.kind === "legacyFailure" ||
        next.kind === "capabilities" ||
        next.kind === "db" ||
        next.kind === "storage" ||
        next.kind === "dbFailure" ||
        next.kind === "image" ||
        next.kind === "bearer" ||
        next.kind === "localDrive" ||
        next.kind === "downloads" ||
        next.kind === "stationMesh" ||
        next.kind === "web" ||
        next.kind === "desktop"
      )
        continue;
      if (released.has(next.seq)) continue;
      const answer = answerOf(next);
      if (!answer || !("request" in next)) return;
      host.release(next.request, answer);
      released.add(next.seq);
    }
  };

  /**
   * Lets the core go on until it has sent `target` outputs: microtask by microtask, then turn by turn. It stops once
   * six turns in a row brought nothing new (the core is idle): the input waits no longer, and a run that sent less
   * than the log is a divergence, said as one. Turns are counted, never timed.
   */
  const settle = async (target: number, input: Entry<Input>) => {
    const sent = () => recorder.outputs.length >= target;
    let idle = 0;
    while (!sent() && idle < 6) {
      const before = recorder.outputs.length;
      for (let step = 0; step < 100 && !sent(); step++) await Promise.resolve();
      if (!sent()) await new Promise<void>((resolve) => setImmediate(resolve));
      idle = recorder.outputs.length === before ? idle + 1 : 0;
    }
    if (!sent())
      throw new Error(
        `replay diverged before #${input.seq} (${input.kind}, ${input.at} ms): the core sent ${recorder.outputs.length} outputs, the log has ${target} before it`
      );
  };

  /** The input after `i` the replay has not given yet. */
  const nextAfter = (i: number) => {
    for (let j = i + 1; j < inputs.length; j++)
      if (!released.has(inputs[j]!.seq)) return inputs[j]!;
    return undefined;
  };

  for (const [i, input] of inputs.entries()) {
    if (released.has(input.seq)) continue;
    // A timer that fired with nothing else at its time: the clock stops there by itself on its way to the next input
    // (the replayed core sleeps as the recorded one did), and what the timer wakes settles before the clock moves on.
    if (input.kind === "tick") {
      const after = nextAfter(i);
      if (after && after.at > input.at) continue;
    }
    await until(input.at);
    // A database the recorded core opened while it took this input (nothing sent between): ready before the core
    // asks, so it opens as synchronously as it did.
    for (let j = i + 1; j < inputs.length; j++) {
      const next = inputs[j]!;
      if (next.at !== input.at || outputsBefore(next.seq) !== outputsBefore(input.seq))
        break;
      if (next.kind !== "db" && next.kind !== "dbFailure") continue;
      host.opened(
        next.name,
        next.kind === "db" ? next.tables : new HostError(next.message)
      );
      released.add(next.seq);
    }
    const diverged = (what: string) => {
      throw new Error(
        `replay diverged at #${input.seq} (${input.kind}, ${input.at} ms): ${what}`
      );
    };
    switch (input.kind) {
      case "connect": {
        const client = core.connect(input.surface, {
          ...(input.session === false ? { session: false } : {}),
          ...(input.host ? { host: true } : {}),
        });
        if (client !== input.client)
          diverged(`connected as ${client}, recorded ${input.client}`);
        clients.set(input.client, client);
        break;
      }
      case "ui":
        core.receive(
          clients.get(input.client) ?? input.client,
          structuredClone(input.message)
        );
        break;
      case "disconnect":
        core.disconnect(clients.get(input.client) ?? input.client);
        break;
      case "session":
        core.observeSession(structuredClone(input.snapshot));
        break;
      case "response":
      case "failure":
      case "stream": {
        // A request made after a few more turns (a fiber waiting on a semaphore or a deferred) is still this one.
        const answer = answerOf(input)!;
        let answered = host.answer(input.request, answer);
        for (let turn = 0; !answered && turn < 5; turn++) {
          await flush();
          answered = host.answer(input.request, answer);
        }
        if (!answered)
          diverged(
            `no request ${refKey(input.request)} waits for its answer (waiting: ${host.waiting().join(", ") || "none"})`
          );
        break;
      }
      case "piece":
        streams.get(input.stream)?.chunk(fromBase64(input.body));
        break;
      case "end":
        streams.get(input.stream)?.end();
        break;
      case "broken":
        streams.get(input.stream)?.fail(input.message);
        break;
      case "hint":
        host.hints.send(null, input.message);
        break;
      case "rejected":
        core.hostRejected(structuredClone(input.lease), input.status);
        break;
      case "db":
        host.opened(input.name, input.tables);
        break;
      case "dbFailure":
        host.opened(input.name, new HostError(input.message));
        break;
      case "close":
        core.close();
        break;
      case "operation": {
        const lifecycle = (core.electronSession ??
          core.webSession) as unknown as Record<
          string,
          (...args: unknown[]) => unknown
        > | null;
        const run = lifecycle?.[input.name];
        if (!run) diverged(`the core has no session lifecycle operation ${input.name}`);
        const out = run!(...structuredClone(input.args));
        // Its outcome is the core's to send (its outputs); a test that ran it read it there.
        if (Effect.isEffect(out))
          void core.runner.run(out as Effect.Effect<unknown>).catch(() => undefined);
        break;
      }
      case "meeting":
        host.meetingEvent(structuredClone(input.event));
        break;
      case "voiceCall":
        host.voiceCallEvent(structuredClone(input.event));
        break;
      case "random":
      case "legacy":
      case "legacyFailure":
      case "storage":
      case "capabilities":
      case "image":
      case "localDriveChanged":
        host.driveChanged();
        break;
      case "localDrive":
      case "downloads":
      case "stationMesh":
      case "reset":
      case "bearer":
      case "web":
      case "desktop":
      case "tick":
        // Served when asked for, or fired by the clock reaching this time.
        break;
    }
    releaseAfter(i);
    const next = nextAfter(i);
    // At the same time, the next input came as soon as the recorded core had sent what the log has before it: the
    // core goes on (microtask by microtask, then turn by turn) only until it has sent as much, so it cannot run ahead
    // of an input the recorded core took first. At a later time, it runs until it is idle.
    if (!next || next.at !== input.at) settled = await flush();
    else {
      await settle(outputsBefore(next.seq), next);
      settled = false;
    }
  }
  if (options.until !== undefined) await until(options.until);
  const unasked = host.unasked();
  if (unasked.length > 0)
    throw new Error(`replay diverged: the core never asked ${unasked.join(", ")}`);
  return { core, host, recorder, outputs: recorder.outputs };
}

/** Outputs as two runs compare them: what was sent or asked, and when; not the log's sequence numbers. */
export function comparable(outputs: Entry<Output>[]): unknown[] {
  return outputs.map(({ seq: _seq, ...output }) => output);
}
