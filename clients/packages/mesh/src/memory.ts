// Endpoints in memory, for tests: connections and streams behave as QUIC's do (ordered bytes per stream, finish,
// reset, stop, close with a code), with nothing timed. A test can cut a connection as a network would (`cut`), and give
// streams a window (`window`) as flow control would: a write then waits until the reader has taken what is over it.
import type {
  BiStream,
  CloseInfo,
  MeshConnection,
  MeshEndpoint,
  MeshVia,
  PeerAddr,
  RecvHalf,
  SendHalf,
  ViaChange,
} from "./link.ts";

class StreamError extends Error {}

/** One direction of a stream. */
class Pipe {
  readonly #window: number;
  #held = 0;
  #drained: (() => void)[] = [];
  #chunks: Uint8Array[] = [];
  #finished = false;
  /** Why reading fails: the writer reset it, or the connection went. */
  #failed: string | null = null;
  /** Why writing fails: the reader stopped it, or the connection went. */
  #stopped: string | null = null;
  #waiting: (() => void) | null = null;
  #frozen = false;
  #holding = false;
  /** The reader read its end. */
  #ended = false;
  readonly #stops: boolean;

  constructor(window = Infinity, stops = true) {
    this.#window = window;
    this.#stops = stops;
  }

  /** Whether the reader is done with it (read its end, stopped it, or it failed): QUIC then counts the stream gone. */
  get done(): boolean {
    return this.#ended || this.#failed !== null;
  }

  #drain() {
    for (const drained of this.#drained.splice(0)) drained();
  }

