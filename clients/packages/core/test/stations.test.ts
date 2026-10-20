import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { StationsHomeValue, StationsValue } from "../src/contract.ts";
import {
  FakeHost,
  FakeStations,
  fakeCredential,
  inProcessOpener,
  json,
  offline,
  signedIn,
  signedOut,
  startTestCore,
  type FakeCommaApi,
} from "../src/testing/index.ts";

const WS = "wsp_1";
const OTHER = "wsp_2";
const me = (workspaces = [{ id: WS, name: "Main", role: "owner" }]) => ({
  user: { id: "user-1", email: "user-1@example.test", name: "Ada" },
  workspaces,
  relay_urls: ["https://relay.example.test/"],
});
const station = (id: string, extra: Record<string, unknown> = {}) => ({
  id,
  name: id,
  version: "1.0.0",
  online: true,
  enrolled_at: 1_700_000_000,
  enrolled_by: "user-1",
  ...extra,
});
const listPath = (ws: string) => `/v1/comma/workspaces/${ws}/stations`;
const eventsPath = (ws: string) => `/v1/comma/workspaces/${ws}/stations/events`;
const credentialPath = (ws: string) => `/v1/comma/workspaces/${ws}/station-credential`;
const relayPath = (ws: string) => `/v1/comma/workspaces/${ws}/station-relay`;

function setup(
  options: {
    role?: string;
    ttlSeconds?: number;
    mesh?: boolean;
    /** The host keeps stations linked whether shown or not (the desktop app). */
    always?: boolean;
    /** The time stations check credentials by: the test's clock unless given. */
    stationClock?: () => number;
    /** The endpoint is reached through Salix too. */
    salix?: boolean;
  } = {}
) {
  const host = new FakeHost();
  const time = host.time!;
  const stations = new FakeStations(options.stationClock ?? (() => time.now()));
  stations.salix = options.salix === true;
  if (options.mesh !== false)
    host.stationMesh = options.always
      ? { ...stations.ports, alwaysLinked: true }
      : stations.ports;
  const seconds = () => Math.floor(time.now() / 1000);
  host.api
    .on("GET", "/v1/comma/stations/me", me())
    .on("GET", listPath(WS), { stations: [station("st_a"), station("st_b")] })
    .onStream(eventsPath(WS))
    .on("GET", "/v1/comma/workspaces", {
      data: [{ id: WS, group_id: "grp_1", name: "Main", status: "ready" }],
    });
  /** The control plane issues credentials for `ws`'s stations (again, after a test stopped it). */
  const issuing = (ws: string) =>
    host.api.on("POST", credentialPath(ws), (request) => {
      const exp = seconds() + (options.ttlSeconds ?? 3_600);
      return json(200, {
        credential: fakeCredential({
          ws,
          device: (request.body as { device: string }).device,
          role: options.role ?? "owner",
          exp,
        }),
        issued_at: seconds(),
        expires_at: exp,
        relay_urls: [],
      });
    });
  for (const ws of [WS, OTHER]) issuing(ws);
  return { host, time, api: host.api, stations, issuing, ...start(host) };
}

/** A core on `host` (another one after a restart: the same device storage and databases), signed in as `user`. */
function start(host: FakeHost, user = "user-1") {
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const stops = new Map<string, () => void>();
  const watch = <T>(topic: Topic) => {
    const k = topicKey(topic);
    stops.set(
      k,
      client.subscribe(
        topic,
        (v) => values.set(k, v),
        () => undefined
      )
    );
    return () => values.get(k) as T;
  };
  const unwatch = (topic: Topic) => stops.get(topicKey(topic))?.();
  core.observeSession(signedIn(user));
  return { core, client, watch, unwatch };
}

/** The control plane answers nothing from now on. */
function controlPlaneDown(api: FakeCommaApi) {
  for (const method of ["GET", "POST", "PUT", "PATCH", "DELETE"])
    api.on(method, "/*", offline());
  api.onStream(eventsPath(WS), 503).onStream(eventsPath(OTHER), 503);
}

const links = (value: StationsValue | undefined) =>
  Object.fromEntries((value?.stations ?? []).map((s) => [s.id, s.link.state]));

