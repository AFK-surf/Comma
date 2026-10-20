// The station's control plane (src/cloud/plane.ts, provider.ts): still.fail cloud's as it always was — its paths,
// tags, both header names and cloud.json unchanged — and Comma's (contract v1 §1–3, §6–7), each against a fake control
// plane that checks every signature. Then which credentials each takes, and a viewer's reads.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Effect, Fiber, Stream, SubscriptionRef } from "effect";
import { enroll, placedState } from "../src/cli.ts";
import { loadKey } from "../src/cloud/key.ts";
import { makeControlPlane } from "../src/cloud/plane.ts";
import { COMMA, STILLFAIL, providerOf } from "../src/cloud/provider.ts";
import { applyState } from "../src/cloud/presence.ts";
import { Cloud, readState, workspaceIds, workspaceKey, writeState } from "../src/cloud/state.ts";
import { verifyMember } from "../src/mesh/credential.ts";
import type { Endpoint, Reach } from "../src/mesh/native.ts";
import { followReach } from "../src/mesh/reach.ts";
import { readOnlyMay } from "../src/api/admin.ts";
import { FakeControlPlane } from "./fake-control-plane.ts";

/// Looks every 20 ms until `what` holds: what comes over real connections has no event here. No deadline (it comes,
/// however slow the machine, or the test hangs).
const until = async (what: () => boolean) => {
  while (!what()) await new Promise((r) => setTimeout(r, 20));
};

/// Enrolled with `provider` in a fake control plane, its plane made and its presence socket held.
async function enrolled(t: { after(f: () => unknown): void }, provider: "stillfail" | "comma", gateways: string[] = []) {
  const fake = new FakeControlPlane({ provider, gateways });
  const origin = await fake.start();
  const data = mkdtempSync(join(tmpdir(), "plane-"));
  const said = console.log;
  console.log = () => {};
  try {
    await enroll(data, origin, "tok", provider);
  } finally {
    console.log = said;
  }
  const state = new Cloud(data);
  const key = loadKey(data);
  const up = Effect.runSync(SubscriptionRef.make(true));
  const plane = makeControlPlane({ state, changes: Stream.never, key, up });
  const presence = Effect.runFork(plane.presence);
  t.after(async () => {
    await Effect.runPromise(Fiber.interrupt(presence));
    state.close();
    await fake.close();
  });
  return { fake, origin, data, state, key, plane };
}

test("still.fail cloud: enrollment, presence, notices, traces and releases as they always were", async (t) => {
  const { fake, origin, data, state, key, plane } = await enrolled(t, "stillfail");
  const enrolledAt = fake.asked.find((a) => a.path === "/v1/stations/enroll")!;
  assert.deepEqual(enrolledAt.verified, ["stillfail"]);
  // cloud.json as before: no provider, no gateways.
  const file = JSON.parse(readFileSync(join(data, "mesh", "cloud.json"), "utf8"));
  assert.deepEqual(Object.keys(file), ["origin", "station", "workspace", "workspace_name", "name", "relay_url", "relay_urls", "grant_keys", "peers", "revocations"]);
  assert.equal(state.provider(), "stillfail");

  await until(() => state.peersCurrent);
  const connected = fake.asked.find((a) => a.path === "/v1/stations/connect")!;
  // Signed under both names, each its own proof.
  assert.deepEqual(connected.verified, ["stillfail", "ember"]);
  assert.equal(connected.headers["x-stillfail-version"], connected.headers["x-ember-version"]);
  assert.equal(state.state!.gateway_keys, undefined);

  await Effect.runPromise(plane.notify([{ email: "a@x", title: "t", body: "b" } as any]));
  const notified = fake.asked.find((a) => a.path === "/v1/stations/notify")!;
  assert.deepEqual(notified.verified, ["ember-station-notify-v1", "ember:ember-station-notify-v1"]);
  assert.deepEqual(JSON.parse(notified.body.toString()), { notices: [{ email: "a@x", title: "t", body: "b" }] });

  await Effect.runPromise(plane.traces([{ name: "span" }]));
  const traced = fake.asked.find((a) => a.path === "/v1/telemetry/traces")!;
  assert.deepEqual(traced.verified, ["stillfail-station-telemetry-v1", "ember:ember-station-telemetry-v1"]);
  assert.equal(JSON.parse(traced.body.toString()).resourceSpans[0].resource.attributes[1].value.stringValue, key.id);

  assert.equal(plane.releaseBase(), origin);
  assert.deepEqual(plane.credential(), STILLFAIL.credential);
});

