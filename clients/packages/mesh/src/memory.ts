// Endpoints in memory, for tests: connections and streams behave as QUIC's do (ordered bytes per stream, finish,
// reset, stop, close with a code), with nothing timed. A test can cut a connection as a network would (`cut`).
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
  #chunks: Uint8Array[] = [];
  #finished = false;
  /** Why reading fails: the writer reset it, or the connection went. */
  #failed: string | null = null;
  /** Why writing fails: the reader stopped it, or the connection went. */
  #stopped: string | null = null;
  #waiting: (() => void) | null = null;

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
      this.#chunks.push(bytes.slice());
      this.#wake();
    },
    finish: async () => {
      if (this.#stopped) throw new StreamError(this.#stopped);
      this.#finished = true;
      this.#wake();
    },
    reset: (code) => {
      if (this.#finished && this.#chunks.length === 0) return;
      this.#failed ??= `reset ${code}`;
      this.#chunks = [];
      this.#wake();
    },
  };

  readonly recv: RecvHalf = {
    read: async (max) => {
      for (;;) {
        if (this.#failed) throw new StreamError(this.#failed);
        const first = this.#chunks[0];
        if (first) {
          if (first.length <= max) {
            this.#chunks.shift();
            return first;
          }
          this.#chunks[0] = first.subarray(max);
          return first.subarray(0, max);
        }
        if (this.#finished) return null;
        await new Promise<void>((resolve) => (this.#waiting = resolve));
      }
    },
    stop: (code) => {
      this.#stopped ??= `stopped ${code}`;
      // Reading on after stopping fails, as QUIC's does.
      this.#failed ??= `stopped ${code}`;
      this.#chunks = [];
      this.#wake();
    },
  };

  /** The connection went: both ends fail. */
  break(reason: string) {
    if (!this.#finished || this.#chunks.length > 0) this.#failed ??= reason;
    this.#stopped ??= reason;
    this.#wake();
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

  constructor(readonly remoteId: string) {}

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
    if (this.#closed)
      throw new StreamError(`connection closed: ${this.#closed.reason}`);
    const out = new Pipe();
    const back = new Pipe();
    this.pipes.push(out, back);
    this.peer.incoming.push({ send: back.send, recv: out.recv });
    return { send: out.send, recv: back.recv };
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
    if (!target || target.isClosed || !target.alpns.includes(alpn))
      throw new Error(`no endpoint ${peer.id} serves ${alpn}`);
    const mine = new Side(peer.id);
    const theirs = new Side(from);
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

  /** Every open connection to the endpoint `to` runs `via` now, as when iroh moves it to another path. */
  route(to: string, via: MeshVia): void {
    for (const side of this.#connections) if (side.remoteId === to) side.route(via);
  }

  /** How many connections were opened so far. */
  get dialed(): number {
    return this.#connections.length;
  }
}

export class MemoryEndpoint implements MeshEndpoint {
  readonly incoming = new Queue<MeshConnection>();
  isClosed = false;

  constructor(
    readonly id: string,
    readonly alpns: readonly string[],
    readonly mesh: MemoryMesh
  ) {}

  async connect(peer: PeerAddr, alpn: string): Promise<MeshConnection> {
    if (this.isClosed) throw new Error("endpoint closed");
    return this.mesh.dial(this.id, peer, alpn);
  }

  accept(): Promise<MeshConnection | null> {
    return this.incoming.next();
  }

  async close(): Promise<void> {
    this.isClosed = true;
    this.incoming.end();
  }
}