  #wake() {
    const waiting = this.#waiting;
    this.#waiting = null;
    waiting?.();
  }

  readonly send: SendHalf = {
    write: async (bytes) => {
      if (this.#stopped) throw new StreamError(this.#stopped);
      if (this.#finished || this.#failed)
        throw new StreamError("written after its end");
      if (this.#frozen) return;
      this.#chunks.push(bytes.slice());
      this.#held += bytes.length;
      this.#wake();
      while (this.#held > this.#window && !this.#stopped && !this.#failed)
        await new Promise<void>((resolve) => this.#drained.push(resolve));
      if (this.#stopped) throw new StreamError(this.#stopped);
    },
    finish: async () => {
      if (this.#stopped) throw new StreamError(this.#stopped);
      if (this.#frozen) return;
      this.#finished = true;
      this.#wake();
    },
    reset: (code) => {
      if (this.#finished && this.#chunks.length === 0) return;
      this.#failed ??= `reset ${code}`;
      this.#chunks = [];
      this.#wake();
      this.#drain();
    },
  };

  readonly recv: RecvHalf = {
    read: async (max) => {
      for (;;) {
        if (this.#failed) throw new StreamError(this.#failed);
        if (this.#holding) {
          await new Promise<void>((resolve) => (this.#waiting = resolve));
          continue;
        }
        const first = this.#chunks[0];
        if (first) {
          const taken = first.length <= max ? first : first.subarray(0, max);
          if (first.length <= max) this.#chunks.shift();
          else this.#chunks[0] = first.subarray(max);
          this.#held -= taken.length;
          this.#drain();
          return taken;
        }
        if (this.#finished) {
          this.#ended = true;
          return null;
        }
        await new Promise<void>((resolve) => (this.#waiting = resolve));
      }
    },
    stop: (code) => {
      if (!this.#stops) return;
      this.#stopped ??= `stopped ${code}`;
      // Reading on after stopping fails, as QUIC's does.
      this.#failed ??= `stopped ${code}`;
      this.#chunks = [];
      this.#wake();
      this.#drain();
    },
  };

  /** Nothing written reaches the reader while `on` (the network paused); it all arrives once it is off. */
  hold(on: boolean) {
    this.#holding = on;
    if (!on) this.#wake();
  }

  /** The other end is gone without a word: what is written goes nowhere, and nothing more arrives. */
  freeze() {
    this.#frozen = true;
    this.#chunks = [];
    this.#held = 0;
    this.#drain();
  }

  /** The connection went: both ends fail. */
  break(reason: string) {
    if (!this.#finished || this.#chunks.length > 0) this.#failed ??= reason;
    this.#stopped ??= reason;
    this.#wake();
    this.#drain();
  }
}

class Queue<T> {
  #items: T[] = [];
  #waiting: ((item: T | null) => void)[] = [];
  #ended = false;
  push(item: T) {
    if (this.#ended) return;
    const waiting = this.#waiting.shift();
    if (waiting) waiting(item);
    else this.#items.push(item);
  }
  next(): Promise<T | null> {
    if (this.#items.length > 0) return Promise.resolve(this.#items.shift()!);
    if (this.#ended) return Promise.resolve(null);
    return new Promise((resolve) => this.#waiting.push(resolve));
  }
  end() {
    this.#ended = true;
    for (const waiting of this.#waiting.splice(0)) waiting(null);
  }
}

class Side implements MeshConnection {
  peer!: Side;
  readonly incoming = new Queue<BiStream>();
  readonly pipes: Pipe[] = [];
  #closed: CloseInfo | null = null;
  readonly #onClosed: ((info: CloseInfo) => void)[] = [];
  #via: MeshVia = "direct";
  #onVia: (() => void)[] = [];

  /** What comes back on each stream this side opened. */
  readonly answers: Pipe[] = [];
  readonly remoteId: string;
  readonly #window: number;
  readonly #stops: boolean;

  constructor(remoteId: string, window: number, stops = true) {
    this.remoteId = remoteId;
    this.#window = window;
    this.#stops = stops;
  }

  async nextVia(last: MeshVia | null): Promise<ViaChange> {
    while (!this.#closed && this.#via === last)
      await new Promise<void>((wake) => this.#onVia.push(wake));
    return this.#closed
      ? { via: null, closed: true }
      : { via: this.#via, closed: false };
  }

  /** It runs another way now (both sides). */
  route(via: MeshVia): void {
    for (const side of [this, this.peer]) {
      side.#via = via;
      for (const wake of side.#onVia.splice(0)) wake();
    }
  }

  async openBi(): Promise<BiStream> {
    // (the peer lets no more streams be open: one waits until it does, or the connection goes)
    while (this.#streamsHeld && !this.#closed)
      await new Promise<void>((wake) => this.#onStreams.push(wake));
    if (this.#closed)
      throw new StreamError(`connection closed: ${this.#closed.reason}`);
    const out = new Pipe(this.#window, this.peer.#stops);
    const back = new Pipe(this.#window, this.#stops);
    this.pipes.push(out, back);
    this.answers.push(back);
    if (this.#silent) {
      out.freeze();
      back.freeze();
    } else this.peer.incoming.push({ send: back.send, recv: out.recv });
    if (this.#paused) {
      out.hold(true);
      back.hold(true);
    }
    return { send: out.send, recv: back.recv };
  }

  #silent = false;
  #paused = false;
  #streamsHeld = false;
  #onStreams: (() => void)[] = [];

  /** No new stream opens on it while `on` (the peer lets no more be open), as QUIC's when its credit is used up. */
  holdStreams(on: boolean): void {
    this.#streamsHeld = on;
    if (!on) for (const wake of this.#onStreams.splice(0)) wake();
  }

  /** The network between it and its peer pauses (`on`) or comes back: what is sent waits, then arrives. */
  pause(on: boolean): void {
    for (const side of [this, this.peer]) {
      side.#paused = on;
      for (const pipe of side.pipes) pipe.hold(on);
    }
  }

  /** Its peer is gone without a word (its process killed): the connection stays open here, and nothing crosses it. */
  silence(): void {
    this.#silent = true;
    for (const pipe of this.pipes) pipe.freeze();
  }

  acceptBi(): Promise<BiStream | null> {
    return this.incoming.next();
  }

  closed(): Promise<CloseInfo> {
    if (this.#closed) return Promise.resolve(this.#closed);
    return new Promise((resolve) => this.#onClosed.push(resolve));
  }

  close(code: number, reason: string): void {
    this.#end({ code, reason });
  }

  /** The connection is lost (no close code), as when the network goes. */
  lose(reason: string): void {
    this.#end({ code: null, reason });
  }

  #end(info: CloseInfo) {
    if (this.#closed) return;
    this.#closed = info;
    this.incoming.end();
    for (const pipe of this.pipes) pipe.break(`connection closed: ${info.reason}`);
    for (const resolve of this.#onClosed.splice(0)) resolve(info);
    for (const wake of this.#onStreams.splice(0)) wake();
    for (const wake of this.#onVia.splice(0)) wake();
    this.peer.#end(info);
  }
}

/** A network of endpoints in memory. */
export class MemoryMesh {
  readonly #endpoints = new Map<string, MemoryEndpoint>();
  readonly #connections: Side[] = [];
  /** Every address dialed, in order, as the dialer gave it (reached or not). */
  readonly dials: PeerAddr[] = [];
  /** What a stream holds that its reader has not taken before a write waits, in bytes. None: writes never wait. */
  window = Infinity;
  /**
   * Whether a dial to an endpoint not there waits on for good instead of failing at once: its first packet lost, as a
   * QUIC dial's is to a peer not yet back, and sent again only after a while (one that waits so is still counted).
   */
  unansweredDialsWait = false;
  /**
   * Whether a reader's `stop` does nothing, as the phones' and the desktop's binding's (native-link.ts): what the peer
   * still sends is left unread, and the stream lasts until it is read to its end.
   */
  stopsNothing = false;

  /** An endpoint with id `id` that serves `alpns` (none: it only connects). */
  endpoint(id: string, alpns: readonly string[] = []): MemoryEndpoint {
    const endpoint = new MemoryEndpoint(id, alpns, this);
    this.#endpoints.set(id, endpoint);
    return endpoint;
  }

  /** @internal */
  dial(from: string, peer: PeerAddr, alpn: string): Side {
    this.dials.push(peer);
    const target = this.#endpoints.get(peer.id);
    if (
      !target ||
      target.isClosed ||
      this.#paused.has(peer.id) ||
      !target.alpns.includes(alpn)
    )
      throw new Error(`no endpoint ${peer.id} serves ${alpn}`);
    const mine = new Side(peer.id, this.window, !this.stopsNothing);
    const theirs = new Side(from, this.window, !this.stopsNothing);
    mine.peer = theirs;
    theirs.peer = mine;
    this.#connections.push(mine);
    target.incoming.push(theirs);
    return mine;
  }

  /** Every open connection goes, or each to the endpoint `to`, as when the network does (no close code). */
  cut(to?: string): void {
    const lost = this.#connections.filter(
      (side) => to === undefined || side.remoteId === to
    );
    for (const side of lost) {
      this.#connections.splice(this.#connections.indexOf(side), 1);
      side.lose("network lost");
    }
  }

  /**
   * The endpoint `id` is gone at once, as a process killed: its connections stay open at their other ends, carrying
   * nothing, until those give them up; it cannot be dialed until an endpoint with its id is made again.
   */
  crash(id: string): void {
    const endpoint = this.#endpoints.get(id);
    if (endpoint) {
      endpoint.isClosed = true;
      this.#endpoints.delete(id);
    }
    for (const side of this.#connections) if (side.remoteId === id) side.silence();
  }

  /**
   * The network to the endpoint `id` pauses (`on`) or comes back: while it is paused nothing crosses its connections
   * (it arrives once it comes back) and it cannot be dialed.
   */
  pause(id: string, on: boolean): void {
    if (on) this.#paused.add(id);
    else this.#paused.delete(id);
    for (const side of this.#connections) if (side.remoteId === id) side.pause(on);
  }

  readonly #paused = new Set<string>();

  /** No new stream opens on the connections to the endpoint `to` while `on` (it lets no more be open). */
  holdStreams(to: string, on: boolean): void {
    for (const side of this.#connections)
      if (side.remoteId === to) side.holdStreams(on);
  }

  /** Every open connection to the endpoint `to` runs `via` now, as when iroh moves it to another path. */
  route(to: string, via: MeshVia): void {
    for (const side of this.#connections) if (side.remoteId === to) side.route(via);
  }

  /** The streams opened to the endpoint `to` whose answer its opener has not done with yet (`Pipe.done`). */
  unfinished(to: string): number {
    return this.#connections
      .filter((side) => side.remoteId === to)
      .reduce((n, side) => n + side.answers.filter((pipe) => !pipe.done).length, 0);
  }

  /** How many connections were opened so far. */
  get dialed(): number {
    return this.#connections.length;
  }
}

export class MemoryEndpoint implements MeshEndpoint {
  readonly incoming = new Queue<MeshConnection>();
  isClosed = false;
  readonly id: string;
  readonly alpns: readonly string[];
  readonly mesh: MemoryMesh;

  constructor(id: string, alpns: readonly string[], mesh: MemoryMesh) {
    this.id = id;
    this.alpns = alpns;
    this.mesh = mesh;
  }

  async connect(peer: PeerAddr, alpn: string): Promise<MeshConnection> {
    if (this.isClosed) throw new Error("endpoint closed");
    try {
      return this.mesh.dial(this.id, peer, alpn);
    } catch (error) {
      if (this.mesh.unansweredDialsWait) return new Promise<never>(() => undefined);
      throw error;
    }
  }

  accept(): Promise<MeshConnection | null> {
    return this.incoming.next();
  }

  async close(): Promise<void> {
    this.isClosed = true;
    this.incoming.end();
  }
}