test("Comma: enrollment, presence with gateways, notices, no traces, releases under /stations", async (t) => {
  const gateway = "ab".repeat(32);
  const { fake, origin, data, state, plane } = await enrolled(t, "comma", [gateway]);
  assert.deepEqual(fake.asked.find((a) => a.path === "/v1/comma/stations/enroll")!.verified, ["comma"]);
  const file = JSON.parse(readFileSync(join(data, "mesh", "cloud.json"), "utf8"));
  assert.equal(file.provider, "comma");
  assert.deepEqual(file.gateway_keys, [gateway]);
  assert.equal(state.provider(), "comma");

  await until(() => state.peersCurrent);
  const connected = fake.asked.find((a) => a.path === "/v1/comma/stations/connect")!;
  assert.deepEqual(connected.verified, ["comma"]);
  assert.equal(connected.headers["x-ember-signature"], undefined, "Comma is sent the still.fail headers only");
  assert.equal(state.state!.workspace, "ws1");

  // The gateways as the presence socket says them, kept in cloud.json.
  fake.gateways = ["cd".repeat(32)];
  fake.push(state.state!.station);
  await until(() => state.state!.gateway_keys?.[0] === "cd".repeat(32));
  assert.deepEqual(JSON.parse(readFileSync(join(data, "mesh", "cloud.json"), "utf8")).gateway_keys, ["cd".repeat(32)]);

  await Effect.runPromise(plane.notify([{ email: "a@x" } as any]));
  const notified = fake.asked.find((a) => a.path === "/v1/comma/stations/notify")!;
  assert.deepEqual(notified.verified, ["comma-station-notify-v1"]);
  assert.equal(notified.headers["x-ember-station"], undefined);

  const before = fake.asked.length;
  await Effect.runPromise(plane.traces([{ name: "span" }]));
  assert.equal(fake.asked.length, before, "Comma takes no traces");

  assert.equal(plane.releaseBase(), `${origin}/stations`);
  assert.deepEqual(plane.credential(), COMMA.credential);
});

/// An endpoint whose reach the test moves, as iroh's moves when it homes on another relay.
function movingEndpoint(first: Reach) {
  let now: Reach = first;
  let wake: (() => void) | null = null;
  const endpoint: Pick<Endpoint, "reach"> = {
    async reach(last) {
      while (JSON.stringify(now) === JSON.stringify(last)) await new Promise<void>((r) => (wake = r));
      return now;
    },
  };
  return {
    endpoint,
    move(next: Reach) {
      now = next;
      wake?.();
    },
  };
}

test("Comma is told where the mesh endpoint may be reached, at connect and whenever it moves", async (t) => {
  const { fake, state } = await enrolled(t, "comma");
  const moving = movingEndpoint({ homeRelay: "https://relay1.comma.test/", addrs: ["192.168.1.5:4770"] });
  const follow = Effect.runFork(followReach(moving.endpoint, state));
  t.after(() => Effect.runPromise(Fiber.interrupt(follow)));
  const told = () => fake.heard.filter((h) => h.type === "reach");

  await until(() => told().length === 1);
  assert.deepEqual(told()[0], { type: "reach", home_relay: "https://relay1.comma.test/", addrs: ["192.168.1.5:4770"] });

  // Homed on another relay: told again.
  moving.move({ homeRelay: "https://relay2.comma.test/", addrs: ["192.168.1.5:4770"] });
  await until(() => told().length === 2);
  assert.deepEqual(told()[1], { type: "reach", home_relay: "https://relay2.comma.test/", addrs: ["192.168.1.5:4770"] });

  // A new presence socket is told at once.
  fake.sockets[0]!.terminate();
  await until(() => told().length === 3);
  assert.equal(fake.sockets.length, 2);
  assert.equal(told()[2].home_relay, "https://relay2.comma.test/");
});

