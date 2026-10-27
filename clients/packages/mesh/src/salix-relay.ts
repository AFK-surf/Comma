// Salix as the relay of last resort, on a client's side (a station's is systems/station/src/mesh/salix-relay.ts): the
// endpoint bound with `salixRelay` hands its packets for Salix here, and sockets to Comma's client relay
// (`GET /v1/comma/station-relay`, one for each Workspace, each in its Group) carry them. Salix passes a packet only to
// a peer in the Group of the socket it came on, so a peer's packets go on the socket that peer was last heard on;
// until it is heard, on every socket. While no socket carries them, they are dropped, as any lost path's are: QUIC
// sends them again, and iroh tries its other paths. Nothing here is Node's: the desktop's endpoint (station-native.ts)
// and the browser's (web.ts) each give it theirs and how to sign with its key.

/** The part of an endpoint bound with `salixRelay` the relay works: its id, and its packets both ways. */
export interface RelayEndpoint {
  id(): string;
  relayIncoming(from: string, data: Uint8Array): void;
  relayOutgoing(max: number): Promise<Array<{ to: string; data: Uint8Array }>>;
}

/** Signs `message` with the endpoint's key (Ed25519): the proof Salix asks each socket for. */
export type RelaySigner = (message: Uint8Array) => Uint8Array | Promise<Uint8Array>;

/** A binary frame's kind: a packet, after the peer's endpoint id (32 bytes). */
const FRAME = 1;
const BATCH = 64;
/** Peers whose socket is remembered: the oldest is forgotten beyond this (its packets go on every socket again). */
const MAX_ROUTES = 4096;
/** Salix closes a socket silent for three minutes. */
const PING_MS = 60_000;
/** A socket not registered by then is given up. */
const REGISTER_MS = 30_000;

const hex = (bytes: Uint8Array) =>
  Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
const fromHex = (text: string) =>
  Uint8Array.from(text.match(/../g) ?? [], (pair) => Number.parseInt(pair, 16));
const base64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));

/** The part of a WebSocket the relay uses. */
export interface RelaySocket {
  send(data: string | Uint8Array<ArrayBuffer>): void;
  close(code?: number, reason?: string): void;
}

/** Opens a socket at `url`: what it receives (text or binary) goes to `message`, and `closed` is told once it closed. */
export type OpenRelaySocket = (
  url: string,
  on: { message(data: string | Uint8Array): void; closed(): void }
) => RelaySocket;

const openWebSocket: OpenRelaySocket = (url, on) => {
  const socket = new WebSocket(url);
  socket.binaryType = "arraybuffer";
  socket.addEventListener("message", (event: MessageEvent) =>
    on.message(
      typeof event.data === "string"
        ? event.data
        : new Uint8Array(event.data as ArrayBuffer)
    )
  );
  socket.addEventListener("close", () => on.closed());
  return {
    send: (data) => socket.send(data),
    close: (code, reason) => socket.close(code, reason),
  };
};

/** A socket that carries packets: it sends one to a peer. */
type Carrier = (to: string, data: Uint8Array) => void;

/** One socket being carried: it ends when the socket closed, and `close` closes it. */
export interface RelayCarry {
  closed: Promise<void>;
  close(): void;
}

export class SalixRelay {
  readonly #endpoint: RelayEndpoint;
  readonly #sign: RelaySigner;
  readonly #open: OpenRelaySocket;
  readonly #carriers = new Set<Carrier>();
  /** The socket each peer was last heard on. */
  readonly #heard = new Map<string, Carrier>();

  /** Carries what `endpoint` (bound with `salixRelay`) sends through Salix until it closes; `sign` signs with its key. */
  constructor(endpoint: RelayEndpoint, sign: RelaySigner, open = openWebSocket) {
    this.#endpoint = endpoint;
    this.#sign = sign;
    this.#open = open;
    void this.#pump();
  }

  /**
   * Opens a socket at `url` with `ticket` (`<id>.<secret>`, single-use) and proves the endpoint's id on it: it
   * resolves once Salix registered it, and fails if the socket closed before (or `signal` gave it up).
   */
  carry(url: string, ticket: string, signal?: AbortSignal): Promise<RelayCarry> {
    const ticketId = ticket.split(".", 1)[0]!;
    return new Promise((resolve, reject) => {
      let registered = false;
      let ended!: () => void;
      const closed = new Promise<void>((done) => (ended = done));
      let ping: ReturnType<typeof setInterval> | undefined;
      let socket: RelaySocket | undefined;
      const abandon = () => socket?.close(1000, "not registered");
      const giveUp = setTimeout(abandon, REGISTER_MS);
      signal?.addEventListener("abort", abandon);
      const settled = () => {
        clearTimeout(giveUp);
        signal?.removeEventListener("abort", abandon);
      };
      const carrier: Carrier = (to, data) => socket?.send(frame(to, data));
      const register = async (challenge: string) => {
        const proof = await this.#sign(
          new TextEncoder().encode(`comma-salix-relay-v1:${ticketId}:${challenge}`)
        );
        socket?.send(
          JSON.stringify({
            type: "register",
            endpoint_id: this.#endpoint.id(),
            signature: base64(proof),
          })
        );
      };
      socket = this.#open(`${url}?ticket=${encodeURIComponent(ticket)}`, {
        message: (data) => {
          if (typeof data !== "string") {
            if (registered) this.#incoming(data, carrier);
            return;
          }
          if (registered) return;
          const said = parse(data);
          if (said?.type === "challenge" && typeof said.challenge === "string") {
            void register(said.challenge).catch(abandon);
          } else if (said?.type === "registered") {
            registered = true;
            settled();
            this.#carriers.add(carrier);
            ping = setInterval(() => socket?.send("ping"), PING_MS);
            resolve({ closed, close: () => socket?.close(1000, "done") });
          }
        },
        closed: () => {
          settled();
          clearInterval(ping);
          this.#carriers.delete(carrier);
          for (const [peer, on] of this.#heard)
            if (on === carrier) this.#heard.delete(peer);
          ended();
          if (!registered)
            reject(new Error("the Salix relay closed before it registered"));
        },
      });
      if (signal?.aborted) abandon();
    });
  }

  #incoming(data: Uint8Array, via: Carrier): void {
    if (data.length < 33 || data[0] !== FRAME) return;
    const from = hex(data.subarray(1, 33));
    this.#heard.delete(from);
    this.#heard.set(from, via);
    if (this.#heard.size > MAX_ROUTES)
      this.#heard.delete(this.#heard.keys().next().value!);
    try {
      this.#endpoint.relayIncoming(from, data.slice(33));
    } catch {
      // The endpoint closed.
    }
  }

  #send(to: string, data: Uint8Array): void {
    if (!/^[0-9a-f]{64}$/.test(to)) return;
    const via = this.#heard.get(to);
    if (via && this.#carriers.has(via)) via(to, data);
    else for (const each of this.#carriers) each(to, data);
  }

  async #pump(): Promise<void> {
    try {
      for (;;) {
        const packets = await this.#endpoint.relayOutgoing(BATCH);
        if (packets.length === 0) return;
        for (const packet of packets) this.#send(packet.to, packet.data);
      }
    } catch {
      // The endpoint closed.
    }
  }
}

function frame(to: string, data: Uint8Array): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(33 + data.length);
  out[0] = FRAME;
  out.set(fromHex(to), 1);
  out.set(data, 33);
  return out;
}

function parse(text: string): { type?: unknown; challenge?: unknown } | null {
  try {
    const value: unknown = JSON.parse(text);
    return typeof value === "object" && value !== null ? value : null;
  } catch {
    return null;
  }
}
