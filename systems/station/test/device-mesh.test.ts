// A desktop's own station on the mesh (src/mesh/device-mesh.ts), on the real addon with no direct path and no iroh
// relay: its packets go only through Salix, carried here by endpoint id as StationRelay does and within one Group. One
// key serves two Groups. Only the device's owner is admitted: another member and a read-only member are refused,
// whatever Salix issued them, and a credential taken back ends the connection.
import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { afterEach, beforeEach, mock, test } from "node:test";
import { MeshClient, MESH_ALPN } from "@comma/mesh";
import { bindNativeEndpoint } from "@comma/mesh/station-native";
import { COMMA_ALPN, serveDeviceComma } from "../src/mesh/comma.ts";
import { DeviceMeshAdmissions, deviceMeshFacts } from "../src/mesh/device-mesh.ts";
import { loadMesh } from "../src/mesh/native.ts";

const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const KEYS = { keys: [{ kid: "k1", kty: "OKP", crv: "Ed25519", x: publicKey.export({ format: "jwk" }).x }] };
const at = 1_800_000_000;
// The station reads the time through `wall`, Node's clock: here it stands still at `at`. Real timers go on, for what QUIC needs.
beforeEach(() => mock.timers.enable({ apis: ["Date"], now: at * 1000 }));
afterEach(() => mock.timers.reset());
/** A key of its own for each endpoint, the same on every run. */
const keyOf = (n: number) => Buffer.alloc(32, n);

/** A member credential as Salix signs it (`SalixStore.Stations.Credential`). */
function credential(claims: { sub: string; ws: string; role: string; device: string }): string {
  const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const head = `${encode({ alg: "EdDSA", typ: "comma-member+jwt", kid: "k1" })}.${encode({ iss: "comma", email: `${claims.sub}@x`, name: claims.sub, sid: `s_${claims.sub}`, iat: at, exp: at + 3600, ...claims })}`;
  return `${head}.${sign(null, Buffer.from(head), privateKey).toString("base64url")}`;
}

const facts = (workspace: string, owner: string, revocations: unknown[] = []) => deviceMeshFacts({ workspace, workspace_was: [], grant_keys: KEYS, revocations, owner, relay_urls: [] });

