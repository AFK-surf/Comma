// What debugs an app on a device through the core (screen-debug.ts), over the memory mesh, to a fake station: each action
// names the boot picked, a picture and a movie are saved into Downloads as they come, a file goes up in parts, and a
// refusal is the station's own words.
import { CoreClient } from "@comma/core-kernel/client";
import type { MeshReply } from "@comma/mesh";
import { describe, expect, it } from "vitest";
import {
  FakeDesktop,
  FakeHost,
  FakeStations,
  fakeCredential,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const WS = "wsp_1";
const STATION = "st_a";
const DEVICE = "dev_1";
const listPath = `/v1/comma/workspaces/${WS}/stations`;
const SCREEN = "simulator:A119A827-41D5-49E0-9689-710DB19BF30E";
const target = { workspace: WS, device: DEVICE, screen: SCREEN, instance: "i1" };

function setup() {
  const host = new FakeHost();
  const stations = new FakeStations(() => host.time!.now());
  host.stationMesh = { ...stations.ports, alwaysLinked: true, ownComputers: true };
  const desktop = new FakeDesktop();
  host.desktop = desktop;
  const seconds = () => Math.floor(host.time!.now() / 1000);
  host.api
    .on("GET", "/v1/comma/stations/me", {
      user: { id: "user-1", email: "a@example.test", name: "Ada" },
      workspaces: [{ id: WS, name: "Main", role: "owner" }],
      relay_urls: [],
    })
    .on("GET", listPath, {
      stations: [
        {
          id: STATION,
          name: STATION,
          version: "1",
          online: true,
          enrolled_at: 1,
          enrolled_by: "u",
        },
      ],
    })
    .onStream(`${listPath}/events`)
    .on("GET", "/v1/comma/workspaces", {
      data: [{ id: WS, group_id: "grp_1", name: "Main", status: "ready" }],
    })
    .on("GET", `/v1/comma/workspaces/${WS}/devices/${DEVICE}`, {
      device_id: DEVICE,
      name: "Mac",
      status: "connected",
      allows_operations: true,
      device_runtimes: [],
      station_id: STATION,
    })
    .on("POST", `/v1/comma/workspaces/${WS}/station-credential`, (request) => {
      const exp = seconds() + 3600;
      return json(200, {
        credential: fakeCredential({
          ws: WS,
          device: (request.body as { device: string }).device,
          role: "owner",
          exp,
        }),
        issued_at: seconds(),
        expires_at: exp,
        relay_urls: [],
      });
    });
  const station = stations.station(STATION, WS);
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn("user-1"));
  const time = host.time!;
  const asked: { path: string; body: number[] }[] = [];
  const answers = new Map<string, () => MeshReply>();
  const fallback = station.handle.bind(station);
  station.handle = async (request): Promise<MeshReply> => {
    const action = /\/debug\/([a-z-]+)\?/.exec(request.path)?.[1];
    if (!action) return fallback(request);
    const body: number[] = [];
    for await (const chunk of request.body) body.push(...chunk);
    asked.push({ path: request.path, body });
    return answers.get(action)!();
  };
  const settled = () => time.pass(100);
  return { client, desktop, asked, answers, settled, time };
}

const called = async <T>(s: ReturnType<typeof setup>, call: Promise<T>): Promise<T> => {
  call.catch(() => undefined);
  await s.settled();
  return call;
};
const said = (value: unknown): MeshReply => ({
  status: 200,
  headers: [["content-type", "application/json"]],
  body: Buffer.from(JSON.stringify(value)),
});

