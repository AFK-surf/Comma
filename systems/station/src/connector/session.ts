// One connection generation (a Salix WebSocket, a VM /connect socket, or a test sink). Request admission belongs to
// the connector and survives a replacement; streams, pending writes, ACK waits and the reply sink belong to this
// generation and end with it. A replaced or closed generation admits nothing new.
import { Deferred, Duration, Effect, Exit, type Fiber, Option } from "effect";
import type { Message } from "./message.ts";
import { type Closer, toWritable, type Writable } from "./io.ts";
import { LAN_TUNNEL_MAX_OPEN, LanTunnel, isTunnelFrame } from "./lan-tunnel.ts";

export const MAX_CONCURRENT_STREAM_WRITES = 4;
export const MAX_PENDING_WRITE_STREAMS = 16;
export const CONNECTION_DRAIN_TIMEOUT = Duration.seconds(5);
export const SCOPE_ABORT_NOTIFY_TIMEOUT = Duration.seconds(2);
export const READ_STREAM_ACK_TIMEOUT = Duration.seconds(60);

export class WriteStreamClosed extends Error {
  override readonly name = "WriteStreamClosed";
  constructor() {
    super("write stream is closed");
  }
}

/** A write_stream's target: the gate flips synchronously on abort; the file is closed asynchronously. */
export class PendingWrite {
  private file: Writable | null = null;
  private closedFlag = false;
  private size = 0;
  private writing: Promise<unknown> = Promise.resolve();

  setFile(file: Writable): boolean {
    if (this.closedFlag) return false;
    this.file = file;
    return true;
  }

  get closed() {
    return this.closedFlag;
  }

  currentSize() {
    return this.size;
  }

  /** Appends `data`, one write at a time; fails once the stream is closed. */
  write(data: Uint8Array): Effect.Effect<number, Error> {
    return Effect.suspend(() => {
      const file = this.file;
      if (this.closedFlag || !file) return Effect.fail(new WriteStreamClosed());
      return file.write(data).pipe(
        Effect.map(() => {
          this.size += data.length;
          return this.size;
        }),
      );
    }).pipe(this.serialized);
  }

  private serialized = <A, E>(effect: Effect.Effect<A, E>): Effect.Effect<A, E> =>
    Effect.suspend(() => {
      const previous = this.writing;
      let release!: () => void;
      this.writing = new Promise<void>((resolve) => (release = resolve));
      return Effect.promise(() => previous).pipe(Effect.andThen(effect), Effect.ensuring(Effect.sync(release)));
    });

  /** Closes the gate and hands back the file for cleanup (null when already closed). */
  abort(): Closer | null {
    if (this.closedFlag) return null;
    this.closedFlag = true;
    const file = this.file;
    this.file = null;
    return file;
  }

  /** As a cleanup item: closes the file if it is still held. */
  readonly close: Effect.Effect<void> = Effect.suspend(() => this.abort()?.close ?? Effect.void);
}

/** What a session needs from its connector. */
export type SessionHost = {
  isActive(session: Session): boolean;
  /** Takes a request admission slot; false when none is free. */
  takeRequestSlot(): boolean;
  releaseRequestSlot(): void;
  enqueueCleanup(closer: Closer): void;
  fork<A, E>(effect: Effect.Effect<A, E>): Fiber.Fiber<A, E>;
  provide<A, E>(effect: Effect.Effect<A, E>): Effect.Effect<A, E>;
  requestTimeout(msg: Message): Duration.Duration;
  /** Runs a request and returns its reply frame. */
  requestReply(session: Session, msg: Message): Effect.Effect<Message>;
  recoverable(msg: Message): boolean;
  deadlineApplies(method: string): boolean;
  bindRequestOperation(session: Session, msg: Message): { binding: "rejected" | "execute" | "rebound" | "reply"; reply?: Message };
  completeRequestOperation(id: string, method: string, reply: Message, beforeWrite: Effect.Effect<void>): Effect.Effect<void>;
  handleStream(session: Session, msg: Message): Effect.Effect<void>;
  hooks: {
    beforeRequestAdmission?: (session: Session, msg: Message) => Effect.Effect<void>;
    afterRequestFinished?: (msg: Message) => Effect.Effect<void>;
  };
};

export type SessionOptions = {
  /** Closes the transport (socket) when the session closes. */
  onClose?: (reason: unknown) => void;
  /** A reply writer that runs `beforeWrite` right before the frame becomes visible (the WebSocket writer's). */
  sendReply?: (message: Message, beforeWrite: Effect.Effect<void>) => Effect.Effect<void, unknown>;
  deadlineMs?: (msg: Message) => number;
};

