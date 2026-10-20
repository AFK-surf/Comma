// The mesh addon's endpoints (src/mesh/native.ts) connected in memory, for tests of what goes over the mesh rather than
// of the mesh: a connection is a pair of ends, a stream a pair of ordered byte queues, nothing lost and nothing waiting
// on real time (QUIC on 127.0.0.1 can lose a connection on a loaded machine). An endpoint's id is its key's public half,
// as iroh's is; connecting finds the endpoint by id, as an address on this machine would.
import { createPrivateKey, createPublicKey } from "node:crypto";
import type { Addr, Connection, Endpoint, Mesh, Reach, Stream } from "../src/mesh/native.ts";

/// The ed25519 public key of a 32-byte secret, hex: iroh's endpoint id.
function idOf(secret: Buffer): string {
  const der = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), secret]);
  const raw = createPublicKey(createPrivateKey({ key: der, format: "der", type: "pkcs8" })).export({ format: "der", type: "spki" });
  return raw.subarray(-32).toString("hex");
}

/// One end of a stream: what it writes, its `peer` reads.
class End implements Stream {
  peer!: End;
  #queue: (Buffer | null)[] = [];
  #error: Error | null = null;
  #waiting: (() => void) | null = null;
  #stopped: Promise<void>;
  #stop!: () => void;
  constructor() {
    this.#stopped = new Promise((r) => (this.#stop = r));
  }
  #wake() {
    const w = this.#waiting;
    this.#waiting = null;
    w?.();
  }
  push(b: Buffer | null) {
    this.#queue.push(b);
    this.#wake();
  }
  fail(e: Error) {
    this.#error ??= e;
    this.#wake();
    this.#stop();
  }
  async read(): Promise<Buffer | null> {
    for (;;) {
      if (this.#queue.length > 0) {
        const b = this.#queue.shift()!;
        // Its end read: the other side's finish is acknowledged.
        if (b === null) this.peer.#stop();
        return b;
      }
      if (this.#error) throw this.#error;
      await new Promise<void>((r) => (this.#waiting = r));
    }
  }
  async write(bytes: Buffer): Promise<void> {
    if (this.#error) throw this.#error;
    this.peer.push(Buffer.from(bytes));
  }
  async finish(): Promise<void> {
    this.peer.push(null);
  }
  stopped(): Promise<void> {
    return this.#stopped;
  }
  async reset(code: number): Promise<void> {
    this.#stop();
    this.peer.fail(new Error(`stream reset (${code})`));
  }
}

class Conn implements Connection {
  peer!: Conn;
  #incoming: End[] = [];
  #accepting: ((s: End | null) => void) | null = null;
  #ends: End[] = [];
  #reason: string | null = null;
  #closed: Promise<string>;
  #resolve!: (r: string) => void;
  readonly #remote: string;
  readonly #alpn: Buffer;
  constructor(remote: string, alpn: Buffer) {
    this.#remote = remote;
    this.#alpn = alpn;
    this.#closed = new Promise((r) => (this.#resolve = r));
  }
  remoteId(): string {
    return this.#remote;
  }
  alpn(): Buffer {
    return this.#alpn;
  }
  via(): string | null {
    return null;
  }
  #offer(s: End) {
    const take = this.#accepting;
    this.#accepting = null;
    if (take) take(s);
    else this.#incoming.push(s);
  }
  async acceptBi(): Promise<Stream | null> {
    if (this.#incoming.length > 0) return this.#incoming.shift()!;
    if (this.#reason !== null) return null;
    return new Promise((r) => (this.#accepting = r));
  }
  async openBi(): Promise<Stream> {
    if (this.#reason !== null) throw new Error("connection lost");
    const [mine, theirs] = [new End(), new End()];
    mine.peer = theirs;
    theirs.peer = mine;
    this.#ends.push(mine);
    this.peer.#ends.push(theirs);
    this.peer.#offer(theirs);
    return mine;
  }
  gone(reason: string) {
    if (this.#reason !== null) return;
    this.#reason = reason;
    for (const e of this.#ends) e.fail(new Error("connection lost"));
    const take = this.#accepting;
    this.#accepting = null;
    take?.(null);
    this.#resolve(reason);
  }
  close(_code: number, reason: string): void {
    this.gone(reason);
    this.peer.gone(reason);
  }
  isClosed(): boolean {
    return this.#reason !== null;
  }
  closed(): Promise<string> {
    return this.#closed;
  }
}

class MemoryEndpoint implements Endpoint {
  readonly #net: Map<string, MemoryEndpoint>;
  readonly #dials: Addr[];
  readonly #id: string;
  readonly #alpns: Buffer[];
  readonly #port: number;
  #incoming: Conn[] = [];
  #accepting: ((c: Conn | null) => void) | null = null;
  #conns: Conn[] = [];
  #closed = false;
  #whenClosed: (() => void)[] = [];
  constructor(net: Map<string, MemoryEndpoint>, secret: Buffer, alpns: Buffer[], port: number, dials: Addr[]) {
    this.#net = net;
    this.#dials = dials;
    this.#id = idOf(secret);
    this.#alpns = alpns;
    this.#port = port;
  }
  id(): string {
    return this.#id;
  }
  sockets(): string[] {
    return [`127.0.0.1:${this.#port}`];
  }
  async online(): Promise<void> {}
  home(): string | null {
    return null;
  }
  /// No relay, its one socket; it never moves.
  async reach(last: Reach | null): Promise<Reach | null> {
    const now = { homeRelay: null, addrs: this.sockets() };
    if (this.#closed) return null;
    if (JSON.stringify(now) !== JSON.stringify(last)) return now;
    await new Promise<void>((r) => this.#whenClosed.push(r));
    return null;
  }
  async insertRelay(_url: string): Promise<void> {}
  async removeRelay(_url: string): Promise<void> {}
  async publicRelays(_on: boolean): Promise<void> {}
  keep(_urls: string[]): void {}
  #arrive(c: Conn) {
    this.#conns.push(c);
    const take = this.#accepting;
    this.#accepting = null;
    if (take) take(c);
    else this.#incoming.push(c);
  }
  async accept(): Promise<Connection | null> {
    if (this.#incoming.length > 0) return this.#incoming.shift()!;
    if (this.#closed) return null;
    return new Promise((r) => (this.#accepting = r));
  }
  async connect(addr: Addr, alpn: Buffer): Promise<Connection> {
    this.#dials.push(addr);
    const there = this.#net.get(addr.id);
    if (!there || there.#closed || this.#closed) throw new Error(`no endpoint ${addr.id} here`);
    if (!there.#alpns.some((a) => a.equals(alpn))) throw new Error("peer doesn't support any known protocol");
    const [mine, theirs] = [new Conn(addr.id, alpn), new Conn(this.#id, alpn)];
    mine.peer = theirs;
    theirs.peer = mine;
    this.#conns.push(mine);
    there.#arrive(theirs);
    return mine;
  }
  async close(): Promise<void> {
    if (this.#closed) return;
    this.#closed = true;
    this.#net.delete(this.#id);
    for (const r of this.#whenClosed.splice(0)) r();
    for (const c of this.#conns) c.close(0, "endpoint closed");
    const take = this.#accepting;
    this.#accepting = null;
    take?.(null);
  }
}

/// A mesh of its own: endpoints bound on it reach each other, and only each other. `dials`: every address its endpoints
/// were asked to connect to, in order (reached or not).
export function memoryMesh(): Pick<Mesh, "bind"> & { dials: Addr[] } {
  const net = new Map<string, MemoryEndpoint>();
  const dials: Addr[] = [];
  let port = 40000;
  return {
    dials,
    bind: async (o) => {
      const e = new MemoryEndpoint(net, o.secretKey, o.alpns, ++port, dials);
      net.set(e.id(), e);
      return e;
    },
  };
}