describe("what debugs an app over the mesh", () => {
  it("names the action and the boot, and answers what the station said", async () => {
    const s = setup();
    await s.settled();
    s.answers.set("restart", () => said({ app: "fail.still.a", name: "Alpha" }));
    s.answers.set("appearance", () => said({ appearance: "dark" }));
    s.answers.set("record", () => said({ recording: true }));
    expect(
      await called(
        s,
        s.client.call("devices.screenDebug", { ...target, action: "restart" })
      )
    ).toEqual({ app: "fail.still.a", name: "Alpha" });
    expect(s.asked[0]!.path).toBe(
      `/screens/${encodeURIComponent(SCREEN)}/debug/restart?instance=i1`
    );
    await called(
      s,
      s.client.call("devices.screenDebug", {
        ...target,
        action: "appearance",
        value: "dark",
      })
    );
    expect(s.asked.at(-1)!.path).toMatch(/debug\/appearance\?instance=i1&value=dark$/);
    await called(
      s,
      s.client.call("devices.screenDebug", {
        ...target,
        action: "record",
        panel: "inner",
      })
    );
    expect(s.asked.at(-1)!.path).toMatch(/debug\/record\?instance=i1&panel=inner$/);
  });

  it("says why when the station refuses, as a watcher is refused", async () => {
    const s = setup();
    await s.settled();
    s.answers.set("restart", () => ({
      status: 403,
      headers: [["content-type", "application/json"]],
      body: Buffer.from(
        JSON.stringify({ error: "only a view in Control may do that" })
      ),
    }));
    await expect(
      called(s, s.client.call("devices.screenDebug", { ...target, action: "restart" }))
    ).rejects.toMatchObject({
      code: "forbidden",
      message: "only a view in Control may do that",
    });
  });

  it("saves a picture into Downloads and gives its bytes for the chat", async () => {
    const s = setup();
    await s.settled();
    s.answers.set("screenshot", () => ({
      status: 200,
      headers: [["content-type", "image/png"]],
      body: Buffer.from([1, 2, 3]),
    }));
    const answer = (await called(
      s,
      s.client.call("devices.saveScreenPicture", { ...target, name: "shot.png" })
    )) as { png: Uint8Array; saved: { fileName: string } };
    expect([...answer.png]).toEqual([1, 2, 3]);
    expect(answer.saved.fileName).toBe("shot.png");
    expect([...s.desktop.saved[0]!.content]).toEqual([1, 2, 3]);
  });

  it("writes a movie into Downloads as it comes", async () => {
    const s = setup();
    await s.settled();
    s.answers.set("record-stop", () => ({
      status: 200,
      headers: [["content-type", "video/mp4"]],
      body: (async function* () {
        yield new Uint8Array([1, 2]);
        yield new Uint8Array([3]);
      })(),
    }));
    expect(
      await called(
        s,
        s.client.call("devices.saveScreenRecording", { ...target, name: "movie.mp4" })
      )
    ).toMatchObject({ fileName: "movie.mp4" });
    expect([...s.desktop.saved[0]!.content]).toEqual([1, 2, 3]);
  });

  it("leaves nothing in Downloads when the station says no movie", async () => {
    const s = setup();
    await s.settled();
    s.answers.set("record-stop", () => ({
      status: 404,
      headers: [["content-type", "application/json"]],
      body: Buffer.from(JSON.stringify({ error: "nothing is being recorded" })),
    }));
    await expect(
      called(
        s,
        s.client.call("devices.saveScreenRecording", { ...target, name: "movie.mp4" })
      )
    ).rejects.toMatchObject({ code: "http_404" });
    expect(s.desktop.saved).toEqual([]);
  });

  it("sends an app up as a file", async () => {
    const s = setup();
    await s.settled();
    s.answers.set("install", () => said({ app: "fail.still.demo" }));
    expect(
      await called(
        s,
        s.client.call("devices.installScreenApp", {
          ...target,
          name: "Demo.ipa",
          bytes: new Uint8Array([9, 8, 7]),
        })
      )
    ).toEqual({ app: "fail.still.demo" });
    expect(s.asked[0]!.path).toMatch(/debug\/install\?instance=i1&name=Demo\.ipa$/);
    expect(s.asked[0]!.body).toEqual([9, 8, 7]);
  });
});
