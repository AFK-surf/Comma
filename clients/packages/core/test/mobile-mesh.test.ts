import { HostError } from "@comma/core-kernel";
import type { BiStream, MeshConnection } from "@comma/mesh";
import type { MemoryEndpoint, MemoryMesh } from "@comma/mesh/testing";
import { Effect } from "effect";
import { describe, expect, it } from "vitest";
import { mobileStations, type MeshOps } from "../src/hosts/mobile-mesh.ts";
import { FakeStations, fakeCredential } from "../src/testing/index.ts";

const WS = "wsp_1";
type Args = Record<string, unknown>;
const answer = (json: unknown, bytes: Uint8Array | null = null) => ({ json, bytes });

/**
 * The engine's `mesh.*` operations (clients/packages/mesh/native) on endpoints in memory: what the phones' core asks
 * of its iroh, by handle, answered as the Rust answers it. The Salix sockets it opens are kept, for a test to see.
 */
function fakeEngine(mesh: MemoryMesh) {
  const handles = new Map<number, unknown>();
  const keep = (handle: unknown) => {
    handles.set(handles.size + 1, handle);
    return handles.size;
  };
  const get = <T>(a: Args): T => {
    const handle = handles.get(Number(a.id));
    if (handle === undefined) throw new Error(`no handle ${String(a.id)}`);
    return handle as T;
  };
  const bound: Args[] = [];
  const sockets: { url: string; ticket: string }[] = [];
  const ops: Record<string, (a: Args, bytes: Uint8Array | null) => Promise<unknown>> = {
    "mesh.bind": async (a, key) => {
      bound.push(a);
      const id = `device-${Buffer.from(key!.subarray(0, 4)).toString("hex")}`;
      return answer({ id: keep(mesh.endpoint(id)), endpoint: id });
    },
    "mesh.connect": async (a, alpn) => {
      const addr = a.addr as { id: string; relays: string[]; ips: string[] };
      const conn = await get<MemoryEndpoint>(a).connect(
        { id: addr.id, relayUrl: addr.relays[0], addresses: addr.ips },
        new TextDecoder().decode(alpn!)
      );
      return answer({ id: keep(conn), remote: conn.remoteId });
    },
    "mesh.endpointClose": async (a) => answer(await get<MemoryEndpoint>(a).close()),
    "mesh.openBi": async (a) =>
      answer({ id: keep(await get<MeshConnection>(a).openBi()) }),
    "mesh.acceptBi": async (a) => {
      const stream = await get<MeshConnection>(a).acceptBi();
      return answer(stream ? { id: keep(stream) } : { end: true });
    },
    "mesh.closed": async (a) =>
      answer({ reason: (await get<MeshConnection>(a).closed()).reason }),
    "mesh.close": async (a) =>
      answer(get<MeshConnection>(a).close(Number(a.code), String(a.reason))),
    "mesh.nextVia": async (a) => answer(await get<MeshConnection>(a).nextVia!(null)),
    "mesh.read": async (a) => {
      const chunk = await get<BiStream>(a).recv.read(64 * 1024);
      return chunk === null ? answer({ end: true }) : answer({}, chunk);
    },
    "mesh.write": async (a, bytes) => answer(await get<BiStream>(a).send.write(bytes!)),
    "mesh.finish": async (a) => answer(await get<BiStream>(a).send.finish()),
    "mesh.reset": async (a) => answer(get<BiStream>(a).send.reset(Number(a.code))),
    "mesh.carry": async (a) => {
      sockets.push({ url: String(a.url), ticket: String(a.ticket) });
      return answer({ id: keep(new Promise<never>(() => {})) });
    },
    "mesh.carried": async (a) => answer(await get<Promise<void>>(a)),
    "mesh.uncarry": async () => answer({}),
  };
  const engine: MeshOps = {
    call: (op, json, bytes = null) =>
      Effect.tryPromise({
        try: () =>
          ops[op]!((json ?? {}) as Args, bytes) as Promise<{
            json: unknown;
            bytes: Uint8Array | null;
          }>,
        catch: (e) => new HostError(e instanceof Error ? e.message : String(e)),
      }),
  };
  return { engine, bound, sockets };
}

describe("A phone's stations", () => {
  it("are asked on the engine's iroh, bound with the control plane's relays and Salix", async () => {
    const stations = new FakeStations(() => 0);
    const station = stations.station("st_a", WS);
    station.chats = [{ thread: 7, title: "Build" }];
    const phone = fakeEngine(stations.mesh);
    const asked = await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const links = yield* mobileStations(phone.engine).open({
            secretKey: new Uint8Array(32).fill(1),
            relays: ["https://relay.example.test/"],
          });
          links.credential(
            "st_a",
            fakeCredential({ ws: WS, device: links.id, role: "owner", exp: 1e10 })
          );
          const response = yield* links.request("st_a", {
            method: "GET",
            path: "/chats",
            headers: [],
            body: null,
          });
          const body: Uint8Array[] = [];
          for (
            let chunk = yield* response.body.take;
            chunk !== null;
            chunk = yield* response.body.take
          )
            body.push(chunk);
          const via = yield* links.nextVia("st_a", null);
          yield* links.relay!(WS, {
            url: "wss://api.example.test/v1/comma/station-relay",
            ticket: "t.secret",
          });
          return {
            status: response.status,
            body: JSON.parse(Buffer.concat(body).toString()),
            via,
            id: links.id,
          };
        })
      )
    );
    expect(asked).toEqual({
      status: 200,
      body: [{ thread: 7, title: "Build" }],
      via: { via: "direct", closed: false },
      id: "device-01010101",
    });
    expect(phone.bound).toEqual([
      { relayUrls: ["https://relay.example.test/"], salixRelay: true },
    ]);
    // The station admitted the endpoint the engine bound: the credential names it.
    expect(station.admitted).toEqual([
      expect.objectContaining({ device: "device-01010101" }),
    ]);
    expect(phone.sockets).toEqual([
      { url: "wss://api.example.test/v1/comma/station-relay", ticket: "t.secret" },
    ]);
  });
});