export class Session {
  private closedFlag = false;
  private readonly closedSignal: Deferred.Deferred<void>;
  private readonly writes = new Map<string, PendingWrite>();
  private readonly acks = new Map<string, Deferred.Deferred<string>>();
  private streamTasks = 0;
  private streamSlots = 0;
  private readonly drained: Array<() => void> = [];
  private deadline: (msg: Message) => Duration.Duration;
  private readonly tunnels = new Map<string, LanTunnel>();

  private readonly host: SessionHost;
  private readonly sendFrame: (message: Message) => Effect.Effect<void, unknown>;
  private readonly options: SessionOptions;

  constructor(host: SessionHost, sendFrame: (message: Message) => Effect.Effect<void, unknown>, options: SessionOptions = {}) {
    this.host = host;
    this.sendFrame = sendFrame;
    this.options = options;
    this.closedSignal = Deferred.makeUnsafe<void>();
    this.deadline = options.deadlineMs ? (msg) => Duration.millis(options.deadlineMs!(msg)) : (msg) => host.requestTimeout(msg);
  }

  setDeadlineForTest(deadline: (msg: Message) => Duration.Duration) {
    this.deadline = deadline;
  }

  get closed() {
    return this.closedFlag;
  }

  /** Resolves when the session closes. */
  get whenClosed(): Effect.Effect<void> {
    return Deferred.await(this.closedSignal);
  }

  send(message: Message): Effect.Effect<void, Error> {
    return this.sendFrame(message).pipe(Effect.mapError(asError));
  }

  /** A request's reply: its admission is released immediately before the reply becomes visible. */
  sendRequestReply(message: Message, beforeWrite: Effect.Effect<void>): Effect.Effect<void, Error> {
    if (this.options.sendReply) return this.options.sendReply(message, beforeWrite).pipe(Effect.mapError(asError));
    return beforeWrite.pipe(Effect.andThen(this.send(message)));
  }

  close(reason: unknown = "connection closed") {
    if (this.closedFlag) return;
    this.closedFlag = true;
    Deferred.doneUnsafe(this.closedSignal, Exit.void);
    this.options.onClose?.(reason);
    this.abortPendingTransfers(reasonText(reason) || "connection closed");
    this.finishTunnels("connector socket closed", false);
  }

  // LAN tunnels (lan_tcp_dial): they belong to this generation and end with it.

  /** A new tunnel for request `id`; fails when the id exists or the generation holds its maximum. */
  reserveTunnel(id: string): LanTunnel {
    if (this.tunnels.has(id)) throw new Error("tunnel already exists");
    if (this.tunnels.size >= LAN_TUNNEL_MAX_OPEN) throw new Error("tunnel capacity exhausted");
    const tunnel = new LanTunnel(id, {
      send: (message) => this.send(message),
      remove: (tunnelId, t) => {
        if (this.tunnels.get(tunnelId) === t) this.tunnels.delete(tunnelId);
      },
      fork: (effect) => void this.host.fork(effect),
    });
    this.tunnels.set(id, tunnel);
    return tunnel;
  }

  removeTunnel(id: string, tunnel: LanTunnel) {
    if (this.tunnels.get(id) === tunnel) this.tunnels.delete(id);
  }

  tunnelCount() {
    return this.tunnels.size;
  }

  /** Delivers a tunnel frame in socket order; true when the frame belongs to the tunnel protocol (consumed). */
  routeTunnelFrame(msg: Message): boolean {
    if (!isTunnelFrame(msg)) return false;
    this.tunnels.get(msg.id ?? "")?.receive(msg);
    return true;
  }

  finishTunnels(reason: string, notify: boolean) {
    for (const tunnel of [...this.tunnels.values()]) this.host.fork(tunnel.finish(reason, notify));
  }

  fillTunnelQueueForTest(id: string, bytes: number) {
    this.tunnels.get(id)?.fillQueueForTest(bytes);
  }

  /** Waits for this generation's stream tasks, up to the drain timeout; false when they did not stop. */
  get wait(): Effect.Effect<boolean> {
    const drained = Effect.callback<void>((resume) => {
      if (this.streamTasks === 0) return resume(Effect.void);
      this.drained.push(() => resume(Effect.void));
    });
    return this.host.provide(drained.pipe(Effect.timeoutOption(CONNECTION_DRAIN_TIMEOUT), Effect.map((o) => o._tag === "Some")));
  }

  private admit(): boolean {
    return this.host.isActive(this) && !this.closedFlag;
  }

  private releaseOnce(): Effect.Effect<void> {
    let released = false;
    return Effect.sync(() => {
      if (released) return;
      released = true;
      this.host.releaseRequestSlot();
    });
  }

