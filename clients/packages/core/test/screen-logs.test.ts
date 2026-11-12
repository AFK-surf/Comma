// A device's app logs through the core (screen-logs.ts), over the memory mesh, to a fake station: lines reach the page
// as progress, the newest are kept for what sends an agent the screen (`devices.screenLogTail`), the call's end ends
// the station's stream, and a station from before says it has none.
import { CoreClient } from "@comma/core-kernel/client";
import { ScreenKind, encodeScreenJson, type MeshReply } from "@comma/mesh";
import { describe, expect, it } from "vitest";
import type { ScreenLogEvent } from "../src/contract.ts";
import { TAIL } from "../src/screen-logs.ts";
import {
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
const device = (station: string | null) => ({
  device_id: DEVICE,
  name: "Mac",
  status: "connected",
  allows_operations: true,
  device_runtimes: [],
  ...(station ? { station_id: station } : {}),
});

function setup(
  options: {
    desktop?: boolean;
    salixOnly?: boolean;
    station?: string | null;
    /** The mesh does not reach the station. */
    unreached?: boolean;
  } = {}
) {
  const host = new FakeHost();
  const stations = new FakeStations(() => host.time!.now());
  host.stationMesh =
    options.desktop === false
      ? stations.ports
      : {
          ...stations.ports,
          alwaysLinked: true,
          ownComputers: true,
          ...(options.salixOnly ? { salixOnly: true } : {}),
        };
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
    .on(
      "GET",
      `/v1/comma/workspaces/${WS}/devices/${DEVICE}`,
      device(options.station === undefined ? STATION : options.station)
    )
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
  const station = options.unreached
    ? (null as unknown as ReturnType<typeof stations.station>)
    : stations.station(STATION, WS);
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn("user-1"));
  const time = host.time!;
  /** Lets what is under way finish, as a step of the test's clock. */
  const until = async (what: () => boolean, why: string) => {
    for (let i = 0; i < 50 && !what(); i++) await time.pass(1);
    if (!what()) throw new Error(`never: ${why}`);
  };
  return { host, client, station, core, until, settled: () => time.pass(100) };
}

const SCREEN = "simulator:A119A827-41D5-49E0-9689-710DB19BF30E";
const nothing = () => undefined;

/** A station that answers a device's logs with the frames the test sends, and notes when the page's stream ends. */
function logs(station: ReturnType<typeof setup>["station"]) {
  const asked: string[] = [];
  let push: (bytes: Uint8Array) => void = nothing;
  let end: () => void = nothing;
  let gone = false;
  const fallback = station.handle.bind(station);
  station.handle = async (request): Promise<MeshReply> => {
    if (!request.path.includes("/logs")) return fallback(request);
    asked.push(`${request.method} ${request.path}`);
    void (async () => {
      for await (const _ of request.body) void _;
      gone = true;
    })().catch(() => (gone = true));
    const queue: Uint8Array[] = [];
    let wake: () => void = nothing;
    let ended = false;
    push = (bytes) => {
      queue.push(bytes);
      wake();
    };
    end = () => {
      ended = true;
      wake();
    };
    return {
      status: 200,
      body: (async function* () {
        for (;;) {
          const next = queue.shift();
          if (next) yield next;
          else if (ended) return;
          else await new Promise<void>((resolve) => (wake = resolve));
        }
      })(),
    };
  };
  const state = (value: unknown) => push(encodeScreenJson(ScreenKind.state, value));
  return { asked, state, end: () => end(), gone: () => gone };
}

const line = (seq: number, more: Record<string, unknown> = {}) => ({
  seq,
  at: "",
  level: "Info",
  app: "LogDemo",
  text: `line ${seq}`,
  ...more,
});

function read(client: CoreClient, mode = "app") {
  const events: ScreenLogEvent[] = [];
  const stop = new AbortController();
  const answer = client.call(
    "devices.openScreenLogs",
    { workspace: WS, device: DEVICE, screen: SCREEN, instance: "i1", mode },
    (value) => events.push(value as ScreenLogEvent),
    stop.signal
  );
  answer.catch(() => undefined);
  return { events, stop, answer };
}