/// A Comma station as enrolled before Salix kept the roster: its workspace is the Comma Workspace id.
function held(workspace: string) {
  const data = mkdtempSync(join(tmpdir(), "plane-"));
  writeState(data, {
    provider: "comma", origin: "https://api.comma.test", station: "ab".repeat(32), workspace, workspace_name: "Team",
    name: "Station", relay_url: "", relay_urls: [], grant_keys: { keys: [] }, peers: [], revocations: [],
  });
  return { data, cloud: new Cloud(data) };
}

test("a state frame that names the id held as one of before is a rename: the workspace is the same one", () => {
  const { data, cloud } = held("wsp_before");
  const group = "grp1_1000000000000000001_1000000000000000002";
  try {
    assert.equal(workspaceKey(cloud.state!), "wsp_before");
    assert.equal(readFileSync(join(data, "mesh", "cloud.json"), "utf8").includes("workspace_was"), false, "a file of a workspace never renamed is as it was");
    const peers = [{ id: "ab".repeat(32), name: "Station", version: "0.1.9" }];
    applyState(cloud, JSON.stringify({ type: "state", workspace: group, workspace_was: ["wsp_before"], workspace_name: "Team", name: "Station", peers }));
    // The new id is the one shown and told; what the station keeps and tells its peers stays keyed by the first.
    assert.equal(cloud.state!.workspace, group);
    assert.deepEqual(workspaceIds(cloud.state!), [group, "wsp_before"]);
    assert.equal(workspaceKey(cloud.state!), "wsp_before");
    // In cloud.json too, for the next start.
    assert.deepEqual([readState(data)!.workspace, readState(data)!.workspace_was], [group, ["wsp_before"]]);
    assert.equal(workspaceKey(readState(data)!), "wsp_before");
    assert.deepEqual(readState(data)!.peers, peers);
    assert.equal(cloud.peersCurrent, true);
    // Renamed again, and a station that was away for both: the first id is still the first.
    applyState(cloud, JSON.stringify({ type: "state", workspace: "grp_later", workspace_was: ["wsp_before", group], peers }));
    assert.equal(workspaceKey(cloud.state!), "wsp_before");
    assert.deepEqual(workspaceIds(cloud.state!), ["grp_later", "wsp_before", group]);
  } finally {
    cloud.close();
  }
});

test("a state frame that names another workspace and not the id held is a move", () => {
  const { data, cloud } = held("wsp_before");
  try {
    applyState(cloud, JSON.stringify({ type: "state", workspace: "grp_other", workspace_was: ["wsp_other"], peers: [] }));
    assert.equal(workspaceKey(cloud.state!), "wsp_other");
    assert.equal(workspaceIds(cloud.state!).includes("wsp_before"), false);
    // A control plane that names no ids of before (still.fail cloud, Comma before it renamed any): none are kept.
    applyState(cloud, JSON.stringify({ type: "state", workspace: "grp_third", peers: [] }));
    assert.deepEqual([workspaceKey(cloud.state!), workspaceIds(cloud.state!)], ["grp_third", ["grp_third"]]);
    assert.equal(readState(data)!.workspace_was, undefined);
  } finally {
    cloud.close();
  }
});

test("an enrollment's answer names the workspace's ids of before as a state frame does", () => {
  const placed = placedState("https://api.comma.test", "ab".repeat(32), { workspace: "grp_now", workspace_was: ["wsp_first"], workspace_name: "Team", name: "S" }, "comma");
  assert.deepEqual([placed.workspace, placed.workspace_was, workspaceKey(placed)], ["grp_now", ["wsp_first"], "wsp_first"]);
  assert.equal(placedState("https://api.comma.test", "ab".repeat(32), { workspace: "grp_now" }, "comma").workspace_was, undefined);
});