  /** Admits a request (false when this generation cannot), runs it and replies. `after` runs once it finishes. */
  startRequest(msg: Message, after?: () => void): boolean {
    if (this.host.hooks.beforeRequestAdmission) {
      // The hook may wait (tests hold admission open); admission is decided when it returns.
      this.host.fork(
        this.host.hooks.beforeRequestAdmission(this, msg).pipe(Effect.andThen(Effect.sync(() => void this.startAdmitted(msg, after)))),
      );
      return true;
    }
    return this.startAdmitted(msg, after);
  }

  private startAdmitted(msg: Message, after?: () => void): boolean {
    if (!this.host.recoverable(msg)) return this.startConnectionRequest(msg, after);
    if (!this.admit()) return false;
    const { binding, reply } = this.host.bindRequestOperation(this, msg);
    switch (binding) {
      case "execute": {
        const release = this.releaseOnce();
        this.host.fork(
          this.runRequest(msg).pipe(
            Effect.flatMap((frame) => this.host.completeRequestOperation(msg.id!, msg.method ?? "", frame, release)),
            Effect.ensuring(release),
            Effect.ensuring(Effect.sync(() => after?.())),
            Effect.ensuring(this.finished(msg)),
          ),
        );
        return true;
      }
      case "rebound":
        return true;
      case "reply": {
        const release = this.releaseOnce();
        this.host.fork(this.sendRequestReply(reply!, release).pipe(Effect.ignore, Effect.ensuring(release)));
        return true;
      }
      default:
        return false;
    }
  }

  /** A request that belongs to this connection only (streams, tunnels): not rebound across generations. */
  startConnectionRequest(msg: Message, after?: () => void): boolean {
    if (!this.admit() || !this.host.takeRequestSlot()) return false;
    const release = this.releaseOnce();
    this.host.fork(
      this.runRequest(msg).pipe(
        Effect.flatMap((frame) => this.sendRequestReply(frame, release).pipe(Effect.ignore)),
        Effect.ensuring(release),
        Effect.ensuring(Effect.sync(() => after?.())),
        Effect.ensuring(this.finished(msg)),
      ),
    );
    return true;
  }

  /** Replies without running anything (an id conflict, a refused request). */
  startRequestReply(reply: Message): boolean {
    if (!this.admit() || !this.host.takeRequestSlot()) return false;
    const release = this.releaseOnce();
    this.host.fork(this.sendRequestReply(reply, release).pipe(Effect.ignore, Effect.ensuring(release)));
    return true;
  }

  /** The request under its deadline; a timeout or defect becomes an error reply. The transport stays open. */
  private runRequest(msg: Message): Effect.Effect<Message> {
    const reply = this.host.requestReply(this, msg);
    const bounded = this.host.deadlineApplies(msg.method ?? "") ? reply.pipe(Effect.timeoutOption(this.deadline(msg))) : reply.pipe(Effect.map(Option.some));
    return this.host.provide(bounded).pipe(
      Effect.map((reply) => (reply._tag === "Some" ? reply.value : { id: msg.id, type: "error", error: `${msg.method}: connector request timed out` })),
      Effect.catchDefect((defect) => Effect.succeed<Message>({ id: msg.id, type: "error", error: `${msg.method}: connector request panic: ${String(defect)}` })),
    );
  }

  private finished(msg: Message): Effect.Effect<void> {
    return this.host.hooks.afterRequestFinished ? this.host.hooks.afterRequestFinished(msg) : Effect.void;
  }

  /** Admits a stream frame into one of this generation's stream workers. Tunnel bytes keep socket order instead. */
  startStream(msg: Message, after?: () => void): boolean {
    if (this.routeTunnelFrame(msg)) return true;
    if (!this.admit() || this.streamSlots >= MAX_CONCURRENT_STREAM_WRITES) return false;
    this.streamSlots++;
    this.streamTasks++;
    this.host.fork(
      this.host.handleStream(this, msg).pipe(
        Effect.catchDefect((defect) =>
          Effect.suspend(() => {
            this.finishPendingWrite(msg.id ?? "");
            return this.send({ id: msg.id, type: "stream", error: `connector stream panic: ${String(defect)}`, stream: { channel: "done", eof: true } }).pipe(Effect.ignore);
          }),
        ),
        Effect.ensuring(
          Effect.sync(() => {
            this.streamSlots--;
            after?.();
            this.taskDone();
          }),
        ),
      ),
    );
    return true;
  }

  streamSlotsInUse() {
    return this.streamSlots;
  }

  private taskDone() {
    this.streamTasks--;
    if (this.streamTasks === 0) for (const notify of this.drained.splice(0)) notify();
  }

  // Pending writes (write_stream).

