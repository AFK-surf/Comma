import { createPrivateKey, createPublicKey, sign, verify } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  SalixRelay,
  type OpenRelaySocket,
  type RelayEndpoint,
} from "../src/salix-relay.ts";

const SEED = Buffer.alloc(32, 7);
const PKCS8_ED25519 = Buffer.from("302e020100300506032b657004220420", "hex");
const PRIVATE = createPrivateKey({
  key: Buffer.concat([PKCS8_ED25519, SEED]),
  format: "der",
  type: "pkcs8",
});
const PUBLIC = createPublicKey(PRIVATE);
const SIGN = (message: Uint8Array) => new Uint8Array(sign(null, message, PRIVATE));
const ID = Buffer.from(PUBLIC.export({ format: "jwk" }).x!, "base64url").toString(
  "hex"
);
const PEER = "ab".repeat(32);
const URL = "wss://api.example.test/v1/comma/station-relay";

/** An endpoint bound with `salixRelay`: the test hands over what it sends, and sees what came for it. */
function endpoint() {
  const queue: { to: string; data: Buffer }[][] = [];
  let wake: (() => void) | null = null;
  const incoming: [string, string][] = [];
  const native = {
    id: () => ID,
    relayIncoming: (from: string, data: Uint8Array) =>
      void incoming.push([from, Buffer.from(data).toString()]),
    relayOutgoing: async () => {
      while (queue.length === 0) await new Promise<void>((done) => (wake = done));
      return queue.shift()!;
    },
  } as RelayEndpoint;
  const push = (packets: { to: string; data: Buffer }[]) => {
    queue.push(packets);
    wake?.();
    wake = null;
  };
  return {
    native,
    incoming,
    send: (to: string, text: string) => push([{ to, data: Buffer.from(text) }]),
    close: () => push([]),
  };
}

type Socket = {
  url: string;
  sent: (string | Uint8Array)[];
  on: Parameters<OpenRelaySocket>[1];
  closed: boolean;
  /** What it sends next. */
  next(): Promise<string | Uint8Array>;
};

/** Sockets the relay opens, each driven by the test as Comma would. */
function sockets() {
  const opened: Socket[] = [];
  const open: OpenRelaySocket = (url, on) => {
    let waiting: ((sent: string | Uint8Array) => void) | null = null;
    const socket: Socket = {
      url,
      sent: [],
      on,
      closed: false,
      next: () => new Promise((done) => (waiting = done)),
    };
    opened.push(socket);
    return {
      send: (data) => {
        socket.sent.push(data);
        waiting?.(data);
        waiting = null;
      },
      close: () => {
        if (socket.closed) return;
        socket.closed = true;
        on.closed();
      },
    };
  };
  return { opened, open };
}

const frame = (peer: string, text: string) =>
  new Uint8Array(
    Buffer.concat([Buffer.from([1]), Buffer.from(peer, "hex"), Buffer.from(text)])
  );

/** Answers the socket's challenge and registration as Comma does; what it signed in the register frame. */
async function register(socket: Socket, ticketId: string, challenge: string) {
  const said = socket.next();
  socket.on.message(JSON.stringify({ type: "challenge", challenge }));
  const sent = JSON.parse((await said) as string) as {
    type: string;
    endpoint_id: string;
    signature: string;
  };
  socket.on.message(JSON.stringify({ type: "registered" }));
  return {
    sent,
    proves: verify(
      null,
      Buffer.from(`comma-salix-relay-v1:${ticketId}:${challenge}`),
      PUBLIC,
      Buffer.from(sent.signature, "base64")
    ),
  };
}

beforeEach(() => {
  vi.useFakeTimers();
});

describe("SalixRelay", () => {
  it("proves the endpoint on each socket, and sends a peer's packets on the socket it was last heard on", async () => {
    const mesh = endpoint();
    const { opened, open } = sockets();
    const relay = new SalixRelay(mesh.native, SIGN, open);

    const first = relay.carry(URL, "t1.secret");
    expect(opened[0]!.url).toBe(`${URL}?ticket=t1.secret`);
    const proof = await register(opened[0]!, "t1", "c1");
    expect(proof.sent).toMatchObject({ type: "register", endpoint_id: ID });
    expect(proof.proves).toBe(true);
    const a = await first;

    const second = relay.carry(URL, "t2.secret");
    await register(opened[1]!, "t2", "c2");
    const b = await second;

    // Each says it is there every minute: Salix closes one silent for three.
    vi.advanceTimersByTime(60_000);
    expect(opened.map((socket) => socket.sent.at(-1))).toEqual(["ping", "ping"]);

    // A peer not heard yet: on every socket.
    const onA = opened[0]!.next();
    const onB = opened[1]!.next();
    mesh.send(PEER, "hello");
    expect([await onA, await onB]).toEqual([
      frame(PEER, "hello"),
      frame(PEER, "hello"),
    ]);

    // Heard on the second: its packets go there only, and what came is the endpoint's.
    opened[1]!.on.message(frame(PEER, "hi"));
    expect(mesh.incoming).toEqual([[PEER, "hi"]]);
    const sentOnA = opened[0]!.sent.length;
    const again = opened[1]!.next();
    mesh.send(PEER, "back");
    expect(await again).toEqual(frame(PEER, "back"));
    expect(opened[0]!.sent).toHaveLength(sentOnA);

    // That socket closed: the peer's packets go on the others again.
    b.close();
    await b.closed;
    const onFirst = opened[0]!.next();
    mesh.send(PEER, "still");
    expect(await onFirst).toEqual(frame(PEER, "still"));

    a.close();
    await a.closed;
    mesh.close();
  });

  it("fails a socket that closes before it registered, and one given up or not registered in 30 s", async () => {
    const mesh = endpoint();
    const { opened, open } = sockets();
    const relay = new SalixRelay(mesh.native, SIGN, open);

    const refused = relay.carry(URL, "t1.secret");
    opened[0]!.on.message(JSON.stringify({ type: "challenge", challenge: "c1" }));
    opened[0]!.on.closed();
    await expect(refused).rejects.toThrow("closed before it registered");

    const abort = new AbortController();
    const abandoned = relay.carry(URL, "t2.secret", abort.signal);
    abort.abort();
    await expect(abandoned).rejects.toThrow("closed before it registered");
    expect(opened[1]!.closed).toBe(true);

    const silent = relay.carry(URL, "t3.secret");
    vi.advanceTimersByTime(30_000);
    await expect(silent).rejects.toThrow("closed before it registered");
    expect(opened[2]!.closed).toBe(true);
    mesh.close();
  });
});