describe("Stations", () => {
  it("shows the account and its workspaces, and why it cannot without a mesh or a session", async () => {
    const t = setup();
    const home = t.watch<StationsHomeValue>({ topic: "stationsHome" });
    await t.time.pass(100);
    expect(home()).toEqual({
      state: "ready",
      account: { id: "user-1", email: "user-1@example.test", name: "Ada" },
      workspaces: [{ id: WS, name: "Main", role: "owner" }],
    });
    // Nothing is bound to show the account.
    expect(t.stations.bound).toEqual([]);

    t.core.observeSession(signedOut());
    await t.time.pass(100);
    expect(home()).toMatchObject({ state: "signed_out", workspaces: [] });

    const without = setup({ mesh: false });
    const none = without.watch<StationsHomeValue>({ topic: "stationsHome" });
    await without.time.pass(100);
    expect(none()).toMatchObject({ state: "unavailable" });
    expect(without.api.seen("GET", "/v1/comma/stations/me")).toHaveLength(0);
  });

  it("lists a workspace's stations with their presence, connects to each, and connects again after it went", async () => {
    const t = setup();
    const a = t.stations.station("st_a", WS);
    t.stations.station("st_b", WS);
    const topic = { topic: "stations", workspace: WS };
    const value = t.watch<StationsValue>(topic);
    await t.time.pass(100);
    expect(value()).toMatchObject({ workspace: WS, loading: false });
    expect(links(value())).toEqual({ st_a: "online", st_b: "online" });
    // One endpoint, bound with the control plane's relays; one credential for the workspace, for this device.
    expect(t.stations.bound).toEqual([
      {
        id: expect.stringMatching(/^device-/),
        relays: ["https://relay.example.test/"],
      },
    ]);
    expect(t.api.seen("POST", credentialPath(WS))).toEqual([
      expect.objectContaining({ body: { device: t.stations.bound[0]!.id } }),
    ]);
    expect(a.admitted).toHaveLength(1);

    // Presence comes from the workspace's events; a roster change reads the list again.
    t.api.open(eventsPath(WS))!.named("station", { id: "st_b", online: false });
    await t.time.pass(100);
    expect(value()!.stations.find((s) => s.id === "st_b")?.present).toBe(false);
    t.api.on("GET", listPath(WS), { stations: [station("st_a")] });
    t.api.open(eventsPath(WS))!.named("stations", {});
    await t.time.pass(100);
    expect(value()!.stations.map((s) => s.id)).toEqual(["st_a"]);

    // The network goes: it says so, and connects again a second later with the credential it has.
    t.stations.mesh.cut();
    await t.time.pass(100);
    expect(links(value())).toEqual({ st_a: "reconnecting" });
    await t.time.pass(1_000);
    expect(links(value())).toEqual({ st_a: "online" });
    expect(a.admitted).toHaveLength(2);
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(1);

    // Let go: the endpoint closes.
    t.unwatch(topic);
    await t.time.pass(120_000, 10_000);
    expect(t.stations.open).toBe(false);
  });

  it("keeps each workspace's stations linked and their chats read, shown or not, where the host stays on", async () => {
    const t = setup({ always: true });
    t.api.on("GET", listPath(WS), { stations: [station("st_a")] });
    const a = t.stations.station("st_a", WS);
    await t.time.pass(100);
    // Nothing is shown: each station is reached, its chats read and its events followed.
    expect(t.stations.open).toBe(true);
    expect(a.admitted).toHaveLength(1);
    expect(a.asked).toEqual(expect.arrayContaining(["GET /chats", "GET /events"]));

    // Shown, then hidden: the same connections, and they stay.
    const topic = { topic: "stations", workspace: WS };
    const value = t.watch<StationsValue>(topic);
    await t.time.pass(100);
    expect(links(value())).toEqual({ st_a: "online" });
    t.unwatch(topic);
    await t.time.pass(120_000, 10_000);
    expect(t.stations.open).toBe(true);
    expect(a.admitted).toHaveLength(1);
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(1);

    // Signed out: they go.
    t.core.observeSession(signedOut());
    await t.time.pass(100);
    expect(t.stations.open).toBe(false);

    // A host that does not stay on reaches no station until one is shown.
    const shownOnly = setup();
    const b = shownOnly.stations.station("st_a", WS);
    await shownOnly.time.pass(100);
    expect(shownOnly.stations.bound).toEqual([]);
    expect(b.asked).toEqual([]);
  });

  it("dials each station where the control plane says it is, and there again after it moved", async () => {
    const t = setup();
    t.stations.station("st_a", WS);
    t.stations.station("st_b", WS);
    t.api.on("GET", listPath(WS), {
      stations: [
        station("st_a", {
          home_relay: "https://relay.example.test/",
          addrs: ["192.168.1.5:4770"],
        }),
        // An old station says nothing: it is dialed by its id.
        station("st_b"),
      ],
    });
    const value = t.watch<StationsValue>({ topic: "stations", workspace: WS });
    await t.time.pass(100);
    expect(links(value())).toEqual({ st_a: "online", st_b: "online" });
    expect(t.stations.mesh.dials).toEqual(
      expect.arrayContaining([
        {
          id: "st_a",
          relayUrl: "https://relay.example.test/",
          addresses: ["192.168.1.5:4770"],
        },
        { id: "st_b" },
      ])
    );
    expect(t.stations.mesh.dials).toHaveLength(2);

    // It homed on another relay; the next connection goes there.
    t.api.open(eventsPath(WS))!.named("station", {
      id: "st_a",
      online: true,
      home_relay: "https://relay2.example.test/",
    });
    await t.time.pass(100);
    t.stations.mesh.cut("st_a");
    await t.time.pass(1_100);
    expect(links(value())).toEqual({ st_a: "online", st_b: "online" });
    expect(t.stations.mesh.dials.slice(2)).toEqual([
      { id: "st_a", relayUrl: "https://relay2.example.test/" },
    ]);
  });

  it("keeps a Salix relay socket for each shown workspace with stations, on a new ticket each time it opens", async () => {
    const t = setup({ salix: true });
    t.stations.station("st_a", WS);
    let tickets = 0;
    t.api.on("POST", relayPath(WS), () =>
      json(200, {
        ticket: `ticket-${++tickets}.secret`,
        url: "wss://api.example.test/v1/comma/station-relay",
      })
    );
    t.api.on("GET", listPath(WS), { stations: [station("st_a")] });
    const topic = { topic: "stations", workspace: WS };
    const value = t.watch<StationsValue>(topic);
    await t.time.pass(100);
    expect(links(value())).toEqual({ st_a: "online" });
    expect(t.stations.relaySockets).toEqual([
      expect.objectContaining({
        url: "wss://api.example.test/v1/comma/station-relay",
        ticket: "ticket-1.secret",
        open: true,
      }),
    ]);

    // Salix closed it: another opens with a new ticket, a second later.
    t.stations.relaySockets[0]!.drop();
    await t.time.pass(1_100);
    expect(t.stations.relaySockets.map((s) => [s.ticket, s.open])).toEqual([
      ["ticket-1.secret", false],
      ["ticket-2.secret", true],
    ]);

    // No station is listed any more: the socket closes and no other opens.
    t.api.on("GET", listPath(WS), { stations: [] });
    t.api.open(eventsPath(WS))!.named("stations", {});
    await t.time.pass(60_000, 10_000);
    expect(t.stations.relaySockets.map((s) => s.open)).toEqual([false, false]);
    expect(t.api.seen("POST", relayPath(WS))).toHaveLength(2);

    // A control plane without the client relay is asked once.
    const older = setup({ salix: true });
    older.stations.station("st_a", WS);
    older.api.on("POST", relayPath(WS), () => json(404, { error: "not_found" }));
    older.watch<StationsValue>(topic);
    await older.time.pass(60_000, 10_000);
    expect(older.api.seen("POST", relayPath(WS))).toHaveLength(1);
    expect(older.stations.relaySockets).toEqual([]);

    // An endpoint not reached through Salix asks no ticket.
    const direct = setup();
    direct.stations.station("st_a", WS);
    direct.watch<StationsValue>(topic);
    await direct.time.pass(100);
    expect(direct.api.seen("POST", relayPath(WS))).toHaveLength(0);
  });

  it("says how each open connection runs, as iroh moves it", async () => {
    const t = setup();
    t.stations.station("st_a", WS);
    t.api.on("GET", listPath(WS), { stations: [station("st_a")] });
    const value = t.watch<StationsValue>({ topic: "stations", workspace: WS });
    const link = () => value()!.stations[0]!.link;
    await t.time.pass(100);
    expect(link()).toEqual({ state: "online", via: "direct" });

    // The direct way went: through a relay, then Salix.
    t.stations.mesh.route("st_a", "relay");
    await t.time.pass(100);
    expect(link()).toEqual({ state: "online", via: "relay" });
    t.stations.mesh.route("st_a", "salix");
    await t.time.pass(100);
    expect(link()).toEqual({ state: "online", via: "salix" });

    // Gone: no way until it is open again, direct.
    t.stations.mesh.cut("st_a");
    await t.time.pass(100);
    expect(link()).toEqual({ state: "reconnecting" });
    await t.time.pass(1_000);
    expect(link()).toEqual({ state: "online", via: "direct" });
  });

  it("says a station it cannot reach, and tries again shortly", async () => {
    const t = setup();
    t.api.on("GET", listPath(WS), { stations: [station("st_gone")] });
    const value = t.watch<StationsValue>({ topic: "stations", workspace: WS });
    await t.time.pass(100);
    expect(value()!.stations[0]!.link).toMatchObject({ state: "offline" });
    expect(value()!.stations[0]!.link.message).toMatch(/st_gone/);
    // It comes up between tries: the next try finds it.
    t.stations.station("st_gone", WS);
    await t.time.pass(1_000);
    expect(links(value())).toEqual({ st_gone: "online" });
  });

  it("asks a credential again shortly before the one it has expires", async () => {
    const t = setup({ ttlSeconds: 120 });
    t.stations.station("st_a", WS);
    t.api.on("GET", listPath(WS), { stations: [station("st_a")] });
    const value = t.watch<StationsValue>({ topic: "stations", workspace: WS });
    await t.time.pass(100);
    expect(links(value())).toEqual({ st_a: "online" });
    await t.client.call("stations.toolsAccess", { workspace: WS, station: "st_a" });
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(1);
    // Within a minute of its expiry, the next request first gets a new one.
    await t.time.pass(61_000, 1_000);
    await t.client.call("stations.toolsAccess", { workspace: WS, station: "st_a" });
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(2);
  });

  it("gives a station that refuses the credential it kept a newly issued one, once", async () => {
    const t = setup();
    const a = t.stations.station("st_a", WS);
    t.api.on("GET", listPath(WS), { stations: [station("st_a")] });
    const value = t.watch<StationsValue>({ topic: "stations", workspace: WS });
    await t.time.pass(100);
    expect(links(value())).toEqual({ st_a: "online" });
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(1);

    // The control plane tells the workspace by a new id: the station takes credentials for that one only, and what
    // the control plane signs from now on names it. The credential this device keeps names the old one.
    a.takes = "grp_1";
    t.api.on("POST", credentialPath(WS), (request) =>
      json(200, {
        credential: fakeCredential({
          ws: "grp_1",
          device: (request.body as { device: string }).device,
          role: "owner",
          exp: Math.floor(t.time.now() / 1000) + 3_600,
        }),
        issued_at: Math.floor(t.time.now() / 1000),
        expires_at: Math.floor(t.time.now() / 1000) + 3_600,
        relay_urls: [],
      })
    );
    t.stations.mesh.cut();
    await t.time.pass(100);
    await t.time.pass(1_000);
    // Refused with the kept one, admitted with a new one, in the same try: no app restart, no second wait.
    expect(links(value())).toEqual({ st_a: "online" });
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(2);
    expect(a.admitted.map((c) => c.ws)).toEqual([WS, "grp_1"]);
    await t.client.call("stations.toolsAccess", { workspace: WS, station: "st_a" });
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(2);
  });

  it("asks one new credential, not one a try, of a station that refuses new ones too", async () => {
    const t = setup();
    const a = t.stations.station("st_a", WS);
    t.api.on("GET", listPath(WS), { stations: [station("st_a")] });
    const value = t.watch<StationsValue>({ topic: "stations", workspace: WS });
    await t.time.pass(100);
    expect(links(value())).toEqual({ st_a: "online" });

    // The station takes nothing the control plane signs for this workspace now.
    a.takes = "elsewhere";
    t.stations.mesh.cut();
    await t.time.pass(100);
    await t.time.pass(1_000);
    expect(value()!.stations[0]!.link).toMatchObject({ state: "offline" });
    expect(value()!.stations[0]!.link.message).toMatch(/another workspace/);
    // The kept one refused, a new one refused: two requests, and none for the tries after.
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(2);
    await t.time.pass(120_000, 1_000);
    expect(value()!.stations[0]!.link).toMatchObject({ state: "offline" });
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(2);
    await expect(
      t.client.call("stations.toolsAccess", { workspace: WS, station: "st_a" })
    ).rejects.toMatchObject({ code: "unreachable" });
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(2);

    // It takes this workspace's again: the credential kept is admitted at the next try, and the station is as any other.
    a.takes = WS;
    await t.time.pass(31_000, 1_000);
    expect(links(value())).toEqual({ st_a: "online" });
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(2);
  });

  it("reads and changes a station's tools access on the station; a viewer is refused in its words", async () => {
    const t = setup();
    const a = t.stations.station("st_a", WS);
    t.watch<StationsValue>({ topic: "stations", workspace: WS });
    await t.time.pass(100);
    expect(
      await t.client.call("stations.toolsAccess", { workspace: WS, station: "st_a" })
    ).toEqual({ access: "off" });
    expect(
      await t.client.call("stations.setToolsAccess", {
        workspace: WS,
        station: "st_a",
        access: "read",
      })
    ).toEqual({ access: "read" });
    expect(a.access).toBe("read");
    expect(a.asked).toEqual(["GET /tools/access", "PUT /tools/access"]);

    const viewer = setup({ role: "viewer" });
    viewer.stations.station("st_a", WS);
    viewer.watch<StationsValue>({ topic: "stations", workspace: WS });
    await viewer.time.pass(100);
    await expect(
      viewer.client.call("stations.setToolsAccess", {
        workspace: WS,
        station: "st_a",
        access: "full",
      })
    ).rejects.toMatchObject({
      code: "forbidden",
      message: "read-only members cannot change this station",
    });
  });

  it("enrolls, renames and removes stations at the control plane", async () => {
    const t = setup();
    t.stations.station("st_a", WS);
    t.stations.station("st_b", WS);
    t.api
      .on("POST", `${listPath(WS)}/enrollments`, {
        token: "enr_1",
        command: "curl -fsSL https://comma.test/stations/install.sh | sh -s -- enr_1",
        expires_at: 1_700_000_600,
      })
      .on("PATCH", `${listPath(WS)}/st_a`, station("st_a", { name: "Studio" }))
      .on("DELETE", `${listPath(WS)}/st_b`, {});
    const value = t.watch<StationsValue>({ topic: "stations", workspace: WS });
    await t.time.pass(100);
    expect(await t.client.call("stations.enroll", { workspace: WS })).toEqual({
      token: "enr_1",
      command: "curl -fsSL https://comma.test/stations/install.sh | sh -s -- enr_1",
      expiresAt: 1_700_000_600,
    });
    await t.client.call("stations.rename", {
      workspace: WS,
      station: "st_a",
      name: " Studio ",
    });
    expect(t.api.seen("PATCH", `${listPath(WS)}/st_a`)[0]!.body).toEqual({
      name: "Studio",
    });
    await t.time.pass(100);
    expect(value()!.stations[0]!.name).toBe("Studio");
    t.api.on("GET", listPath(WS), { stations: [station("st_a", { name: "Studio" })] });
    await t.client.call("stations.remove", { workspace: WS, station: "st_b" });
    await t.time.pass(100);
    expect(value()!.stations.map((s) => s.id)).toEqual(["st_a"]);
  });

  it("another account closes the endpoint and its connections, and asks its own credential", async () => {
    const t = setup();
    t.api.on("GET", listPath(OTHER), { stations: [] });
    t.stations.station("st_a", WS);
    const value = t.watch<StationsValue>({ topic: "stations", workspace: WS });
    await t.time.pass(100);
    expect(links(value())).toMatchObject({ st_a: "online" });
    expect(t.stations.bound).toHaveLength(1);

    t.core.observeSession(signedIn("user-2"));
    await t.time.pass(100);
    // The endpoint was bound again for the new account, with a credential of its own.
    expect(t.stations.bound).toHaveLength(2);
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(2);
    expect(t.api.seen("POST", credentialPath(WS))[1]!.lease.sessionId).toBe(
      "session-user-2"
    );
    expect(links(value())).toMatchObject({ st_a: "online" });
  });
  it("reaches its stations after a restart while the control plane answers nothing, with the stations and credential it kept", async () => {
    const t = setup();
    const a = t.stations.station("st_a", WS);
    t.stations.station("st_b", WS);
    const topic = { topic: "stations", workspace: WS };
    t.watch<StationsValue>(topic);
    await t.time.pass(100);
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(1);
    t.core.close();
    await t.time.pass(100);

    controlPlaneDown(t.api);
    const requests = t.api.requests.length;
    const again = start(t.host);
    const value = again.watch<StationsValue>(topic);
    await t.time.pass(100);
    // The stations as kept, each reached with the credential kept: no credential was asked for.
    expect(value()!.stations.map((s) => s.id)).toEqual(["st_a", "st_b"]);
    expect(links(value())).toEqual({ st_a: "online", st_b: "online" });
    expect(
      await again.client.call("stations.toolsAccess", {
        workspace: WS,
        station: "st_a",
      })
    ).toEqual({ access: "off" });
    expect(t.api.requests.length).toBeGreaterThan(requests);
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(1);
    // The same endpoint (its key is the device's), admitted with the one credential issued before the restart.
    expect(t.stations.bound).toHaveLength(2);
    expect(t.stations.bound[1]!.id).toBe(t.stations.bound[0]!.id);
    expect(a.admitted.length).toBeGreaterThan(1);
    expect(new Set(a.admitted.map((c) => JSON.stringify(c))).size).toBe(1);
  });

  it("does not give a kept credential once it expired by the core's clock: it asks a new one", async () => {
    // The station's clock is behind: it would still take the kept one.
    const t = setup({ ttlSeconds: 3_600, stationClock: () => 0 });
    const a = t.stations.station("st_a", WS);
    t.api.on("GET", listPath(WS), { stations: [station("st_a")] });
    await t.client.call("stations.toolsAccess", { workspace: WS, station: "st_a" });
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(1);
    t.core.close();

    // The core starts again past the kept credential's expiry.
    await t.time.pass(3_600_000);
    const again = start(t.host);
    await again.client.call("stations.toolsAccess", { workspace: WS, station: "st_a" });
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(2);
    const [first, second] = a.admitted;
    expect(a.admitted).toHaveLength(2);
    expect(second!.exp).toBeGreaterThan(first!.exp);
    expect(second!.exp * 1000).toBeGreaterThan(t.time.now());
  });

  it("drops a kept credential a station refused: the next start asks a new one instead of giving it again", async () => {
    const t = setup();
    const a = t.stations.station("st_a", WS);
    t.api.on("GET", listPath(WS), { stations: [station("st_a")] });
    await t.client.call("stations.toolsAccess", { workspace: WS, station: "st_a" });
    expect(a.admitted).toHaveLength(1);

    // The station refuses the kept credential, and the control plane issues none now.
    a.takes = "elsewhere";
    t.stations.mesh.cut();
    t.api.on("POST", credentialPath(WS), offline());
    await expect(
      t.client.call("stations.toolsAccess", { workspace: WS, station: "st_a" })
    ).rejects.toMatchObject({ code: "network" });
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(2);
    t.core.close();
    await t.time.pass(1_000);

    a.takes = WS;
    t.issuing(WS);
    const again = start(t.host);
    await again.client.call("stations.toolsAccess", { workspace: WS, station: "st_a" });
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(3);
    expect(a.admitted).toHaveLength(2);
    expect(a.admitted[1]).not.toEqual(a.admitted[0]);
  });

  it("signing out deletes the stations and credential kept: another account on the device has none of them", async () => {
    const t = setup();
    t.stations.station("st_a", WS);
    t.watch<StationsValue>({ topic: "stations", workspace: WS });
    await t.time.pass(100);
    expect(t.api.seen("POST", credentialPath(WS))).toHaveLength(1);
    const kept = [...t.host.dbs.keys()];

    t.core.observeSession(signedOut());
    await t.time.pass(100);
    expect(t.host.deleted).toEqual(kept);
    t.core.close();

    // Another account, while the list does not answer: no station shows, and it asks a credential of its own.
    t.api.on("GET", listPath(WS), offline());
    const other = start(t.host, "user-2");
    const value = other.watch<StationsValue>({ topic: "stations", workspace: WS });
    await t.time.pass(100);
    expect(value()).toMatchObject({ stations: [], error: expect.any(String) });
    await other.client.call("stations.toolsAccess", { workspace: WS, station: "st_a" });
    expect(
      t.api.seen("POST", credentialPath(WS)).map((r) => r.lease.sessionId)
    ).toEqual(["session-user-1", "session-user-2"]);
  });
});