  reservePendingWrite(id: string): PendingWrite {
    if (this.writes.has(id)) throw new Error("write_stream already exists");
    if (this.writes.size >= MAX_PENDING_WRITE_STREAMS) throw new Error("write_stream capacity exhausted");
    const pending = new PendingWrite();
    this.writes.set(id, pending);
    return pending;
  }

  activatePendingWrite(id: string, pending: PendingWrite, file: unknown): boolean {
    const writable = toWritable(file);
    if (this.writes.get(id) !== pending || !pending.setFile(writable)) {
      this.host.enqueueCleanup(writable);
      return false;
    }
    return true;
  }

  /** Reserves and activates in one step (tests and simple callers). */
  trackPendingWrite(id: string, file: unknown) {
    this.activatePendingWrite(id, this.reservePendingWrite(id), file);
  }

  pendingWrite(id: string): PendingWrite | null {
    return this.writes.get(id) ?? null;
  }

  pendingWriteCount() {
    return this.writes.size;
  }

  detachPendingWrite(id: string): PendingWrite | null {
    const pending = this.writes.get(id) ?? null;
    if (pending) this.writes.delete(id);
    return pending;
  }

  finishPendingWrite(id: string) {
    const pending = this.detachPendingWrite(id);
    if (pending) this.host.enqueueCleanup(pending);
  }

  abortPendingWrite(id: string) {
    const file = this.detachPendingWrite(id)?.abort();
    if (file) this.host.enqueueCleanup(file);
  }

  /** Drops every write authority now; reports the cancellation without waiting for user files to close. */
  abortPendingWritesForScope(reason: string) {
    const ids = [...this.writes.keys()];
    for (const pending of this.writes.values()) {
      const file = pending.abort();
      if (file) this.host.enqueueCleanup(file);
    }
    this.writes.clear();
    if (ids.length === 0) return;
    this.host.fork(
      Effect.forEach(ids, (id) => this.send({ id, type: "stream", error: reason, stream: { channel: "done", eof: true } }).pipe(Effect.ignore), { discard: true }).pipe(
        Effect.timeoutOption(SCOPE_ABORT_NOTIFY_TIMEOUT),
      ),
    );
  }

  abortPendingTransfers(reason: string) {
    for (const pending of this.writes.values()) {
      const file = pending.abort();
      if (file) this.host.enqueueCleanup(file);
    }
    this.writes.clear();
    const acks = [...this.acks.values()];
    this.acks.clear();
    for (const ack of acks) Deferred.doneUnsafe(ack, Exit.succeed(reason));
  }

  // Read stream ACKs.

  private ackKey(id: string, seq: number) {
    return `${id}:${seq}`;
  }

  /** Registers a wait for Salix's ACK of chunk `seq`; resolves with the ACK's error text ("" for success). */
  waitPendingAck(id: string, seq: number): Effect.Effect<string> {
    const key = this.ackKey(id, seq);
    const ack = Deferred.makeUnsafe<string>();
    this.acks.set(key, ack);
    return Deferred.await(ack).pipe(Effect.onInterrupt(() => Effect.sync(() => this.acks.get(key) === ack && this.acks.delete(key))));
  }

  pendingAckCount() {
    return this.acks.size;
  }

  /** Sends a read stream chunk and waits for its ACK (bounded); an ACK with an error fails the stream. */
  sendReadStreamFrame(id: string, seq: number, frame: Message): Effect.Effect<void, Error> {
    const key = this.ackKey(id, seq);
    const self = this;
    const run = Effect.gen(function* () {
      const ack = Deferred.makeUnsafe<string>();
      self.acks.set(key, ack);
      const forget = Effect.sync(() => self.acks.get(key) === ack && self.acks.delete(key));
      yield* self.send(frame).pipe(Effect.tapError(() => forget));
      const outcome = yield* Deferred.await(ack).pipe(Effect.timeoutOption(READ_STREAM_ACK_TIMEOUT), Effect.onInterrupt(() => forget));
      if (outcome._tag === "None") {
        yield* forget;
        return yield* Effect.fail(new Error("read_stream ack timeout"));
      }
      if (outcome.value !== "") return yield* Effect.fail(new Error(outcome.value));
    });
    return this.host.provide(run);
  }

  completePendingAck(id: string, seq: number, error: string) {
    const key = this.ackKey(id, seq);
    const ack = this.acks.get(key);
    if (!ack) return;
    this.acks.delete(key);
    Deferred.doneUnsafe(ack, Exit.succeed(error));
  }

  /** Handles a stream frame for this session (write_stream data or an ACK). */
  handleStream(msg: Message): Effect.Effect<void> {
    return this.host.handleStream(this, msg);
  }
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

export function reasonText(reason: unknown): string {
  if (reason === null || reason === undefined) return "";
  if (reason instanceof Error) return reason.message;
  return String(reason);
}
