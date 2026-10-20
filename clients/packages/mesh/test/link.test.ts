// What every endpoint the mesh runs on must do (link.ts), as the client and the server rely on it: the same cases on
// memory and on the station's addon (station-native.ts).
import { describe, expect, it } from "vitest";
import type {
  BiStream,
  MeshConnection,
  MeshEndpoint,
  PeerAddr,
  RecvHalf,
} from "../src/link.ts";
import { MemoryMesh } from "../src/memory.ts";
import {
  bindNativeEndpoint,
  type NativeAddr,
  type NativeBindOptions,
  type NativeConnection,
  type NativeEndpoint,
  type NativeMesh,
  type NativeStream,
} from "../src/station-native.ts";

const CONTRACT_ALPN = "comma/contract/1";

/** Two endpoints that reach each other: `station` serves CONTRACT_ALPN at `stationAddr`, `app` only connects. */
interface LinkPair {
  app: MeshEndpoint;
  station: MeshEndpoint;
  stationAddr: PeerAddr;
}

const text = (s: string) => new TextEncoder().encode(s);

/** Everything until the end, each read asked for at most `max` bytes and given no more. */
async function drain(recv: RecvHalf, max = 64 * 1024): Promise<string> {
  const parts: Uint8Array[] = [];
  for (;;) {
    const chunk = await recv.read(max);
    if (chunk === null) break;
    expect(chunk.length).toBeLessThanOrEqual(max);
    parts.push(chunk);
  }
  return new TextDecoder().decode(Buffer.concat(parts));
}

function linkContract(name: string, make: () => Promise<LinkPair>) {
  describe(`the link surface on ${name}`, () => {
    async function connected(): Promise<
      LinkPair & { out: MeshConnection; in: MeshConnection }
    > {
      const pair = await make();
      const out = await pair.app.connect(pair.stationAddr, CONTRACT_ALPN);
      const accepted = await pair.station.accept();
      if (!accepted) throw new Error("the station accepted nothing");
      return { ...pair, out, in: accepted };
    }

    it("names each side of a connection by the other's id", async () => {
      const { app, station, out, in: accepted } = await connected();
      expect(out.remoteId).toBe(station.id);
      expect(accepted.remoteId).toBe(app.id);
    });

    it("carries a stream's bytes in order both ways, in reads no larger than asked, to its end", async () => {
      const { out, in: accepted } = await connected();
      const opened = await out.openBi();
      await opened.send.write(text("hello, "));
      await opened.send.write(text("station"));
      await opened.send.finish();
      const served = await accepted.acceptBi();
      if (!served) throw new Error("no stream");
      expect(await drain(served.recv, 3)).toBe("hello, station");
      await served.send.write(text("hello, app"));
      await served.send.finish();
      expect(await drain(opened.recv)).toBe("hello, app");
    });

    it("fails the peer's reading of a stream that was reset", async () => {
      const { out, in: accepted } = await connected();
      const opened = await out.openBi();
      await opened.send.write(text("half"));
      const served = await accepted.acceptBi();
      if (!served) throw new Error("no stream");
      opened.send.reset(1);
      await expect(drain(served.recv)).rejects.toThrow();
    });

    it("ends a closed connection on both sides", async () => {
      const { out, in: accepted } = await connected();
      out.close(0, "done");
      await expect(accepted.closed()).resolves.toMatchObject({
        reason: expect.any(String),
      });
      await expect(out.closed()).resolves.toMatchObject({ reason: expect.any(String) });
      expect(await accepted.acceptBi()).toBeNull();
    });

    it("accepts nothing more once the endpoint is closed", async () => {
      const { station } = await make();
      await station.close();
      expect(await station.accept()).toBeNull();
    });

    it("refuses a protocol the peer does not serve", async () => {
      const { app, stationAddr } = await make();
      await expect(app.connect(stationAddr, "comma/other/1")).rejects.toThrow();
    });
  });
}

linkContract("memory", async () => {
  const mesh = new MemoryMesh();
  const station = mesh.endpoint("station", [CONTRACT_ALPN]);
  return { app: mesh.endpoint("app"), station, stationAddr: { id: station.id } };
});

/** A stream as the addon's: a read gives a whole chunk as it was written. */
const stream = ({ send, recv }: BiStream): NativeStream => ({
  read: () => recv.read(Number.MAX_SAFE_INTEGER),
  write: (bytes) => send.write(bytes),
  finish: () => send.finish(),
  reset: async (code) => send.reset(code),
});

/**
 * The station's addon as its API has it (station-native.ts), over endpoints in memory: a close's reason is text. What
 * it was asked is kept.
 */
function memoryAddon() {
  const mesh = new MemoryMesh();
  const bound: NativeBindOptions[] = [];
  const dialed: NativeAddr[] = [];
  const connection = (link: MeshConnection): NativeConnection => ({
    remoteId: () => link.remoteId,
    openBi: async () => stream(await link.openBi()),
    acceptBi: async () => {
      const next = await link.acceptBi();
      return next === null ? null : stream(next);
    },
    close: (code, reason) => link.close(code, reason),
    closed: async () => (await link.closed()).reason,
  });
  const endpoint = (inner: MeshEndpoint): NativeEndpoint => ({
    id: () => inner.id,
    sockets: () => [],
    connect: async (addr, alpn) => {
      dialed.push(addr);
      return connection(await inner.connect({ id: addr.id }, alpn.toString()));
    },
    accept: async () => {
      const next = await inner.accept();
      return next === null ? null : connection(next);
    },
    close: () => inner.close(),
  });
  const addon: NativeMesh = {
    bind: async (options) => {
      bound.push(options);
      return endpoint(
        mesh.endpoint(
          options.secretKey.toString("hex"),
          options.alpns.map((alpn) => alpn.toString())
        )
      );
    },
  };
  return { addon, bound, dialed };
}

const key = (byte: number) => new Uint8Array(32).fill(byte);

linkContract("the station's addon", async () => {
  const { addon } = memoryAddon();
  const station = await bindNativeEndpoint(addon, {
    secretKey: key(1),
    alpns: [CONTRACT_ALPN],
  });
  const app = await bindNativeEndpoint(addon, { secretKey: key(2) });
  return { app, station, stationAddr: { id: station.id } };
});

describe("a client's endpoint on the station's addon", () => {
  it("is never announced, looks stations up only with relays, and dials a station where it is said to be", async () => {
    const { addon, bound, dialed } = memoryAddon();
    const station = await bindNativeEndpoint(addon, {
      secretKey: key(1),
      alpns: [CONTRACT_ALPN],
    });
    const app = await bindNativeEndpoint(addon, {
      secretKey: key(2),
      relays: ["https://relay.example/"],
    });
    await app.connect(
      {
        id: station.id,
        relayUrl: "https://relay.example/",
        addresses: ["192.0.2.1:4000"],
      },
      CONTRACT_ALPN
    );
    expect(bound.map(({ discovery, lookup }) => ({ discovery, lookup }))).toEqual([
      { discovery: false, lookup: false },
      { discovery: false, lookup: true },
    ]);
    expect(dialed).toEqual([
      { id: station.id, relays: ["https://relay.example/"], ips: ["192.0.2.1:4000"] },
    ]);
  });
});
