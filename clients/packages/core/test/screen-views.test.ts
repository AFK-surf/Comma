// A view of a computer's screen through the core (screen-views.ts), over the memory mesh, to a fake station: only a desktop
// app takes this way, a station that does not list the screen is never sent the view's stream, frames reach the page as
// they come with their bytes, and what the page says reaches the station for as long as the view runs.
import { CoreClient } from "@comma/core-kernel/client";
import {
  ScreenFrameReader,
  SCREEN_AUDIO,
  ScreenKind,
  clipPayload,
  encodeScreenAudio,
  encodeScreenFrame,
  encodeScreenJson,
  encodeScreenVideo,
  parseClip,
  parseScreenSound,
  parseScreenAck,
  parseScreenAckTiming,
  parseScreenControl,
  parseScreenReceived,
  type MeshReply,
} from "@comma/mesh";
import { describe, expect, it } from "vitest";
import type { ScreenViewEvent } from "../src/contract.ts";
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
    /** A phone's mesh: own computers reached, but stations linked only while something holds them. */
    phone?: boolean;
    salixOnly?: boolean;
    station?: string | null;
    /** The mesh does not reach the station. */
    unreached?: boolean;
    /** The app's own decoder for views opened with a `sink` (the phones'). */
    screenFrames?: {
      frame(
        sink: number,
        kind: number,
        ts: number,
        width: number,
        height: number,
        bytes: Uint8Array
      ): void;
    };
    /** False: the run is not played again (a test where the computer sleeps, which a replay's clock cannot). */
    replays?: boolean;
  } = {}
) {
  const host = new FakeHost();
  const stations = new FakeStations(() => host.time!.now());
  host.stationMesh =
    options.desktop === false
      ? stations.ports
      : options.phone
        ? { ...stations.ports, ownComputers: true }
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
  if (options.screenFrames) host.screenFrames = options.screenFrames;
  const station = options.unreached
    ? (null as unknown as ReturnType<typeof stations.station>)
    : stations.station(STATION, WS);
  const core = startTestCore(host, options.replays === false ? { replays: false } : {});
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
  return {
    host,
    client,
    station,
    stations,
    core,
    until,
    settled: () => time.pass(100),
  };
}

const params = { workspace: WS, device: DEVICE, target: "display", control: true };

function open(client: CoreClient, asked: Record<string, unknown> = params) {
  const events: ScreenViewEvent[] = [];
  const stop = new AbortController();
  const answer = client.call(
    "devices.openScreenView",
    asked,
    (value) => events.push(value as ScreenViewEvent),
    stop.signal
  );
  return { events, stop, answer };
}

const nothing = () => undefined;