test("a member's credential is this workspace's under the id of now or any of before", async () => {
  const fake = new FakeControlPlane({ provider: "comma" });
  const device = "d".repeat(64);
  // Issued at a fixed time, good long past any run of this test.
  const [issued, expires] = [1_700_000_000, 4_000_000_000];
  const keys = { keys: [fake.grant.jwk] };
  const credential = (ws: string) => fake.grant.credential({ typ: "comma-member+jwt" }, { sub: "usr_1", email: "a@x", name: "A", ws, role: "member", device, sid: "s1", iat: issued, exp: expires, iss: "comma" });
  const { cloud } = held("wsp_before");
  try {
    const admit = (ws: string) => verifyMember(credential(ws), keys, workspaceIds(cloud.state!), device, cloud.state!.revocations, COMMA.credential);
    assert.equal(admit("wsp_before").viewer.email, "a@x");
    assert.throws(() => admit("grp_now"), /another workspace/);
    applyState(cloud, JSON.stringify({ type: "state", workspace: "grp_now", workspace_was: ["wsp_before"], peers: [] }));
    // The one a client kept from before the rename, and the one issued after it.
    assert.equal(admit("wsp_before").viewer.email, "a@x");
    assert.equal(admit("grp_now").viewer.email, "a@x");
    assert.throws(() => admit("wsp_other"), /another workspace/);
    // A revocation takes back either.
    applyState(cloud, JSON.stringify({ type: "revoke", kind: "sid", id: "s1", at: issued }));
    assert.throws(() => admit("wsp_before"), /revoked/);
    assert.throws(() => admit("grp_now"), /revoked/);
  } finally {
    cloud.close();
  }
});

test("a cloud.json without a provider is still.fail cloud's; one naming another is that one's", () => {
  assert.equal(providerOf(undefined), "stillfail");
  assert.equal(providerOf("stillfail"), "stillfail");
  assert.equal(providerOf("comma"), "comma");
  assert.equal(providerOf("other"), "stillfail");
});

test("each provider's credentials are taken only where it is the control plane", async () => {
  const fake = new FakeControlPlane({ provider: "comma" });
  const device = "d".repeat(64);
  const now = Math.floor(Date.now() / 1000);
  const claims = { sub: "usr_1", email: "a@x", name: "A", ws: "ws1", role: "viewer", device, sid: "s1", iat: now, exp: now + 3600 };
  const keys = { keys: [fake.grant.jwk] };
  const comma = fake.grant.credential({ typ: "comma-member+jwt" }, { ...claims, iss: "comma" });
  const stillfail = fake.grant.credential({ typ: "stillfail-member+jwt" }, { ...claims, iss: "stillfail-cloud" });
  assert.equal(verifyMember(comma, keys, ["ws1"], device, [], COMMA.credential).viewer.role, "viewer");
  assert.throws(() => verifyMember(comma, keys, ["ws1"], device, []), /not a member's credential/);
  assert.equal(verifyMember(stillfail, keys, ["ws1"], device, []).viewer.email, "a@x");
  assert.throws(() => verifyMember(stillfail, keys, ["ws1"], device, [], COMMA.credential), /not a member's credential/);
  // Its type but another issuer.
  const forged = fake.grant.credential({ typ: "comma-member+jwt" }, { ...claims, iss: "stillfail-cloud" });
  assert.throws(() => verifyMember(forged, keys, ["ws1"], device, [], COMMA.credential), /not issued/);
  // Revoked by its Comma session.
  assert.throws(() => verifyMember(comma, keys, ["ws1"], device, [{ kind: "sid", id: "s1", at: now }], COMMA.credential), /revoked/);
});

test("a viewer reads and keeps their own marks, and changes nothing else", () => {
  assert.ok(readOnlyMay({ method: "GET", path: "/chats" }));
  assert.ok(readOnlyMay({ method: "GET", path: "/events" }));
  assert.ok(readOnlyMay({ method: "PUT", path: "/threads/3/read" }));
  assert.ok(!readOnlyMay({ method: "POST", path: "/threads/3/messages" }));
  assert.ok(!readOnlyMay({ method: "POST", path: "/sessions" }));
  assert.ok(!readOnlyMay({ method: "PUT", path: "/threads/3/title" }));
  assert.ok(!readOnlyMay({ method: "PUT", path: "/tools/access" }));
  assert.ok(!readOnlyMay({ method: "DELETE", path: "/sessions/k" }));
});