describe("a device's app logs over the mesh", () => {
  it("sends none of what was cleared, though the station gives it again; later lines are kept", async () => {
    const { client, station, until, settled } = setup();
    const served = logs(station);
    await settled();
    const { events, stop } = read(client);
    await until(() => served.asked.length > 0, "the station is asked");
    served.state({ logs: { mode: "app" } });
    served.state({ lines: [line(0), line(1)] });
    await until(() => events.length === 2, "the lines come");
    const screen = { workspace: WS, device: DEVICE, screen: SCREEN };
    const tail = () =>
      (
        client.call("devices.screenLogTail", screen) as Promise<{
          lines: { seq: number }[];
        }>
      ).then((answer) => answer.lines.map((l) => l.seq));
    expect(await tail()).toEqual([0, 1]);

    await client.call("devices.clearScreenLogTail", screen);
    expect(await tail()).toEqual([]);

    served.state({ lines: [line(1), line(2)] });
    await until(() => events.length === 3, "a reader that joins is given them again");
    expect(await tail()).toEqual([2]);
    stop.abort();
  });

  it("brings the filter and the lines as progress, keeps the newest for an agent, and ends the station's stream with the call", async () => {
    const { client, station, until, settled } = setup();
    const served = logs(station);
    await settled();
    const { events, stop, answer } = read(client);
    await until(() => served.asked.length > 0, "the station is asked");
    expect(served.asked[0]).toBe(
      `POST /screens/${encodeURIComponent(SCREEN)}/logs?mode=app&instance=i1`
    );
    served.state({ logs: { mode: "app" } });
    served.state({
      lines: [line(0), line(1, { crash: true, level: "Default" })],
      dropped: 3,
    });
    served.state({ lines: [{ seq: "bad" }, line(2)] });
    await until(() => events.length === 3, "the lines come");
    expect(events[0]).toEqual({ type: "filter", mode: "app" });
    expect(events[1]).toEqual({
      type: "lines",
      lines: [line(0), line(1, { crash: true, level: "Default" })],
      dropped: 3,
    });
    // A line that is not one is left out.
    expect(events[2]).toEqual({ type: "lines", lines: [line(2)] });

    const tail = (lines?: number) =>
      client.call("devices.screenLogTail", {
        workspace: WS,
        device: DEVICE,
        screen: SCREEN,
        ...(lines !== undefined ? { lines } : {}),
      }) as Promise<{ lines: { seq: number }[] }>;
    expect((await tail(2)).lines.map((l) => l.seq)).toEqual([1, 2]);
    served.state({ lines: Array.from({ length: TAIL + 20 }, (_, i) => line(3 + i)) });
    await until(() => events.length === 4, "more lines");
    const all = (await tail(10_000)).lines;
    expect(all).toHaveLength(TAIL);
    expect(all.at(-1)!.seq).toBe(TAIL + 22);

    stop.abort();
    await until(() => served.gone(), "the station's stream ends");
    await expect(answer).rejects.toMatchObject({ code: "cancelled" });
    // Kept after the pane closed, for what sends it to an agent.
    expect((await tail(1)).lines.map((l) => l.seq)).toEqual([TAIL + 22]);
  });

  it("keeps each filter's lines apart: App and All count from 0 each", async () => {
    const { client, station, until, settled } = setup();
    const served = logs(station);
    await settled();
    const app = read(client, "app");
    await until(() => served.asked.length === 1, "App is asked");
    served.state({ logs: { mode: "app" } });
    served.state({ lines: [line(0, { text: "app 0" }), line(1, { text: "app 1" })] });
    await until(() => app.events.length === 2, "App's lines");
    app.stop.abort();
    const all = read(client, "all");
    await until(() => served.asked.length === 2, "All is asked");
    served.state({ logs: { mode: "all" } });
    served.state({ lines: [line(0, { text: "all 0" }), line(1, { text: "all 1" })] });
    await until(() => all.events.length === 2, "All's lines");
    const tail = (more: Record<string, unknown> = {}) =>
      (
        client.call("devices.screenLogTail", {
          workspace: WS,
          device: DEVICE,
          screen: SCREEN,
          ...more,
        }) as Promise<{ lines: { text: string }[] }>
      ).then((answer) => answer.lines.map((l) => l.text));
    // The one read last, unless another is named; never the two mixed.
    expect(await tail()).toEqual(["all 0", "all 1"]);
    expect(await tail({ mode: "app" })).toEqual(["app 0", "app 1"]);
    all.stop.abort();
  });

  it("fails with why the station ended it", async () => {
    const { client, station, until, settled } = setup();
    const served = logs(station);
    await settled();
    const { answer } = read(client);
    await until(() => served.asked.length > 0, "the station is asked");
    served.state({ logs: { mode: "app" } });
    served.state({ ended: "the device is gone" });
    served.end();
    await expect(answer).rejects.toMatchObject({
      code: "screen_ended",
      message: "the device is gone",
    });
  });

  it("says a station from before has no app logs", async () => {
    const { client, station, settled } = setup();
    // (as one from before answers a path it does not serve the owner over the mesh, its body not read)
    const fallback = station.handle.bind(station);
    station.handle = async (request): Promise<MeshReply> =>
      request.path.includes("/logs")
        ? json(403, { error: "not served to this computer over the mesh" })
        : fallback(request);
    await settled();
    const { answer } = read(client);
    await expect(answer).rejects.toMatchObject({ code: "unsupported" });
  });
});