/** What a station's view does: lists the screen, answers a view with frames the test sends, keeps what comes back. */
function screens(
  station: ReturnType<typeof setup>["station"],
  listed: Record<string, unknown>[] = [{ id: "display" }]
) {
  const said: { kind: number; payload: Uint8Array }[] = [];
  const asked: string[] = [];
  let push: (bytes: Uint8Array) => void = nothing;
  let end: () => void = nothing;
  let gone = false;
  station.on("GET", "/screens", () => json(200, { screens: listed, codecs: ["h264"] }));
  const fallback = station.handle.bind(station);
  station.handle = async (request): Promise<MeshReply> => {
    if (!request.path.endsWith("/view")) return fallback(request);
    asked.push(
      `${request.method} ${request.path} ${request.headers.map(([k, v]) => `${k}=${v}`).join()}`
    );
    const reader = new ScreenFrameReader(16 << 20);
    void (async () => {
      for await (const chunk of request.body) said.push(...reader.push(chunk));
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
  return {
    said,
    asked,
    push: (b: Uint8Array) => push(b),
    end: () => end(),
    gone: () => gone,
  };
}

describe("a screen's view over the mesh", () => {
  it("asks the 画质 chosen: one the station knows, none for 自动, another or a preview", async () => {
    const { client, station, until, settled } = setup();
    const view = screens(station);
    await settled();
    const asks = [
      { quality: "hd" },
      { quality: "original" },
      { quality: "best" },
      {},
      { quality: "smooth", peek: true },
    ];
    for (const [i, extra] of asks.entries()) {
      const { stop, answer } = open(client, { ...params, control: false, ...extra });
      answer.catch(() => undefined);
      await until(() => view.asked.length === i + 1, "the view is asked");
      stop.abort();
      await settled();
    }
    const said = view.asked.map((line) => /"quality":"(\w+)"/.exec(line)?.[1]);
    expect(said).toEqual(["hd", "original", undefined, undefined, undefined]);
  });

  it("keeps the 画质 with the account on this device: chosen, read back, 自动 again, another account's its own", async () => {
    const { core, client, settled } = setup();
    let value: unknown;
    client.subscribe(
      { topic: "screenQuality" },
      (v) => (value = v),
      () => undefined
    );
    await settled();
    expect(value).toEqual({ quality: null });
    await client.call("devices.chooseScreenQuality", { quality: "original" });
    await settled();
    expect(value).toEqual({ quality: "original" });
    await expect(
      client.call("devices.chooseScreenQuality", { quality: "best" as "hd" })
    ).rejects.toMatchObject({ code: "invalid_params" });
    expect(value).toEqual({ quality: "original" });
    await client.call("devices.chooseScreenQuality", { quality: null });
    await settled();
    expect(value).toEqual({ quality: null });
    await client.call("devices.chooseScreenQuality", { quality: "smooth" });
    await settled();
    expect(value).toEqual({ quality: "smooth" });
    // Another account on this device has its own: 自动 until it chooses.
    core.observeSession(signedIn("user-2"));
    await settled();
    expect(value).toEqual({ quality: null });
  });

  it("brings frames to the page with their bytes, and takes acknowledgements and input back", async () => {
    const { client, station, until, settled } = setup();
    const view = screens(station);
    await settled();
    const { events, stop, answer } = open(client);
    answer.catch(() => undefined);
    await until(() => events.length > 0, "the view opens");
    expect(events[0]).toMatchObject({ type: "open" });
    expect(view.asked[0]).toContain("POST /screens/display/view");
    expect(view.asked[0]).toContain('"control":true');
    const id = (events[0] as { view: number }).view;

    view.push(
      encodeScreenJson(ScreenKind.config, {
        codec: "h264",
        width: 64,
        height: 48,
        description: "AQ==",
      })
    );
    const frame = encodeScreenVideo(true, 2 ** 40, new Uint8Array(100_000).fill(9));
    // Cut across chunks, as a stream may.
    view.push(frame.subarray(0, 7));
    view.push(frame.subarray(7));
    await until(() => events.length === 3, "the frame comes");
    expect(events[1]).toEqual({
      type: "config",
      codec: "h264",
      width: 64,
      height: 48,
      description: "AQ==",
    });
    const video = events[2] as Extract<ScreenViewEvent, { type: "video" }>;
    expect([video.key, video.ts, video.data.length]).toEqual([true, 2 ** 40, 100_000]);
    expect(video.data.every((byte) => byte === 9)).toBe(true);
    // Its own bytes alone: a port would clone a larger buffer whole.
    expect(video.data.buffer.byteLength).toBe(100_000);

    void client.call("devices.sendToScreenView", { view: id, ack: 2 ** 40 });
    void client.call("devices.sendToScreenView", { view: id, keyframe: true });
    void client.call("devices.sendToScreenView", {
      view: id,
      input: { type: "move", x: 0.5, y: 0.5, mods: [] },
    });
    await until(() => view.said.length === 3, "the station hears them");
    expect(parseScreenAck(view.said[0]!.payload)).toBe(2 ** 40);
    expect(view.said[1]!.kind).toBe(ScreenKind.keyframe);
    expect(JSON.parse(new TextDecoder().decode(view.said[2]!.payload)).type).toBe(
      "move"
    );

    stop.abort();
    await until(() => view.gone(), "the station's stream ends");
    await expect(answer).rejects.toMatchObject({ code: "cancelled" });
    // Over: nothing more goes.
    void client.call("devices.sendToScreenView", { view: id, ack: 1 });
    await settled();
    expect(view.said.length).toBe(3);
  });

  it("hands a phone's own decoder its configs and frames as numbers and bytes, not as progress", async () => {
    const got: {
      sink: number;
      kind: number;
      ts: number;
      width: number;
      height: number;
      bytes: number[];
    }[] = [];
    const { client, station, until, settled } = setup({
      screenFrames: {
        frame: (sink, kind, ts, width, height, bytes) =>
          got.push({ sink, kind, ts, width, height, bytes: [...bytes] }),
      },
    });
    const view = screens(station);
    await settled();
    const { events, stop, answer } = open(client, { ...params, sink: 7 });
    answer.catch(() => undefined);
    await until(() => events.length > 0, "the view opens");
    view.push(
      encodeScreenJson(ScreenKind.config, {
        codec: "h265",
        width: 64,
        height: 48,
        description: "AQID",
      })
    );
    view.push(encodeScreenVideo(true, 2 ** 40, new Uint8Array([9, 8, 7])));
    view.push(encodeScreenVideo(false, 2 ** 40 + 1, new Uint8Array([6])));
    view.push(encodeScreenJson(ScreenKind.state, { control: true }));
    await until(
      () => got.length === 3 && events.length === 2,
      "the frames and the state come"
    );
    expect(got).toEqual([
      { sink: 7, kind: 2, ts: 0, width: 64, height: 48, bytes: [1, 2, 3] },
      { sink: 7, kind: 4, ts: 2 ** 40, width: 0, height: 0, bytes: [9, 8, 7] },
      { sink: 7, kind: 3, ts: 2 ** 40 + 1, width: 0, height: 0, bytes: [6] },
    ]);
    // Only what is not a picture comes as progress.
    expect(events.map((e) => e.type)).toEqual(["open", "state"]);
    stop.abort();
    await until(() => view.gone(), "the station's stream ends");
  });

  it("tells a station that logs its frames' times when each came whole, and the times each acknowledgement went by", async () => {
    const { client, station, until, settled, host } = setup();
    const view = screens(station);
    await settled();
    const { events, stop, answer } = open(client);
    answer.catch(() => undefined);
    await until(() => events.length > 0, "the view opens");
    const id = (events[0] as { view: number }).view;

    // Before its state asks: no receipt, and an acknowledgement as before.
    view.push(encodeScreenVideo(true, 1, new Uint8Array(10)));
    await until(() => events.length === 2, "the frame comes");
    void client.call("devices.sendToScreenView", {
      view: id,
      ack: 1,
      timing: { decodeOut: 3 },
    });
    await until(() => view.said.length === 1, "the station hears it");
    expect(view.said[0]!.kind).toBe(ScreenKind.ack);
    expect(parseScreenAckTiming(view.said[0]!.payload)).toBeNull();

    view.push(encodeScreenJson(ScreenKind.state, { control: true, timing: true }));
    view.push(encodeScreenVideo(false, 2, new Uint8Array(10)));
    await until(() => view.said.length === 2, "the receipt comes");
    expect(view.said[1]!.kind).toBe(ScreenKind.received);
    expect(parseScreenReceived(view.said[1]!.payload)).toBe(2);
    await host.time!.pass(40);
    void client.call("devices.sendToScreenView", {
      view: id,
      ack: 2,
      timing: { decodeIn: 0.5, decodeOut: 30.25, shown: 30.5, ack: 31, bogus: 1 },
    });
    await until(() => view.said.length === 3, "the acknowledgement comes");
    expect(parseScreenAck(view.said[2]!.payload)).toBe(2);
    const timing = parseScreenAckTiming(view.said[2]!.payload)!;
    // (`held`: on the core's clock, from the frame whole to its acknowledgement, at least the 40 ms passed)
    expect(timing).toMatchObject({
      decodeIn: 0.5,
      decodeOut: 30.25,
      shown: 30.5,
      ack: 31,
    });
    expect(timing.held).toBeGreaterThanOrEqual(40);
    stop.abort();
  });

  it("carries the screen's clipboard both ways and its system output, as the station lists and sends them", async () => {
    const { client, station, until, settled } = setup();
    const view = screens(station, [
      { id: "display", clipboard: ["text", "png", "rtf"] },
    ]);
    await settled();
    const { events, stop, answer } = open(client, { ...params, audio: true });
    answer.catch(() => undefined);
    await until(() => events.length > 0, "the view opens");
    // The types it listed that a page knows; the system output asked of the station.
    expect(events[0]).toMatchObject({ type: "open", clipboard: ["text", "png"] });
    expect(view.asked[0]).toContain('"audio":"pcm_s16le"');
    const id = (events[0] as { view: number }).view;

    const pcm = new Uint8Array(3840).fill(3);
    view.push(
      encodeScreenFrame(
        ScreenKind.clipboard,
        clipPayload({ type: "text", text: "复制的" })
      )
    );
    view.push(encodeScreenJson(ScreenKind.audioConfig, SCREEN_AUDIO));
    view.push(encodeScreenAudio(40_000, pcm));
    // A packet that is not one, and a format it does not carry, reach the page as nothing.
    view.push(encodeScreenFrame(ScreenKind.audio, new Uint8Array(12)));
    await until(() => events.length === 4, "they come");
    expect(events.slice(1, 3)).toEqual([
      { type: "clipboard", clip: { type: "text", text: "复制的" } },
      { type: "audioConfig", codec: "pcm_s16le" },
    ]);
    const audio = events[3] as Extract<ScreenViewEvent, { type: "audio" }>;
    expect([audio.type, audio.ts, audio.data.length, audio.data[0]]).toEqual([
      "audio",
      40_000,
      3840,
      3,
    ]);
    expect(audio.data.buffer.byteLength).toBe(3840);

    const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
    void client.call("devices.sendToScreenView", {
      view: id,
      clipboard: { type: "text", text: "粘贴的" },
      paste: true,
    });
    void client.call("devices.sendToScreenView", {
      view: id,
      clipboard: { type: "png", data: png },
    });
    // Nothing of an empty text.
    void client.call("devices.sendToScreenView", {
      view: id,
      clipboard: { type: "text", text: "" },
    });
    await until(() => view.said.length === 2, "the station hears them");
    await settled();
    expect(view.said.map((frame) => frame.kind)).toEqual([
      ScreenKind.setClipboard,
      ScreenKind.setClipboard,
    ]);
    expect(view.said.map((frame) => parseClip(frame.payload))).toEqual([
      { clip: { type: "text", text: "粘贴的" }, paste: true },
      { clip: { type: "png", data: png }, paste: false },
    ]);
    stop.abort();
  });

  it("asks Opus for a page that decodes it, passes its packets as they are, and turns a view's sound off and on", async () => {
    const { client, station, until, settled } = setup();
    const view = screens(station);
    await settled();
    const { events, stop, answer } = open(client, { ...params, audio: "opus" });
    answer.catch(() => undefined);
    await until(() => events.length > 0, "the view opens");
    expect(view.asked[0]).toContain('"audio":"opus"');
    const id = (events[0] as { view: number }).view;
    view.push(
      encodeScreenJson(ScreenKind.audioConfig, { ...SCREEN_AUDIO, codec: "opus" })
    );
    view.push(encodeScreenAudio(60_000, new Uint8Array(180).fill(9)));
    await until(() => events.length === 3, "they come");
    expect(events[1]).toEqual({ type: "audioConfig", codec: "opus" });
    const audio = events[2] as Extract<ScreenViewEvent, { type: "audio" }>;
    expect([audio.ts, audio.data.length, audio.data[0]]).toEqual([60_000, 180, 9]);

    void client.call("devices.sendToScreenView", { view: id, sound: false });
    void client.call("devices.sendToScreenView", { view: id, sound: true });
    await until(() => view.said.length === 2, "the station hears them");
    expect(
      view.said.map((frame) => [frame.kind, parseScreenSound(frame.payload)])
    ).toEqual([
      [ScreenKind.sound, false],
      [ScreenKind.sound, true],
    ]);
    stop.abort();
  });

  it("asks no system output of a preview, and says no clipboard of a station that lists none", async () => {
    const { client, station, until, settled } = setup();
    const view = screens(station);
    await settled();
    const { events, stop, answer } = open(client, {
      ...params,
      control: false,
      peek: true,
      audio: true,
    });
    answer.catch(() => undefined);
    await until(() => events.length > 0, "the view opens");
    expect(events[0]).toEqual({
      type: "open",
      view: (events[0] as { view: number }).view,
    });
    expect(view.asked[0]).not.toContain("audio");
    stop.abort();
  });

  it("switches Watch and Control on the open view: one view, the station told on its stream", async () => {
    const { client, station, until, settled } = setup();
    const view = screens(station);
    await settled();
    const { events, stop, answer } = open(client, { ...params, control: false });
    answer.catch(() => undefined);
    await until(() => events.length > 0, "the view opens");
    expect(view.asked[0]).toContain('"control":false');
    const id = (events[0] as { view: number }).view;

    void client.call("devices.sendToScreenView", { view: id, control: true });
    void client.call("devices.sendToScreenView", {
      view: id,
      input: { type: "move", x: 0.5, y: 0.5, mods: [] },
    });
    void client.call("devices.sendToScreenView", { view: id, control: false });
    await until(() => view.said.length === 3, "the station hears them");
    expect(view.said.map((frame) => frame.kind)).toEqual([
      ScreenKind.control,
      ScreenKind.input,
      ScreenKind.control,
    ]);
    expect(
      [view.said[0]!, view.said[2]!].map((frame) => parseScreenControl(frame.payload))
    ).toEqual([true, false]);
    // The station's answer reaches the page as the view's state.
    view.push(encodeScreenJson(ScreenKind.state, { control: true }));
    await until(
      () => events.some((event) => event.type === "state" && event.state.control),
      "the page hears it drives"
    );
    // Still the one view it opened.
    expect(view.asked).toHaveLength(1);
    expect(view.gone()).toBe(false);
    stop.abort();
  });

  it("says when the station ended the view, and why", async () => {
    const { client, station, until, settled } = setup();
    const view = screens(station);
    await settled();
    const { events, answer } = open(client);
    answer.catch(() => undefined);
    await until(() => events.length > 0, "the view opens");
    view.push(encodeScreenJson(ScreenKind.state, { ended: "the display went away" }));
    view.end();
    await settled();
    await expect(answer).rejects.toMatchObject({
      code: "screen_ended",
      message: "the display went away",
    });
  });

  it("puts a new connection in place of a silent station's once one opens, and the view ends to be asked again", async () => {
    const { client, station, stations, host, until, settled } = setup();
    const view = screens(station);
    await settled();
    const { events, answer } = open(client);
    let failed: unknown;
    answer.catch((error: unknown) => (failed = error));
    await until(() => events.length > 0, "the view opens");
    view.push(encodeScreenJson(ScreenKind.state, { alive: true }));
    await settled();

    // The station's process is killed: its connection stays open here and carries nothing. A new one is tried beside
    // it and none opens: the view waits on, on the old one.
    stations.mesh.crash(STATION);
    const dials = stations.mesh.dials.length;
    await host.time!.pass(12_000);
    expect(stations.mesh.dials.length).toBeGreaterThan(dials);
    expect(failed).toBeUndefined();

    // Started again (its key, a new process): the next try opens, takes the old one's place, and the view ends.
    screens(stations.station(STATION, WS));
    const dialed = stations.mesh.dialed;
    // (a second at a time, to stop where it ended: what reconnects after is another test's)
    const ended = () => failed !== undefined;
    for (let s = 0; s < 6 && !ended(); s++) await host.time!.pass(1_000);
    expect(failed).toMatchObject({
      code: "unreachable",
      message: expect.stringContaining("replaced"),
    });
    expect(stations.mesh.dialed).toBe(dialed + 1);
  });

  it("opens another new connection beside one still dialling a station that came back, and that one takes the place", async () => {
    const { client, station, stations, host, until, settled } = setup();
    screens(station);
    await settled();
    const { events, answer } = open(client);
    let failed: unknown;
    answer.catch((error: unknown) => (failed = error));
    await until(() => events.length > 0, "the view opens");
    await settled();

    // Killed, and its first new connection dialled while it is away gets no answer: it waits on (QUIC sends its first
    // packet again only after a while).
    stations.mesh.unansweredDialsWait = true;
    stations.mesh.crash(STATION);
    const dials = stations.mesh.dials.length;
    await host.time!.pass(4_000);
    expect(stations.mesh.dials.length).toBe(dials + 1);

    // Back: the next unanswered ping opens another beside the one still waiting, which reaches it.
    screens(stations.station(STATION, WS));
    const ended = () => failed !== undefined;
    for (let s = 0; s < 4 && !ended(); s++) await host.time!.pass(1_000);
    expect(failed).toMatchObject({
      code: "unreachable",
      message: expect.stringContaining("replaced"),
    });
  });

  it("gives up a connection that opens no new stream and carries nothing for 30 s; keeps one that still carries a view", async () => {
    const { client, station, stations, host, until, settled } = setup();
    const view = screens(station);
    await settled();
    const { events, answer } = open(client);
    let failed: unknown;
    answer.catch((error: unknown) => (failed = error));
    await until(() => events.length > 0, "the view opens");
    await settled();
    const dials = stations.mesh.dials.length;

    // The station lets no more streams be open, and its view goes on: the connection is kept, and no other opened.
    stations.mesh.holdStreams(STATION, true);
    for (let s = 0; s < 40; s++) {
      view.push(encodeScreenJson(ScreenKind.state, { alive: true }));
      await host.time!.pass(1_000);
    }
    expect(failed).toBeUndefined();
    expect(stations.mesh.dials.length).toBe(dials);

    // Nothing comes any more either: given up once nothing was heard for 30 s.
    await host.time!.pass(26_000, 1_000);
    expect(failed).toBeUndefined();
    const ended = () => failed !== undefined;
    for (let s = 0; s < 8 && !ended(); s++) await host.time!.pass(1_000);
    expect(failed).toBeDefined();
  });

  it("keeps the connection of a view whose network only paused, and the view on it", async () => {
    const { client, station, stations, host, until, settled } = setup();
    const view = screens(station);
    await settled();
    const { events, answer } = open(client);
    let failed: unknown;
    answer.catch((error: unknown) => (failed = error));
    await until(() => events.length > 0, "the view opens");
    view.push(encodeScreenJson(ScreenKind.state, { alive: true }));
    await settled();
    const dialed = stations.mesh.dialed;

    // Ten seconds of no network: new connections are tried and none opens; then it comes back and the station's
    // words that waited arrive on the old one.
    stations.mesh.pause(STATION, true);
    view.push(encodeScreenJson(ScreenKind.state, { alive: true }));
    await host.time!.pass(10_000);
    stations.mesh.pause(STATION, false);
    // (the station says it is alive every 2 s, as it does)
    for (let s = 0; s < 4; s++) {
      view.push(encodeScreenJson(ScreenKind.state, { alive: true }));
      await host.time!.pass(2_000);
    }
    expect(failed).toBeUndefined();
    expect(stations.mesh.dialed).toBe(dialed);
    const before = events.length;
    view.push(encodeScreenJson(ScreenKind.state, { alive: true }));
    await until(() => events.length > before, "the view goes on");
  });

  it("keeps the connection of a view after this computer slept: the silence counts again from waking", async () => {
    // The wall clock jumps while no timer runs: a replay's clock cannot sleep through it.
    const { client, station, stations, host, until, settled } = setup({
      replays: false,
    });
    const view = screens(station);
    await settled();
    const { events, answer } = open(client);
    let failed: unknown;
    answer.catch((error: unknown) => (failed = error));
    await until(() => events.length > 0, "the view opens");
    view.push(encodeScreenJson(ScreenKind.state, { alive: true }));
    await settled();
    const dials = stations.mesh.dials.length;

    // Asleep for a minute: on waking, the clock has moved on before what the station sent is read.
    host.time!.sleepThrough(60_000);
    for (let s = 0; s < 4; s++) {
      await host.time!.pass(2_000);
      view.push(encodeScreenJson(ScreenKind.state, { alive: true }));
    }
    await settled();
    expect(failed).toBeUndefined();
    expect(stations.mesh.dials.length).toBe(dials);
  });

  it("keeps an explicit capture refusal distinct from a lost stream", async () => {
    const { client, station, until, settled } = setup();
    const view = screens(station);
    await settled();
    const { events, answer } = open(client);
    answer.catch(() => undefined);
    await until(() => events.length > 0, "the view opens");
    const reason = "Open one separate Device Hub window to show its half fold.";
    view.push(
      encodeScreenJson(ScreenKind.state, { ended: reason, endedCode: "screen_refused" })
    );
    view.end();
    await settled();
    await expect(answer).rejects.toMatchObject({
      code: "screen_refused",
      message: reason,
    });
  });

  it("says the mesh does not reach the computer; forced through Salix, it says that path failed", async () => {
    for (const [salixOnly, code] of [
      [false, "unreachable"],
      [true, "salix_only"],
    ] as const) {
      const { client, settled } = setup({ salixOnly, unreached: true });
      const { answer } = open(client);
      answer.catch(() => undefined);
      await settled();
      await expect(answer).rejects.toMatchObject({ code });
    }
  });

  it("says a station's refusal as a refusal, for no other way to try, forced through Salix or not", async () => {
    for (const salixOnly of [false, true]) {
      const { client, station, settled } = setup({ salixOnly });
      station.takes = "another-workspace";
      const { answer } = open(client);
      answer.catch(() => undefined);
      await settled();
      await expect(answer).rejects.toMatchObject({ code: "unauthorized" });
    }
  });

  it("is only where the host reaches own computers: elsewhere it says so without asking anyone", async () => {
    const { client, station, settled } = setup({ desktop: false });
    const view = screens(station);
    await settled();
    const { answer } = open(client);
    answer.catch(() => undefined);
    await settled();
    await expect(answer).rejects.toMatchObject({ code: "unsupported" });
    expect(view.asked).toEqual([]);
  });

  it("does not open on a computer with no station", async () => {
    const { client, settled } = setup({ station: null });
    await settled();
    const { answer } = open(client);
    answer.catch(() => undefined);
    await settled();
    await expect(answer).rejects.toMatchObject({ code: "unsupported" });
  });

  it("never sends a view's stream to a station from before: it would wait for its body to end", async () => {
    const { client, station, settled } = setup();
    await settled();
    const views: string[] = [];
    const fallback = station.handle.bind(station);
    station.handle = (request) => {
      if (request.path.endsWith("/view")) views.push(request.path);
      return fallback(request);
    };
    const { answer } = open(client);
    answer.catch(() => undefined);
    await settled();
    await expect(answer).rejects.toMatchObject({ code: "unsupported" });
    expect(views).toEqual([]);
    expect(station.asked).toContain("GET /screens");
  });

  it("says a refusal as the station says it", async () => {
    const { client, station, settled } = setup();
    await settled();
    station.on("GET", "/screens", () => json(200, { screens: [{ id: "display" }] }));
    // A station answers before the view's stream ends, which it never does by itself.
    const fallback = station.handle.bind(station);
    station.handle = (request) =>
      request.path.endsWith("/view")
        ? Promise.resolve({
            status: 403,
            body: new TextEncoder().encode(
              JSON.stringify({
                error: "this computer does not allow its screen to be viewed",
              })
            ),
          })
        : fallback(request);
    const { answer } = open(client);
    answer.catch(() => undefined);
    await settled();
    await expect(answer).rejects.toMatchObject({
      code: "forbidden",
      message: "this computer does not allow its screen to be viewed",
    });
  });

  describe("a computer's Android devices and iOS Simulators", () => {
    const EMULATOR = "android:emulator-5554";
    const SIMULATOR = "simulator:0702F8CC-2E2A-4D0A-8401-C37FA01E1646";
    const simulator = {
      id: SIMULATOR,
      kind: "simulator",
      title: "iPhone 17 · iOS 27.2",
      name: "iPhone 17",
      model: "iPhone 17 Pro",
      instance: "fedcba9876543210",
      width: 1206,
      height: 2622,
      peek: true,
      capabilities: {
        input: "touch",
        buttons: ["home", "lock"],
        panels: [],
        closable: true,
      },
    };
    const listing = {
      screens: [
        { id: "display", kind: "desktop" },
        {
          id: EMULATOR,
          kind: "android",
          title: "Fold · Android 16",
          name: "Fold",
          instance: "0123456789abcdef",
          width: 1080,
          height: 2400,
          peek: true,
          capabilities: { input: "touch", buttons: ["rotate"], panels: [] },
        },
        simulator,
        // A booted one whose boot the station could not tell: it is not one to drive, and not listed.
        {
          ...simulator,
          id: "simulator:0702F8CC-0000-0000-0000-C37FA01E1646",
          instance: undefined,
        },
      ],
      codecs: ["h264"],
      avds: ["Pixel_9"],
      simulators: [
        {
          udid: "FEF50280-1320-41CC-9F03-B3FA444053A7",
          title: "iPhone Air · iOS 27.2",
          model: "iPhone Air",
        },
      ],
    };
    const listed = (station: ReturnType<typeof setup>["station"]) => {
      const view = screens(station);
      station.on("GET", "/screens", () => json(200, listing));
      return view;
    };

    it("are listed with what could start, a computer's own screen left out", async () => {
      const { client, station, settled } = setup();
      listed(station);
      await settled();
      const answer = client.call("devices.listScreens", {
        workspace: WS,
        device: DEVICE,
      });
      await settled();
      await expect(answer).resolves.toEqual({
        screens: [
          {
            id: EMULATOR,
            instance: "0123456789abcdef",
            name: "Fold",
            title: "Fold · Android 16",
            width: 1080,
            height: 2400,
            peek: true,
            capabilities: { input: "touch", buttons: ["rotate"], panels: [] },
          },
          {
            id: SIMULATOR,
            instance: "fedcba9876543210",
            name: "iPhone 17",
            model: "iPhone 17 Pro",
            title: "iPhone 17 · iOS 27.2",
            width: 1206,
            height: 2622,
            peek: true,
            capabilities: simulator.capabilities,
          },
        ],
        avds: ["Pixel_9"],
        simulators: [
          {
            udid: "FEF50280-1320-41CC-9F03-B3FA444053A7",
            title: "iPhone Air · iOS 27.2",
            model: "iPhone Air",
          },
        ],
      });
    });

    it("are not asked for with Debug's setting off: nothing wakes the computer's adb", async () => {
      const { client, settled } = setup({ desktop: false });
      await settled();
      const answer = client.call("devices.listScreens", {
        workspace: WS,
        device: DEVICE,
      });
      answer.catch(() => undefined);
      await settled();
      await expect(answer).rejects.toMatchObject({ code: "unsupported" });
    });

    it("open only as the list says, and a preview asks to only look, small", async () => {
      const { client, station, until, settled } = setup();
      const view = listed(station);
      await settled();
      const { events, stop, answer } = open(client, {
        workspace: WS,
        device: DEVICE,
        target: EMULATOR,
        instance: "0123456789abcdef",
        control: false,
        peek: true,
        maxWidth: 640,
        maxHeight: 640,
      });
      answer.catch(() => undefined);
      await until(() => events.length > 0, "the view opens");
      expect(view.asked[0]).toContain(
        `POST /screens/${encodeURIComponent(EMULATOR)}/view`
      );
      expect(view.asked[0]).toContain('"peek":true');
      expect(view.asked[0]).toContain('"maxWidth":640');
      expect(view.asked[0]).toContain('"instance":"0123456789abcdef"');
      stop.abort();
      await settled();

      const other = open(client, { ...params, target: "android:emulator-5556" });
      other.answer.catch(() => undefined);
      await settled();
      await expect(other.answer).rejects.toMatchObject({ code: "unsupported" });
      const hostile = open(client, { ...params, target: "android:../../x" });
      hostile.answer.catch(() => undefined);
      await settled();
      await expect(hostile.answer).rejects.toMatchObject({ code: "invalid_params" });
      expect(view.asked).toHaveLength(1);
    });

    it("a simulator is viewed in the codecs its page decodes, and a card's preview asks JPEG", async () => {
      const { client, station, until, settled } = setup();
      const view = listed(station);
      await settled();
      const simParams = {
        workspace: WS,
        device: DEVICE,
        target: SIMULATOR,
        instance: "fedcba9876543210",
        control: true,
      };
      const opened = open(client, { ...simParams, codecs: ["h265", "h264", "vp9"] });
      opened.answer.catch(() => undefined);
      await until(() => opened.events.length > 0, "the view opens");
      expect(view.asked[0]).toContain(
        `POST /screens/${encodeURIComponent(SIMULATOR)}/view`
      );
      expect(view.asked[0]).toContain('"codecs":["h265","h264"]');
      opened.stop.abort();
      await settled();
      const card = open(client, {
        ...simParams,
        control: false,
        peek: true,
        codecs: ["jpeg", "h264"],
      });
      card.answer.catch(() => undefined);
      await until(() => card.events.length > 0, "the preview opens");
      expect(view.asked[1]).toContain('"codecs":["jpeg","h264"]');
      card.stop.abort();
      await settled();
    });

    it("a phone views a simulator over the mesh while its page holds the workspace's stations", async () => {
      const { client, station, until, settled } = setup({ phone: true });
      const view = listed(station);
      const held = client.subscribe(
        { topic: "stations", workspace: WS },
        nothing,
        nothing
      );
      await settled();
      const list = await client.call("devices.listScreens", {
        workspace: WS,
        device: DEVICE,
      });
      expect(
        (list as { screens: { id: string }[] }).screens.map((s) => s.id)
      ).toContain(SIMULATOR);
      const opened = open(client, {
        workspace: WS,
        device: DEVICE,
        target: SIMULATOR,
        instance: "fedcba9876543210",
        control: true,
        codecs: ["h265", "h264"],
      });
      opened.answer.catch(() => undefined);
      await until(() => opened.events.length > 0, "the view opens");
      expect(view.asked[0]).toContain(
        `POST /screens/${encodeURIComponent(SIMULATOR)}/view`
      );
      view.push(encodeScreenVideo(true, 7, new Uint8Array([1, 2, 3])));
      await until(() => opened.events.some((e) => e.type === "video"), "a frame comes");
      opened.stop.abort();
      held();
      await settled();
    });

    it("start and close through the station", async () => {
      const { client, station, settled } = setup();
      listed(station);
      const asked: unknown[] = [];
      station.on("POST", "/screens/start", (_request, body) => {
        asked.push(body);
        return json(200, { id: EMULATOR });
      });
      station.on(
        "POST",
        `/screens/${encodeURIComponent(EMULATOR)}/close`,
        (_request, body) => {
          asked.push(body);
          return json(200, {});
        }
      );
      await settled();
      const started = client.call("devices.startScreenDevice", {
        workspace: WS,
        device: DEVICE,
        avd: "Pixel_9",
      });
      await settled();
      await expect(started).resolves.toEqual({ id: EMULATOR });
      const booted = client.call("devices.startScreenDevice", {
        workspace: WS,
        device: DEVICE,
        simulator: "FEF50280-1320-41CC-9F03-B3FA444053A7",
      });
      await settled();
      await expect(booted).resolves.toEqual({ id: EMULATOR });
      const closed = client.call("devices.closeScreenDevice", {
        workspace: WS,
        device: DEVICE,
        screen: EMULATOR,
        instance: "0123456789abcdef",
      });
      await settled();
      await expect(closed).resolves.toBeNull();
      expect(asked).toEqual([
        { avd: "Pixel_9" },
        { simulator: "FEF50280-1320-41CC-9F03-B3FA444053A7" },
        { instance: "0123456789abcdef" },
      ]);
    });

    it("a simulator's case comes with the list, and its pictures through the station", async () => {
      const { client, station, settled } = setup();
      const chrome = [
        {
          key: "0123456789abcdef",
          width: 1206,
          height: 2622,
          frame: { width: 450, height: 920 },
          screen: { x: 24, y: 23, width: 402, height: 874 },
          corners: [0.15, 0.15, 0.15, 0.15],
          buttons: [
            {
              name: "power",
              x: 447,
              y: 260,
              width: 6,
              height: 100,
              dx: -3,
              dy: 0,
              page: 12,
              usage: 48,
            },
          ],
        },
      ];
      screens(station);
      station.on("GET", "/screens", () =>
        json(200, {
          ...listing,
          screens: [
            { ...simulator, capabilities: { ...simulator.capabilities, chrome } },
          ],
        })
      );
      const asked: string[] = [];
      station.on(
        "GET",
        `/screens/${encodeURIComponent(SIMULATOR)}/chrome/0/1`,
        (request) => {
          asked.push(request.path);
          return json(200, {
            body: "iVBORw0K",
            buttons: { power: { up: "iVBORw0K" } },
          });
        }
      );
      await settled();
      const list = client.call("devices.listScreens", {
        workspace: WS,
        device: DEVICE,
      });
      await settled();
      const got = (await list) as { screens: { capabilities: { chrome?: unknown } }[] };
      expect(got.screens[0]!.capabilities.chrome).toEqual(chrome);
      const pictures = client.call("devices.screenDeviceChrome", {
        workspace: WS,
        device: DEVICE,
        screen: SIMULATOR,
        panel: 0,
        turn: 1,
      });
      await settled();
      await expect(pictures).resolves.toEqual({
        body: "iVBORw0K",
        buttons: { power: { up: "iVBORw0K" } },
      });
      expect(asked).toHaveLength(1);
      // A way that is no quarter turn is not asked of the station.
      const odd = client.call("devices.screenDeviceChrome", {
        workspace: WS,
        device: DEVICE,
        screen: SIMULATOR,
        panel: 0,
        turn: 4,
      });
      odd.catch(() => undefined);
      await settled();
      await expect(odd).rejects.toMatchObject({ code: "invalid_params" });
      expect(asked).toHaveLength(1);
    });

    it("list the computer's phones, which its owner chooses through the station", async () => {
      const { client, station, settled } = setup();
      const phone = {
        serial: "3B162S00P0N00000",
        state: "device",
        model: "Pixel 8",
        transport: "usb",
        shown: false,
        agents: false,
      };
      screens(station);
      station.on("GET", "/screens", () =>
        json(200, {
          ...listing,
          screens: [
            ...listing.screens,
            {
              ...listing.screens.find((one) => one.id === EMULATOR)!,
              id: "android:3B162S00P0N00000",
              phone: true,
              agent: true,
            },
          ],
          phones: { usb: true, list: [phone] },
        })
      );
      const asked: unknown[] = [];
      station.on("POST", "/screens/phones", (_request, body) => {
        asked.push(body);
        return json(200, {
          usb: true,
          list: [
            { ...phone, shown: true, agents: true, screen: "android:3B162S00P0N00000" },
          ],
        });
      });
      await settled();
      const listedNow = client.call("devices.listScreens", {
        workspace: WS,
        device: DEVICE,
      });
      await settled();
      const answer = (await listedNow) as {
        phones?: unknown;
        screens: unknown[];
      };
      expect(answer.phones).toEqual({
        usb: true,
        list: [{ ...phone, transport: "usb" }],
      });
      expect(
        (answer.screens as { id: string }[]).find(
          (one) => one.id === "android:3B162S00P0N00000"
        )
      ).toMatchObject({
        id: "android:3B162S00P0N00000",
        phone: true,
        agent: true,
      });
      const chosen = client.call("devices.chooseScreenPhones", {
        workspace: WS,
        device: DEVICE,
        change: { serial: phone.serial, shown: true, agents: true },
      });
      await settled();
      await expect(chosen).resolves.toEqual({
        usb: true,
        list: [
          { ...phone, shown: true, agents: true, screen: "android:3B162S00P0N00000" },
        ],
      });
      expect(asked).toEqual([{ serial: phone.serial, shown: true, agents: true }]);
      const nothingAsked = client.call("devices.chooseScreenPhones", {
        workspace: WS,
        device: DEVICE,
        change: { what: 1 } as never,
      });
      nothingAsked.catch(() => undefined);
      await settled();
      await expect(nothingAsked).rejects.toMatchObject({ code: "invalid_params" });
      expect(asked).toHaveLength(1);
    });
  });

  it("takes what a page says only for a view of its own", async () => {
    const { client, station, core, host, until, settled } = setup();
    const view = screens(station);
    await settled();
    const { events, stop, answer } = open(client);
    answer.catch(() => undefined);
    await until(() => events.length > 0, "the view opens");
    const id = (events[0] as { view: number }).view;
    const other = new CoreClient(inProcessOpener(core, host), {
      schedule: () => undefined,
    });
    void other.call("devices.sendToScreenView", { view: id, keyframe: true });
    await settled();
    void client.call("devices.sendToScreenView", { view: id, ack: 5 });
    await until(() => view.said.length === 1, "its own page is heard");
    expect(view.said.map((f) => f.kind)).toEqual([ScreenKind.ack]);
    stop.abort();
    await settled();
    await expect(answer).rejects.toMatchObject({ code: "cancelled" });
  });
});