test("one key in two Groups, through Salix alone: the owner reaches it, no other member does", async (t) => {
  const mesh = loadMesh();
  const relayOnly = { relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0", salixRelay: true, relayOnly: true } as const;
  const station = await mesh.bind({ secretKey: keyOf(1), alpns: [COMMA_ALPN], ...relayOnly } as never);
  const admissions = new DeviceMeshAdmissions();
  const runA = {};
  const runB = {};
  admissions.set(runA, facts("wsA", "u_owner_a"));
  admissions.set(runB, facts("wsB", "u_owner_b"));

  const asked: string[] = [];
  const admin = {
    handle: async (r: { method: string; path: string; viewer: { sub: string } }) => {
      asked.push(`${r.viewer.sub} ${r.method} ${r.path}`);
      return { status: 200, headers: {}, body: Buffer.from(`{"who":"${r.viewer.sub}"}`) };
    },
  } as never;

  const client = async (n: number) => {
    const native = await mesh.bind({ secretKey: keyOf(n), alpns: [], ...relayOnly } as never);
    return native;
  };
  const clients = await Promise.all([client(2), client(3), client(4), client(5)]);
  const endpoints = new Map([station, ...clients].map((e) => [e.id(), e]));
  let carried = 0;
  // Salix: what one endpoint sends to an id, the endpoint with that id receives, from the sender's id.
  const carry = async (from: typeof station) => {
    for (;;) {
      const packets = await from.relayOutgoing!(64);
      if (packets.length === 0) return;
      for (const packet of packets) {
        carried++;
        endpoints.get(packet.to)?.relayIncoming!(from.id(), packet.data);
      }
    }
  };
  for (const endpoint of endpoints.values()) void carry(endpoint);

  void (async () => {
    for (;;) {
      const conn = await station.accept();
      if (!conn) return;
      void serveDeviceComma({ admin, up: () => true }, admissions, conn).catch(() => {});
    }
  })();

  const reach = (native: (typeof clients)[number], given: string) => {
    const client = new MeshClient({
      endpoint: {
        id: native.id(),
        connect: async (_peer, alpn) => {
          const { nativeConnection } = await import("@comma/mesh/station-native");
          return nativeConnection(await native.connect({ id: station.id(), salix: true }, Buffer.from(alpn)));
        },
        accept: async () => null,
        close: () => native.close(),
      },
      credential: async () => given,
    });
    t.after(() => client.close());
    return client;
  };
  const read = async (client: MeshClient, path = "/overview") => {
    const response = await client.request({ id: station.id() }, { method: "GET", path });
    let body = "";
    for await (const chunk of response.body) body += new TextDecoder().decode(chunk);
    return [response.status, body] as const;
  };
  t.after(async () => {
    await Promise.all([station, ...clients].map((e) => e.close()));
  });

  const [ownerA, ownerB, member, viewer] = clients;

  // Each Group's device owner reaches the one key, and it goes through Salix.
  const a = reach(ownerA!, credential({ sub: "u_owner_a", ws: "wsA", role: "owner", device: ownerA!.id() }));
  assert.deepEqual(await read(a), [200, '{"who":"u_owner_a"}']);
  assert.ok(carried > 0, "nothing went through Salix");
  const via = await a.nextVia(station.id(), null);
  assert.deepEqual(via, { via: "salix", closed: false });
  const b = reach(ownerB!, credential({ sub: "u_owner_b", ws: "wsB", role: "owner", device: ownerB!.id() }));
  assert.deepEqual(await read(b), [200, '{"who":"u_owner_b"}']);

  // Nothing else of the machine is served yet, to the owner either.
  assert.equal((await read(a, "/chats"))[0], 403);

  // Another member of the Group has a valid credential, and is refused.
  const other = reach(member!, credential({ sub: "u_member", ws: "wsA", role: "member", device: member!.id() }));
  await assert.rejects(read(other), /only this computer's owner/);
  // A read-only member too, and an owner whose role in the Group is now read-only.
  const stranger = reach(viewer!, credential({ sub: "u_viewer", ws: "wsA", role: "viewer", device: viewer!.id() }));
  await assert.rejects(read(stranger), /only this computer's owner/);
  const demoted = reach(viewer!, credential({ sub: "u_owner_a", ws: "wsA", role: "viewer", device: viewer!.id() }));
  await assert.rejects(read(demoted), /read-only member/);
  // Another Group's owner, with a credential for a Workspace this station is not told of.
  const elsewhere = reach(member!, credential({ sub: "u_owner_a", ws: "wsC", role: "owner", device: member!.id() }));
  await assert.rejects(read(elsewhere), /another workspace/);
  assert.deepEqual(new Set(asked), new Set(["u_owner_a GET /overview", "u_owner_b GET /overview"]));

  // A's credential taken back: told over the run, and the connection ends; B's stays.
  const closed = new Promise<void>((resolve) => {
    const stop = admissions.listen(() => {
      stop();
      // The other listeners run before what awaits this: they are called in one go.
      resolve();
    });
  });
  admissions.set(runA, facts("wsA", "u_owner_a", [{ kind: "sub", id: "u_owner_a", at: at + 1 }]));
  await closed;
  // Its request finds the connection gone, or a new one refused; a new one is refused either way.
  await assert.rejects(read(a));
  await assert.rejects(read(a), /credential revoked/);
  assert.deepEqual(await read(b), [200, '{"who":"u_owner_b"}']);

  // A's run ends: nothing is admitted for its Group; Salix's null says the same of B's.
  admissions.set(runA, null);
  assert.throws(() => admissions.admit(credential({ sub: "u_owner_a", ws: "wsA", role: "owner", device: ownerA!.id() }), ownerA!.id()), /another workspace/);
  admissions.set(runB, deviceMeshFacts(null));
  assert.equal(admissions.active(), false);
  assert.throws(() => admissions.admit(credential({ sub: "u_owner_b", ws: "wsB", role: "owner", device: ownerB!.id() }), ownerB!.id()), /in no workspace/);
  assert.equal(MESH_ALPN, COMMA_ALPN.toString());
});

test("a client that picks Salix alone holds no IP path and no iroh relay, whatever relays it was given", async (t) => {
  const app = await bindNativeEndpoint(loadMesh(), { secretKey: keyOf(6), relays: ["https://relay.example.test"], salixOnly: true, salixRelay: true });
  t.after(() => app.close());
  assert.deepEqual(app.sockets(), []);
  assert.ok(app.relay, "bound without the Salix transport");
});

test("a run that drops leaves what is open for a moment, admits no one new, and the run after it is the one heard", async () => {
  const device = "de".repeat(32);
  const admissions = new DeviceMeshAdmissions();
  const run = {};
  admissions.set(run, facts("wsA", "u_owner_a"));
  const open = admissions.admit(credential({ sub: "u_owner_a", ws: "wsA", role: "owner", device }), device);
  assert.equal(admissions.holds(open), true);

  admissions.dropped(run, 60_000);
  assert.equal(admissions.holds(open), true, "a direct path went with Salix");
  assert.throws(() => admissions.admit(credential({ sub: "u_owner_a", ws: "wsA", role: "owner", device }), device), /another workspace/);

  // The next run says it was revoked meanwhile: the old one's word does not stand beside it.
  const next = {};
  admissions.set(next, facts("wsA", "u_owner_a", [{ kind: "sub", id: "u_owner_a", at: at + 1 }]));
  assert.equal(admissions.holds(open), false);

  // And no next run: it ends by itself.
  const alone = new DeviceMeshAdmissions();
  const gone = {};
  alone.set(gone, facts("wsB", "u_owner_b"));
  const ended = new Promise<void>((resolve) => alone.listen(resolve));
  alone.dropped(gone, 1);
  await ended;
  assert.equal(alone.active(), false);
});

test("a credential past its end holds no longer, whatever the run says", () => {
  const device = "de".repeat(32);
  const admissions = new DeviceMeshAdmissions();
  admissions.set({}, facts("wsA", "u_owner_a"));
  const admitted = admissions.admit(credential({ sub: "u_owner_a", ws: "wsA", role: "owner", device }), device);
  assert.equal(admissions.holds({ ...admitted, exp: at - 1 }), false);
  assert.equal(admissions.holds(admitted), true);
});
