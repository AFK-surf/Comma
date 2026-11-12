// A view of a computer's screen end to end, in memory: `MeshClient` on @comma/mesh's memory mesh, a desktop's own station
// (mesh/comma.ts `deviceServing`) with a real member credential for its owner, the view (mesh/screens.ts), and the helper as a real Unix socket
// speaking still.fail Helper's messages (screens/helper.ts, screen-pipe.ts).
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { CLIP_TEXT_MAX, MAX_CLIP_IN, MESH_ALPN, MeshClient, MeshError, type MeshResponse, SCREEN_HEADER, SCREEN_TYPE, ScreenFrameReader, ScreenKind, encodeScreenAck, encodeScreenReceived, encodeScreenClip, encodeScreenControl, encodeScreenFrame, encodeScreenJson, encodeScreenSound, parseScreenAudio, parseScreenAudioConfig, parseScreenVideo, parseStationClip, serveMeshConnection } from "@comma/mesh";
import { MemoryMesh } from "@comma/mesh/testing";
import { askOf, helperInput, makeScreenViews } from "../src/mesh/screens.ts";
import { deviceServing } from "../src/mesh/comma.ts";
import { DeviceMeshAdmissions, deviceMeshFacts } from "../src/mesh/device-mesh.ts";
import { LOW_BOUNDS, START_RATE, START_UNACKED, hostNow } from "../src/mesh/screen-pace.ts";
import { TIMING_COLUMNS } from "../src/mesh/screen-timing.ts";
import type { Access } from "../src/device/access.ts";
import { ScreenHelpers, helperSources } from "../src/screens/helper.ts";
import type { ScreenInput, ScreenSource } from "../src/screens/source.ts";
import { AppLogs, type AppLogSaid } from "../src/screens/app-logs.ts";
import { COMMA } from "../src/cloud/provider.ts";
import { GrantKey } from "./fake-control-plane.ts";
import { WindowsDesktop } from "../src/screens/win-desktop.ts";
import { fakeScreen } from "./desktop-screen-fakes.ts";

const SPS = Buffer.from("6742c00ada11ec0440000003004000000f23c489a8", "hex");
const PPS = Buffer.from("68ce0fc8", "hex");
const avcC = (sps: Buffer) => Buffer.from([1, sps[1]!, sps[2]!, sps[3]!, 0xff, 0xe1, 0, sps.length, ...sps, 1, 0, PPS.length, ...PPS]);

/// still.fail Helper's messages (CUStream/ScreenView.swift): a kind byte, the payload's length, the payload.
const message = (kind: number, payload: Buffer = Buffer.alloc(0)) => {
  const head = Buffer.alloc(5);
  head[0] = kind;
  head.writeUInt32BE(payload.length, 1);
  return Buffer.concat([head, payload]);
};
const json = (kind: number, value: unknown) => message(kind, Buffer.from(JSON.stringify(value)));
/// A config (message 2): the picture's size, then its avcC.
const config = (width: number, height: number, sps = SPS) => {
  const size = Buffer.alloc(8);
  size.writeUInt32BE(width, 0);
  size.writeUInt32BE(height, 4);
  return message(2, Buffer.concat([size, avcC(sps)]));
};
/// A frame (message 3): flags, timestamp, one AVCC NAL unit marked `mark`.
const frame = (key: boolean, ts: number, mark: number) => {
  const head = Buffer.alloc(9);
  head[0] = key ? 1 : 0;
  head.writeBigUInt64BE(BigInt(ts), 1);
  return message(3, Buffer.concat([head, Buffer.from([0, 0, 0, 2, key ? 0x65 : 0x41, mark])]));
};
const INFO = { width: 1280, height: 800, encoder: "hardware, low latency, H264_ConstrainedBaseline_AutoLevel, 1500000 bps", codec: "h264" };

/// Everything the tests wait on says it changed here: what the helper hears, what a view reads. A wait has no deadline
/// of its own: the test runner's is the only bound.
let waiting: (() => void)[] = [];
const changed = () => {
  const woken = waiting;
  waiting = [];
  for (const wake of woken) wake();
};
async function until(what: () => boolean) {
  while (!what()) await new Promise<void>((resolve) => waiting.push(resolve));
}

/// The Computer Use helper on a real Unix socket, speaking still.fail Helper's messages: each connection's request line,
/// then `info` (the n-th connection's: `first` may say each), and what the station asks noted: `next`s (per
/// connection), key frames and input (`said`), rates, bounds. It gives a frame only when the test says (`give`), and
/// only once one was asked for, as the real one does.
function fakeHelper(t: TestContext, first: unknown | ((n: number) => unknown) = INFO) {
  const path = join(mkdtempSync("/tmp/msv-"), "helper.sock");
  // `clips`: what views set of the clipboard (message 4), in order with `said`; `watches`: watch on/off (message 5);
  // `audios`: packets asked (message 9), each answered with one (the n-th filled with n) by a view asked `audio`.
  const got: { requests: Record<string, any>[]; said: Record<string, any>[]; rates: number[]; bounds: Record<string, any>[]; nexts: number[]; conns: Socket[]; closed: number; watches: number[]; audios: number } = { requests: [], said: [], rates: [], bounds: [], nexts: [], conns: [], closed: 0, watches: [], audios: 0 };
  const given = new Map<Socket, number>();
  const server: Server = createServer((conn) => {
    const at = got.conns.push(conn) - 1;
    got.nexts.push(0);
    given.set(conn, 0);
    changed();
    let buffer = Buffer.alloc(0);
    let asked = false;
    let opus = false;
    conn.on("data", (chunk: Buffer) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!asked) {
        const newline = buffer.indexOf(10);
        if (newline < 0) return;
        got.requests.push(JSON.parse(buffer.subarray(0, newline).toString("utf8")));
        changed();
        buffer = buffer.subarray(newline + 1);
        asked = true;
        const audio = got.requests.at(-1)!.view?.audio === true;
        // A Mac's helper encodes Opus for a view that asks it (SystemAudio.swift); its packets are then 160 bytes here.
        opus = audio && got.requests.at(-1)!.view?.audioCodec === "opus";
        const info = typeof first === "function" ? first(at) : first;
        conn.write(json(1, audio && info && typeof info === "object" && !("error" in info) ? { ...info, audio: true } : info));
        if (audio) conn.write(json(8, { codec: opus ? "opus" : "pcm_s16le", sampleRate: 48000, channels: 2 }));
      }
      while (buffer.length >= 5 && buffer.length >= 5 + buffer.readUInt32BE(1)) {
        const kind = buffer[0]!;
        const payload = buffer.subarray(5, 5 + buffer.readUInt32BE(1));
        buffer = buffer.subarray(5 + payload.length);
        if (kind === 1) got.nexts[at]!++;
        else if (kind === 2) got.said.push({ type: "keyframe" });
        else if (kind === 3) got.said.push(JSON.parse(payload.toString("utf8")));
        else if (kind === 7) got.rates.push(payload.readUInt32BE(0));
        else if (kind === 8) got.bounds.push(JSON.parse(payload.toString("utf8")));
        else if (kind === 4) got.said.push({ clip: Buffer.from(payload) });
        else if (kind === 5) got.watches.push(payload[0]!);
        else if (kind === 9) {
          const n = ++got.audios;
          const packet = Buffer.alloc(8 + (opus ? 160 : 3840), n);
          packet.writeBigUInt64BE(BigInt(1_000_000 + n * 20_000), 0);
          conn.write(message(9, packet));
        }
        changed();
      }
    });
    conn.on("close", () => {
      got.closed++;
      changed();
    });
    conn.on("error", () => {});
  });
  /// Writes `bytes` (a frame, a config before it) once the station has asked for one more frame than it was given.
  const give = async (conn: Socket, ...bytes: Buffer[]) => {
    const at = got.conns.indexOf(conn);
    await until(() => got.nexts[at]! > given.get(conn)!);
    given.set(conn, given.get(conn)! + 1);
    conn.write(Buffer.concat(bytes));
  };
  t.after(() => {
    for (const conn of got.conns) conn.destroy();
    server.close();
  });
  return { path, got, give, ready: new Promise<void>((resolve) => server.listen(path, () => resolve())) };
}

const GRANT = new GrantKey();
const WS = "ws_1";
const WS2 = "ws_2";
/// A credential's times, which the station reads by the machine's clock: long ago, and long after any run.
const ISSUED = 1_700_000_000;
const EXPIRES = 4_102_444_800;

/// A station serving Comma's mesh, and a member's client on it.
async function setup(t: TestContext, options: { role?: string; first?: unknown | ((n: number) => unknown); helper?: boolean; sub?: string; exp?: number; credential?: string; ensure?: () => Promise<void>; window?: number; sources?: ScreenSource[]; via?: string; timing?: (fields: Record<string, unknown>) => void } = {}) {
  const helper = fakeHelper(t, options.first);
  await helper.ready;
  const helpers = new ScreenHelpers();
  if (options.helper !== false) helpers.attach({ ensure: options.ensure ?? (async () => {}), authToken: () => "token", socketPath: helper.path });
  const world = { access: "full" as Access, drive: true };
  // One key in two Groups: `user_1` owns this computer in one, `user_2` in the other.
  const admissions = new DeviceMeshAdmissions();
  const runA = {};
  const facts = (revocations: unknown[]) => deviceMeshFacts({ workspace: WS, grant_keys: { keys: [GRANT.jwk] }, revocations, owner: "user_1", relay_urls: [] });
  admissions.set(runA, facts([]));
  admissions.set({}, deviceMeshFacts({ workspace: WS2, grant_keys: { keys: [GRANT.jwk] }, revocations: [], owner: "user_2", relay_urls: [] }));
  const changes = new Set<() => void>();
  const deadlines: (() => void)[] = [];
  const worldChanged = () => changes.forEach((f) => f());
  const sources = helperSources(() => helpers.current());
  const screens = makeScreenViews({
    sources: () => [...(helpers.current() ? sources : []), ...(options.sources ?? [])],
    access: () => world.access,
    up: () => true,
    mayView: (member) => admissions.mayView(member),
    mayControl: (member) => world.drive && admissions.mayControl(member),
    listen: (f) => {
      changes.add(f);
      const stop = admissions.listen(f);
      return () => (changes.delete(f), stop());
    },
    after: (_ms, f) => {
      deadlines.push(f);
      changed();
      return () => void deadlines.splice(deadlines.indexOf(f), 1);
    },
    timing: options.timing !== undefined,
    ...(options.timing ? { timingLine: options.timing } : {}),
  });
  // What an ordinary request would take: nothing here goes to the admin API but what is not a screen's.
  const admin = { handle: async () => ({ status: 200, headers: {}, body: Buffer.from("{}") }) };
  const members = { admin, up: () => true, screens } as any;

  const mesh = new MemoryMesh();
  if (options.window !== undefined) mesh.window = options.window;
  const station = mesh.endpoint("station", [MESH_ALPN]);
  const app = mesh.endpoint("device");
  void (async () => {
    for (;;) {
      const connection = await station.accept();
      if (connection === null) return;
      void serveMeshConnection(connection, deviceServing(members, admissions, undefined, () => options.via ?? null));
    }
  })();
  const credentialOf = (device: string, sub: string, ws = WS) => GRANT.credential({ typ: COMMA.credential.types[0] }, { iss: COMMA.credential.issuers[0], ws, device, sub, email: "m@example.com", name: "M", role: options.role ?? "member", sid: "sess_1", iat: ISSUED, exp: options.exp ?? ISSUED + 365 * 86400 * 100});
  const client = new MeshClient({ endpoint: app, credential: async () => options.credential ?? credentialOf("device", options.sub ?? "user_1") });
  /// The owner of this computer in the other Group, on a device of their own.
  const another = () => {
    const client = new MeshClient({ endpoint: mesh.endpoint("device-2"), credential: async () => credentialOf("device-2", "user_2", WS2) });
    t.after(() => client.close());
    return client;
  };
  const peer = { id: "station" };
  t.after(async () => {
    client.close();
    await Promise.all([app.close(), station.close()]);
  });
  return { helper, helpers, world, changed: worldChanged, client, peer, mesh, another, deadlines, revoke: () => admissions.set(runA, facts([{ kind: "sub", id: "user_1", at: ISSUED + 1 }])), runEnds: () => admissions.set(runA, null) };
}

/// A view the test reads as it comes, sending what it says to.
async function openView(client: MeshClient, peer: { id: string }, ask: Record<string, unknown> = { codecs: ["h264"], control: true }, id = "display") {
  const queue: Uint8Array[] = [];
  let wake = () => {};
  let finished = false;
  const body = (async function* () {
    for (;;) {
      const next = queue.shift();
      if (next) yield next;
      else if (finished) return;
      else await new Promise<void>((resolve) => (wake = resolve));
    }
  })();
  const response: MeshResponse = await client.request(peer, { method: "POST", path: `/screens/${id}/view`, headers: [[SCREEN_HEADER, JSON.stringify(ask)]], body });
  const frames: { kind: number; payload: Uint8Array }[] = [];
  const reader = new ScreenFrameReader(16 << 20);
  const read = (async () => {
    for await (const chunk of response.body) {
      frames.push(...reader.push(chunk));
      changed();
    }
  })().catch(() => {});
  return {
    response,
    frames,
    read,
    videos: () => frames.filter((f) => f.kind === ScreenKind.video).map((f) => parseScreenVideo(f.payload)!),
    states: () => frames.filter((f) => f.kind === ScreenKind.state).map((f) => JSON.parse(Buffer.from(f.payload).toString("utf8"))),
    configs: () => frames.filter((f) => f.kind === ScreenKind.config).map((f) => JSON.parse(Buffer.from(f.payload).toString("utf8"))),
    clips: () => frames.filter((f) => f.kind === ScreenKind.clipboard).map((f) => parseStationClip(f.payload)),
    audios: () => {
      const config = frames.find((f) => f.kind === ScreenKind.audioConfig);
      const codec = (config && parseScreenAudioConfig(config.payload)) || "pcm_s16le";
      return frames.filter((f) => f.kind === ScreenKind.audio).map((f) => parseScreenAudio(f.payload, codec)!);
    },
    kinds: () => frames.map((f) => f.kind),
    send: (bytes: Uint8Array) => {
      queue.push(bytes);
      wake();
    },
    finish: () => {
      finished = true;
      wake();
    },
  };
}

const answer = async (response: MeshResponse) => {
  const parts: Uint8Array[] = [];
  for await (const chunk of response.body) parts.push(chunk);
  return JSON.parse(Buffer.concat(parts).toString("utf8"));
};

test("the screens are listed, and a station with no helper lists none", async (t) => {
  const { client, peer } = await setup(t);
  const listed = await client.request(peer, { method: "GET", path: "/screens" });
  assert.equal(listed.status, 200);
  // Each says the clipboard's types a view that drives it carries (still.fail's list `clipboard`).
  assert.deepEqual((await answer(listed)).screens, [
    { id: "app", kind: "desktop", clipboard: ["text", "png"] },
    { id: "display", kind: "desktop", clipboard: ["text", "png"] },
  ]);
  const none = await setup(t, { helper: false });
  assert.deepEqual((await answer(await none.client.request(none.peer, { method: "GET", path: "/screens" }))).screens, []);
  const refused = await none.client.request(none.peer, { method: "POST", path: "/screens/display/view", headers: [[SCREEN_HEADER, '{"codecs":["h264"]}']] });
  assert.equal(refused.status, 404);
});

test("a view: H.264 or H.265 from the helper as a config and AVCC frames, each asked for, two-way while the request is open", async (t) => {
  const { client, peer, helper } = await setup(t);
  const view = await openView(client, peer, { codecs: ["h264"], control: true, apps: ["Notes"], maxWidth: 1280, background: "#102030" }, "app");
  assert.equal(view.response.status, 200);
  assert.deepEqual(view.response.headers, [["content-type", SCREEN_TYPE]]);
  await until(() => helper.got.conns.length === 1 && helper.got.requests.length === 1);
  assert.deepEqual(helper.got.requests[0], { control: "screen.view", view: { target: "app", codec: "h264", control: true, maxWidth: 1280, maxHeight: 1080, apps: ["Notes"], bitrate: START_RATE, background: "#102030", cursor: true }, auth_token: "token" });
  const conn = helper.got.conns[0]!;

  await helper.give(conn, config(64, 48), frame(true, 1000, 1));
  await until(() => view.videos().length === 1);
  const said = view.configs()[0];
  assert.deepEqual({ codec: said.codec, width: said.width, height: said.height }, { codec: "h264", width: 64, height: 48 });
  assert.deepEqual(Buffer.from(said.description, "base64"), avcC(SPS));
  const key = view.videos()[0]!;
  assert.equal(key.key, true);
  assert.equal(key.ts, 1000);
  assert.deepEqual([...key.data], [0, 0, 0, 2, 0x65, 1]);
  assert.equal(view.states()[0].control, true);

  // A delta frame needs no second config.
  view.send(encodeScreenAck(1000));
  await helper.give(conn, frame(false, 2000, 2));
  await until(() => view.videos().length === 2);
  assert.equal(view.videos()[1]!.key, false);
  assert.equal(view.configs().length, 1);

  // A new size is a new config, before its key frame.
  view.send(encodeScreenAck(2000));
  await helper.give(conn, config(1920, 1080, Buffer.from("6742c028da01e0089f970110000003001000000303c0f1832a", "hex")), frame(true, 3000, 3));
  await until(() => view.configs().length === 2);
  assert.deepEqual([view.configs()[1].width, view.configs()[1].height], [1920, 1080]);

  // Input and a key frame asked reach the helper; what is not input does not (`stop` would end its stream).
  view.send(encodeScreenJson(ScreenKind.input, { type: "move", x: 0.5, y: 0.5, mods: [] }));
  view.send(encodeScreenJson(ScreenKind.input, { type: "stop" }));
  view.send(encodeScreenFrame(ScreenKind.keyframe));
  await until(() => helper.got.said.length === 2);
  assert.deepEqual(helper.got.said, [{ type: "move", x: 0.5, y: 0.5, mods: [] }, { type: "keyframe" }]);

  // The client finishing ends the capture, and the station says so.
  view.finish();
  await until(() => helper.got.closed === 1);
  await view.read;
  assert.equal(view.states().at(-1).ended, "finished");
});

test("a view logs where each frame's time went, its receipt apart from its decoder, once the station is asked to", async (t) => {
  const lines: Record<string, any>[] = [];
  const { client, peer, helper } = await setup(t, { timing: (fields) => lines.push(fields) });
  const view = await openView(client, peer);
  await until(() => helper.got.requests.length === 1 && view.states().length > 0);
  assert.equal(helper.got.requests[0]!.view.timing, true);
  assert.equal(view.states()[0].timing, true);
  const conn = helper.got.conns[0]!;
  // Its helper's stamps (message 66: µs on the host's clock), just before its frame.
  const ts = Math.round(hostNow() * 1000) - 20_000;
  const stamps = Buffer.alloc(32);
  [ts, ts + 2_000, ts + 9_000, ts + 9_500].forEach((us, i) => stamps.writeBigUInt64BE(BigInt(us), i * 8));
  await helper.give(conn, config(64, 48), message(66, stamps), frame(true, ts, 1));
  await until(() => view.videos().length === 1);
  view.send(encodeScreenReceived(ts));
  view.send(encodeScreenAck(ts, { held: 31, decodeIn: 0.5, decodeOut: 30, shown: 30.2, ack: 30.4 }));
  // From a helper and a client from before: no stamps, no receipt, the acknowledgement alone.
  await helper.give(conn, frame(false, ts + 1, 2));
  await until(() => view.videos().length === 2);
  view.send(encodeScreenAck(ts + 1));
  view.finish();
  await until(() => helper.got.closed === 1);
  await view.read;
  await until(() => lines.length > 0);

  assert.equal(lines[0]!.columns, TIMING_COLUMNS.join(","));
  assert.equal(lines[0]!.screen, "display");
  const frames = lines.flatMap((line) => line.frames as (number | null)[][]).map((row) => Object.fromEntries(TIMING_COLUMNS.map((name, i) => [name, row[i]])));
  assert.equal(frames.length, 2);
  const [first, second] = frames as Record<string, number | null>[];
  assert.deepEqual([first!.ts, first!.key, first!.encodeStart, first!.encodeDone, first!.helperSent], [ts, 1, 2, 9, 9.5]);
  // The station's, in order, after capture.
  const station = [first!.got, first!.queued, first!.writeStart, first!.writeDone, first!.received, first!.acked] as number[];
  assert.ok(station.every((ms, i) => typeof ms === "number" && ms >= 20 && (i === 0 || ms >= station[i - 1]!)), JSON.stringify(first));
  assert.deepEqual([first!.held, first!.decodeIn, first!.decodeOut, first!.shown, first!.clientAck], [31, 0.5, 30, 30.2, 30.4]);
  assert.deepEqual([second!.encodeStart, second!.received, second!.held], [null, null, null]);
  assert.equal(typeof second!.acked, "number");
});

test("a view logs no frame times, nor says it does, unless the station is asked to", async (t) => {
  const { client, peer, helper } = await setup(t);
  const view = await openView(client, peer);
  await until(() => helper.got.requests.length === 1 && view.states().length > 0);
  assert.equal(helper.got.requests[0]!.view.timing, undefined);
  assert.equal(view.states()[0].timing, undefined);
  view.finish();
  await view.read;
});

test("the Mac's desktop is H.265 where the client takes it and the helper makes it, else H.264 as the helper says", async (t) => {
  const s = await setup(t, { first: (n: number) => ({ ...INFO, codec: n === 0 ? "h265" : "h264" }) });
  const h265 = await openView(s.client, s.peer, { codecs: ["h265", "h264"], control: true });
  await until(() => s.helper.got.requests.length === 1);
  assert.equal(s.helper.got.requests[0]!.view.codec, "h265");
  await s.helper.give(s.helper.got.conns[0]!, config(1280, 800), frame(true, 1000, 1));
  await until(() => h265.configs().length === 1);
  assert.equal(h265.configs()[0].codec, "h265");
  // This Mac had no H.265 encoder for the second: the helper's info says H.264, and the config is so.
  const fell = await openView(s.client, s.peer, { codecs: ["h265", "h264"], control: true });
  await until(() => s.helper.got.requests.length === 2);
  await s.helper.give(s.helper.got.conns[1]!, config(1280, 800), frame(true, 1000, 1));
  await until(() => fell.configs().length === 1);
  assert.equal(fell.configs()[0].codec, "h264");
  // A client that takes H.264 alone is asked H.264.
  const only = await openView(s.client, s.peer, { codecs: ["h264"], control: true });
  await until(() => s.helper.got.requests.length === 3);
  assert.equal(s.helper.got.requests[2]!.view.codec, "h264");
  for (const view of [h265, fell, only]) view.finish();
});

test("Watch and Control switch on the open view: the same capture, no key frame or rate asked, input only while it drives", async (t) => {
  const { client, peer, helper } = await setup(t);
  const view = await openView(client, peer, { codecs: ["h264"], control: false });
  await until(() => helper.got.requests.length === 1);
  // The helper takes input from the station for a view that may drive; the station says which goes.
  assert.equal(helper.got.requests[0]!.view.control, true);
  const conn = helper.got.conns[0]!;
  await helper.give(conn, config(64, 48), frame(true, 1000, 1));
  await until(() => view.videos().length === 1);
  view.send(encodeScreenAck(1000));
  assert.equal(view.states()[0].control, false);
  /// What reached the helper, once a key frame asked after `send` did (the helper hears in order).
  const heard = async (send: () => void) => {
    const was = helper.got.said.length;
    send();
    view.send(encodeScreenFrame(ScreenKind.keyframe));
    await until(() => helper.got.said.at(-1)?.type === "keyframe" && helper.got.said.length > was);
    return helper.got.said.slice(was, -1);
  };
  const move = { type: "move", x: 0.5, y: 0.5, mods: [] };

  // Watching: input is dropped.
  assert.deepEqual(await heard(() => view.send(encodeScreenJson(ScreenKind.input, move))), []);
  const rates = helper.got.rates.length;

  // Control: said back, and input goes from the next event, on the same capture.
  assert.deepEqual(await heard(() => (view.send(encodeScreenControl(true)), view.send(encodeScreenJson(ScreenKind.input, move)))), [move]);
  assert.deepEqual(view.states().at(-1), { control: true });

  // Watch: from the very next event, nothing goes.
  assert.deepEqual(await heard(() => (view.send(encodeScreenControl(false)), view.send(encodeScreenJson(ScreenKind.input, move)))), []);
  assert.deepEqual(view.states().filter((s) => "control" in s).map((s) => s.control), [false, true, false]);

  // The picture went on as it was: one capture, no key frame but those the test asked, no rate from the switches.
  assert.equal(helper.got.conns.length, 1);
  assert.equal(helper.got.requests.length, 1);
  assert.equal(helper.got.rates.length, rates);
  await helper.give(conn, frame(false, 2000, 2));
  await until(() => view.videos().length === 2);
  assert.equal(view.videos()[1]!.key, false);
  assert.equal(view.configs().length, 1);
  view.finish();
});

test("Control is admitted on the open view as at its opening: refused while access is not Full or one may not drive", async (t) => {
  const s = await setup(t);
  const view = await openView(s.client, s.peer, { codecs: ["h264"], control: false });
  await until(() => s.helper.got.requests.length === 1 && view.states().length === 1);
  const move = { type: "move", x: 0.5, y: 0.5, mods: [] };
  const answered = async (on: boolean) => {
    const was = view.states().length;
    view.send(encodeScreenControl(on));
    await until(() => view.states().slice(was).some((state) => "control" in state));
    return view.states().slice(was).find((state) => "control" in state);
  };

  // Lowered with nothing told yet (the view would end once it is): the switch itself looks.
  s.world.access = "read" as Access;
  assert.deepEqual(await answered(true), { control: false, refused: "this computer does not allow its screen to be viewed: its access is not Full" });
  s.world.access = "full";
  s.world.drive = false;
  assert.deepEqual(await answered(true), { control: false, refused: "only one who may drive this computer may do that" });
  // None of it went to the helper.
  view.send(encodeScreenJson(ScreenKind.input, move));
  view.send(encodeScreenFrame(ScreenKind.keyframe));
  await until(() => s.helper.got.said.length === 1);
  assert.deepEqual(s.helper.got.said, [{ type: "keyframe" }]);

  // Once it may again, the same view drives.
  s.world.drive = true;
  assert.deepEqual(await answered(true), { control: true });
  view.send(encodeScreenJson(ScreenKind.input, move));
  await until(() => s.helper.got.said.length === 2);
  assert.deepEqual(s.helper.got.said[1], move);
  view.finish();
});

test("frames are asked of the helper only as they are acknowledged: none is encoded while the link holds them back", async (t) => {
  const { client, peer, helper } = await setup(t);
  const view = await openView(client, peer);
  await until(() => helper.got.conns.length === 1 && helper.got.requests.length === 1);
  const conn = helper.got.conns[0]!;
  await helper.give(conn, config(64, 48), frame(true, 1000, 0));
  for (let i = 1; i < START_UNACKED; i++) await helper.give(conn, frame(false, (i + 1) * 1000, i));
  await until(() => view.videos().length === START_UNACKED);
  // A round through the view and the helper's socket, in which another `next` would have come: none did, so the helper
  // encoded nothing more (a slow or relayed link gets fewer frames, never a queue of them).
  view.send(encodeScreenFrame(ScreenKind.keyframe));
  await until(() => helper.got.said.length === 1);
  assert.equal(helper.got.nexts[0], START_UNACKED);
  assert.equal(view.videos().length, START_UNACKED);
  // Frames held back: the helper is told the rate to encode at, so what comes next is smaller rather than later.
  assert.equal(helper.got.rates.length, 1);
  // Once one is acknowledged the next is asked for.
  view.send(encodeScreenAck(view.videos().at(-1)!.ts));
  await until(() => helper.got.nexts[0]! > START_UNACKED);
  view.finish();
});

test("who may: this computer's owner, while its access is Full; another member or a read-only one sees nothing", async (t) => {
  const off = await setup(t);
  for (const access of ["off", "read"] as Access[]) {
    off.world.access = access;
    const refused = await off.client.request(off.peer, { method: "POST", path: "/screens/display/view", headers: [[SCREEN_HEADER, '{"codecs":["h264"],"control":true}']] });
    assert.equal(refused.status, 403);
    assert.match((await answer(refused)).error, /Full/);
  }
  assert.equal(off.helper.got.conns.length, 0, "the helper is never reached");

  // The owner whose role is now read-only, and members who are not the owner: refused before any screen is named.
  const demoted = await setup(t, { role: "viewer" });
  await assert.rejects(demoted.client.request(demoted.peer, { method: "GET", path: "/screens" }), (error: MeshError) => error.code === "unauthorized" && /read-only/.test(error.message));
  assert.equal(demoted.helper.got.conns.length, 0);
  for (const role of ["member", "viewer", "owner"]) {
    const other = await setup(t, { role, sub: "user_3" });
    await assert.rejects(other.client.request(other.peer, { method: "POST", path: "/screens/display/view", headers: [[SCREEN_HEADER, '{"codecs":["h264"],"control":true}']] }), (error: MeshError) => error.code === "unauthorized" && /owner/.test(error.message));
    assert.equal(other.helper.got.conns.length, 0, "the helper is never reached");
  }
});

test("a view ends when what allowed it goes: access lowered, credential revoked, the run to Salix gone", async (t) => {
  const lowers: [string, (s: Awaited<ReturnType<typeof setup>>) => void, RegExp][] = [
    ["access", (s) => (s.world.access = "read"), /Full/],
    ["revoked", (s) => s.revoke(), /revoked/],
    ["run gone", (s) => s.runEnds(), /revoked/],
  ];
  for (const [what, lower, said] of lowers) {
    const s = await setup(t);
    const view = await openView(s.client, s.peer);
    await until(() => s.helper.got.conns.length === 1 && s.helper.got.requests.length === 1);
    lower(s);
    s.changed();
    await until(() => s.helper.got.closed === 1);
    await view.read;
    assert.match(view.states().at(-1).ended, said);
  }
});

test("what the helper refuses or stops with is said; a stream's loss ends the capture", async (t) => {
  // Screen Recording not granted: refused, saying where it is given.
  const refused = await setup(t, { first: { error: "Screen Recording is not granted", code: "capture", capture: false } });
  const answered = await refused.client.request(refused.peer, { method: "POST", path: "/screens/display/view", headers: [[SCREEN_HEADER, '{"codecs":["h264"]}']] });
  assert.equal(answered.status, 503);
  assert.match((await answer(answered)).error, /Comma Computer Use.*System Settings > Privacy & Security > Screen & System Audio Recording/);
  const other = await setup(t, { first: { error: "Display was not found", code: "display" } });
  const failed = await other.client.request(other.peer, { method: "POST", path: "/screens/display/view", headers: [[SCREEN_HEADER, '{"codecs":["h264"]}']] });
  assert.equal(failed.status, 503);
  assert.match((await answer(failed)).error, /Display was not found/);

  const ended = await setup(t);
  const view = await openView(ended.client, ended.peer);
  await until(() => ended.helper.got.requests.length === 1);
  const reason = "Open one separate Device Hub window for still.fail-try – iOS 27.1 to show its half fold.";
  ended.helper.got.conns[0]!.end(json(4, { stopped: reason }));
  await view.read;
  assert.ok(view.states().at(-1).ended.includes(reason));
  assert.equal(view.states().at(-1).endedCode, "screen_refused");

  const lost = await setup(t);
  const gone = await openView(lost.client, lost.peer);
  await until(() => lost.helper.got.requests.length === 1);
  lost.mesh.cut();
  await until(() => lost.helper.got.closed === 1);
  await gone.read;
});

test("Screen Recording granted since the helper started: it is started again and asked once more (still.fail's restart)", async (t) => {
  let ensured = 0;
  const s = await setup(t, {
    ensure: async () => void ensured++,
    first: (n: number) => (n === 0 ? { error: "restarting to take Screen Recording", code: "restart", capture: true } : INFO),
  });
  const view = await openView(s.client, s.peer);
  assert.equal(view.response.status, 200);
  await until(() => s.helper.got.requests.length === 2);
  assert.equal(ensured, 2, "the helper is started again before the second ask");
  await s.helper.give(s.helper.got.conns[1]!, config(64, 48), frame(true, 1000, 1));
  await until(() => view.videos().length === 1);
  view.finish();

  // Once only: a helper that says so again is refused, saying where Screen Recording is given.
  const again = await setup(t, { first: { error: "restarting to take Screen Recording", code: "restart", capture: true } });
  const refused = await again.client.request(again.peer, { method: "POST", path: "/screens/display/view", headers: [[SCREEN_HEADER, '{"codecs":["h264"]}']] });
  assert.equal(refused.status, 503);
  assert.match((await answer(refused)).error, /Screen & System Audio Recording/);
  assert.equal(again.helper.got.requests.length, 2);
});

test("the Mac helper's view is asked for other bounds as it runs (the smaller picture of a slow link)", async (t) => {
  // The Mac's helper: the bounds go as message 8 on the view's connection (screen-pace.ts Sizer asks them).
  const s = await setup(t);
  const sources = helperSources(() => s.helpers.current());
  const view = await sources[1]!.open({ maxWidth: 1920, maxHeight: 1080, codecs: ["h264"] });
  view.bounds!(LOW_BOUNDS.maxWidth, LOW_BOUNDS.maxHeight);
  await until(() => s.helper.got.bounds.length === 1);
  assert.deepEqual(s.helper.got.bounds[0], LOW_BOUNDS);
  view.close();
});

test("at most so many views run at once, and one member cannot take them all; a closed one makes room", async (t) => {
  const { client, peer, helper, another } = await setup(t);
  const asks = { method: "POST", path: "/screens/display/view", headers: [[SCREEN_HEADER, '{"codecs":["h264"]}']] as [string, string][] };
  const views = [];
  for (let i = 0; i < 3; i++) views.push(await openView(client, peer));
  const theirs = await client.request(peer, asks);
  assert.equal(theirs.status, 503);
  assert.match((await answer(theirs)).error, /one member/);
  const other = another();
  views.push(await openView(other, peer));
  assert.equal(views.at(-1)!.response.status, 200);
  const fifth = await other.request(peer, asks);
  assert.equal(fifth.status, 503);
  await answer(fifth);
  views[0]!.finish();
  await until(() => helper.got.closed === 1);
  await views[0]!.read;
  const again = await openView(client, peer);
  assert.equal(again.response.status, 200);
  for (const view of [...views.slice(1), again]) view.finish();
});

test("a stream broken as its view ends frees the view's place", async (t) => {
  const s = await setup(t);
  const views = [];
  for (let i = 0; i < 3; i++) views.push(await openView(s.client, s.peer));
  await until(() => s.helper.got.requests.length === 3);
  s.world.access = "read";
  s.changed();
  s.mesh.cut();
  await until(() => s.helper.got.closed === 3);
  await Promise.all(views.map((view) => view.read));
  s.world.access = "full";
  for (let i = 0; i < 3; i++) {
    const again = await openView(s.client, s.peer);
    assert.equal(again.response.status, 200);
  }
  s.mesh.cut();
});

test("what allowed a view going while it opens: refused, and the capture stopped", async (t) => {
  for (const [lower, status] of [
    [(s: Awaited<ReturnType<typeof setup>>) => s.revoke(), 401],
    [(s: Awaited<ReturnType<typeof setup>>) => (s.world.access = "read"), 403],
  ] as const) {
    let started = false;
    let release = () => {};
    const gate = new Promise<void>((resolve) => (release = resolve));
    const s = await setup(t, {
      ensure: () => {
        started = true;
        changed();
        return gate;
      },
    });
    const pending = s.client.request(s.peer, { method: "POST", path: "/screens/display/view", headers: [[SCREEN_HEADER, '{"codecs":["h264"],"control":true}']] });
    await until(() => started);
    lower(s);
    s.changed();
    release();
    const answered = await pending;
    assert.equal(answered.status, status);
    await answer(answered);
    await until(() => s.helper.got.closed === s.helper.got.conns.length);
  }
});

test("a client that stopped reading does not keep its place once its view ended", async (t) => {
  // The window fills with what the view says first: what it says next waits, as it does on QUIC.
  const s = await setup(t, { window: 1 });
  const asks = { method: "POST", path: "/screens/display/view", headers: [[SCREEN_HEADER, '{"codecs":["h264"]}']] as [string, string][] };
  const unread: MeshResponse[] = [];
  for (let i = 0; i < 3; i++) unread.push(await s.client.request(s.peer, asks));
  await until(() => s.helper.got.requests.length === 3);
  s.world.access = "read";
  s.changed();
  await until(() => s.helper.got.closed === 3 && s.deadlines.length === 3);
  s.world.access = "full";
  const waiting = await s.client.request(s.peer, asks);
  assert.equal(waiting.status, 503, "their places are still taken, as they may yet read");
  for (const deadline of [...s.deadlines]) deadline();
  const after = await s.client.request(s.peer, asks);
  assert.equal(after.status, 200);
  s.mesh.cut();
});

test("the overview goes on to the admin API, nothing else of it does, and a bad credential gets nothing", async (t) => {
  const { client, peer } = await setup(t);
  const overview = await client.request(peer, { method: "GET", path: "/overview" });
  assert.equal(overview.status, 200);
  await answer(overview);
  const other = await client.request(peer, { method: "GET", path: "/sessions" });
  assert.equal(other.status, 403);
  await answer(other);
  const s = await setup(t, { credential: "not-a-credential" });
  await assert.rejects(s.client.request(s.peer, { method: "GET", path: "/screens" }), (error: MeshError) => error.code === "unauthorized");
});

test("a view is told how its connection runs now, which its bit rate goes by", async (t) => {
  const admissions = new DeviceMeshAdmissions();
  admissions.set({}, deviceMeshFacts({ workspace: WS, grant_keys: { keys: [GRANT.jwk] }, revocations: [], owner: "user_1", relay_urls: [] }));
  let via = "direct";
  const seen: (string | null)[] = [];
  const screens = {
    handle: (_admitted: unknown, _request: unknown, wayNow?: () => string | null) => {
      seen.push(wayNow?.() ?? null);
      via = "salix";
      seen.push(wayNow?.() ?? null);
      return Promise.resolve({ status: 200, headers: [["content-type", "application/json"]] as [string, string][], body: Buffer.from("{}") });
    },
  };
  const mesh = new MemoryMesh();
  const station = mesh.endpoint("station", [MESH_ALPN]);
  const app = mesh.endpoint("device");
  void (async () => {
    for (;;) {
      const connection = await station.accept();
      if (connection === null) return;
      void serveMeshConnection(connection, deviceServing({ admin: null, up: () => true, screens } as any, admissions, undefined, () => via));
    }
  })();
  const credential = GRANT.credential({ typ: COMMA.credential.types[0] }, { iss: COMMA.credential.issuers[0], ws: WS, device: "device", sub: "user_1", email: "m@example.com", name: "M", role: "member", sid: "sess_1", iat: ISSUED, exp: EXPIRES });
  const client = new MeshClient({ endpoint: app, credential: async () => credential });
  t.after(async () => {
    client.close();
    await Promise.all([app.close(), station.close()]);
  });
  await answer(await client.request({ id: "station" }, { method: "GET", path: "/screens" }));
  assert.deepEqual(seen, ["direct", "salix"]);
});

test("the pointer and how the pictures are made, as the helper says them", async (t) => {
  const { client, peer, helper } = await setup(t);
  const view = await openView(client, peer);
  await until(() => helper.got.conns.length === 1);
  const conn = helper.got.conns[0]!;
  // The encoder as the helper's info names it: said with the first state.
  await until(() => view.states().some((s) => s.video));
  assert.deepEqual(view.states().find((s) => s.video).video, { capture: "ScreenCaptureKit", encoder: INFO.encoder, hardware: true });
  // The pointer as it moves and changes shape; a shape no CSS cursor has is the arrow, a place off the picture nothing.
  for (const said of [{ x: 0.25, y: 0.5, shape: "default" }, { x: 2, y: 0.5, shape: "text" }, { x: 0.3, y: 0.5, shape: "text" }, { x: 0.3, y: 0.5, shape: "<b>" }, { x: 0.3, y: 0.6, shape: "none" }]) conn.write(json(6, said));
  await until(() => view.states().filter((s) => s.cursor).length === 4);
  assert.deepEqual(view.states().filter((s) => s.cursor).map((s) => s.cursor), [{ x: 0.25, y: 0.5, shape: "default" }, { x: 0.3, y: 0.5, shape: "text" }, { x: 0.3, y: 0.5, shape: "default" }, { x: 0.3, y: 0.6, shape: "none" }]);
  // The helper's encoder made anew without low latency (its first frame failed): a new info before its config, and the
  // statistics say the encoder it has now.
  await helper.give(conn, json(1, { width: 1280, height: 800, codec: "h264", encoder: "hardware, H264_ConstrainedBaseline_AutoLevel, 1500000 bps" }), config(1280, 800), frame(true, 1000, 1));
  await until(() => view.states().filter((s) => s.video).length === 2);
  assert.deepEqual(view.states().filter((s) => s.video).at(-1).video, { capture: "ScreenCaptureKit", encoder: "hardware, H264_ConstrainedBaseline_AutoLevel, 1500000 bps", hardware: true });
  assert.equal(view.configs()[0].codec, "h264");
  view.finish();
  // A software encoder says so.
  const soft = await setup(t, { first: { ...INFO, encoder: "software, H264_Baseline_AutoLevel, 1500000 bps" } });
  const other = await openView(soft.client, soft.peer);
  await until(() => other.states().some((s) => s.video));
  assert.equal(other.states().find((s) => s.video).video.hardware, false);
  other.finish();
});

test("a preview is asked of a screen that says it can be, and neither of the helper's does", async (t) => {
  const { client, peer, helper } = await setup(t);
  const listed = await answer(await client.request(peer, { method: "GET", path: "/screens" }));
  assert.ok(listed.screens.every((screen: { peek?: boolean }) => screen.peek === undefined));
  for (const id of ["display", "app"]) {
    const refused = await client.request(peer, { method: "POST", path: `/screens/${id}/view`, headers: [[SCREEN_HEADER, '{"codecs":["h264"],"peek":true}']] });
    assert.equal(refused.status, 501);
    await answer(refused);
  }
  assert.equal(helper.got.conns.length, 0, "the display is not touched");
});

test("a view ends when its credential does, and takes no input after", async (t) => {
  // The time stands still until the view is up, then passes the credential's end: the view's own timer finds it so.
  const start = 1_800_000_000;
  t.mock.timers.enable({ apis: ["Date"], now: start * 1000 });
  const s = await setup(t, { exp: start + 1 });
  const view = await openView(s.client, s.peer);
  await until(() => s.helper.got.conns.length === 1 && s.helper.got.requests.length === 1);
  t.mock.timers.setTime((start + 2) * 1000);
  await until(() => s.helper.got.closed === 1);
  await view.read;
  assert.match(view.states().at(-1).ended, /expired/);
  view.send(encodeScreenJson(ScreenKind.input, { type: "move", x: 0, y: 0, mods: [] }));
  assert.equal(s.helper.got.said.filter((said) => said.type === "move").length, 0);
});

test("a view says which app it really shows and how many of its windows are on screen, and when that changes", async (t) => {
  const s = await setup(t, { first: { ...INFO, geometry: { target: "app", apps: ["Calculator"], windows: 1, x: 0, y: 0, width: 800, height: 600, control: true } } });
  const view = await openView(s.client, s.peer);
  await until(() => s.helper.got.conns.length === 1 && s.helper.got.requests.length === 1);
  await until(() => view.states().some((state: { apps?: string[] }) => state.apps !== undefined));
  const said = view.states().find((state: { apps?: string[] }) => state.apps);
  assert.deepEqual([said.apps, said.windows], [["Calculator"], 1]);
  s.helper.got.conns[0]!.write(json(64, { target: "app", apps: ["Calculator"], windows: 0, x: 0, y: 0, width: 1440, height: 900, control: true }));
  await until(() => view.states().some((state: { windows?: number }) => state.windows === 0));
  view.finish();
});

test("a view says it is alive, so a still screen is told from a dead one", async (t) => {
  const s = await setup(t);
  const view = await openView(s.client, s.peer);
  await until(() => s.helper.got.conns.length === 1 && s.helper.got.requests.length === 1);
  await until(() => view.states().some((state: { alive?: boolean }) => state.alive === true));
  view.finish();
});

test("a view's ask: its 画质 among those known, none for a preview's, and an ask without one is 自动", () => {
  // Ported from still.fail's station/test/screens.test.ts (afk/main 0a70d5e9d0, `asked`), the ask in its header.
  const ask = (v: Record<string, unknown>) => askOf([[SCREEN_HEADER, JSON.stringify({ maxWidth: 1920, maxHeight: 1080, codecs: ["h265", "h264"], ...v })]]);
  assert.equal(ask({ quality: "original" })?.quality, "original");
  assert.equal(ask({ quality: "hd" })?.quality, "hd");
  assert.equal(ask({ quality: "smooth" })?.quality, "smooth");
  for (const quality of ["best", "auto", "HD", 3, null, { hd: true }]) assert.equal("quality" in ask({ quality })!, false, JSON.stringify(quality));
  assert.equal("quality" in ask({})!, false);
  assert.equal(ask({ quality: "original", peek: true })?.quality, undefined);
});

test("what a client says goes to the helper only as input: no command of the helper's own", () => {
  const press = { type: "down", x: 0.5, y: 0.5, button: 0, clicks: 2, mods: ["shift"] };
  assert.deepEqual(helperInput(press), press);
  for (const said of [{ type: "stop" }, { type: "bitrate", bitrate: 1 }, { type: "keyframe" }, null, "down"]) assert.equal(helperInput(said), null);
  // Text an IME composed or a paste carried: only the text, and none empty or past what one event carries.
  assert.deepEqual(helperInput({ type: "text", text: "你好", stop: true }), { type: "text", text: "你好" });
  for (const text of ["", "x".repeat(4097), 7, undefined]) assert.equal(helperInput({ type: "text", text }), null);
});

test("a view's inputs reach its source in order, each once the one before was posted", async (t) => {
  const posted: string[] = [];
  let release!: () => void;
  const held = new Promise<void>((resolve) => (release = resolve));
  let ended!: () => void;
  let keyframes = 0;
  const source: ScreenSource = {
    id: "display",
    kind: "desktop",
    open: async () => ({
      next: () => new Promise((resolve) => (ended = () => resolve(null))),
      keyframe() {
        keyframes += 1;
        changed();
      },
      async input(event: ScreenInput) {
        const said = (event as { type: string }).type;
        posted.push(`${said} began`);
        changed();
        // The first waits as a slow source would (a rotate waiting for adb).
        if (said === "down") await held;
        posted.push(`${said} done`);
        changed();
      },
      close: () => ended?.(),
    }),
  };
  const s = await setup(t, { helper: false, sources: [source] });
  const view = await openView(s.client, s.peer);
  view.send(encodeScreenJson(ScreenKind.input, { type: "down", x: 0.5, y: 0.5, button: 0, clicks: 1, mods: [] }));
  view.send(encodeScreenJson(ScreenKind.input, { type: "text", text: "粘贴" }));
  await until(() => posted.length === 1);
  view.send(encodeScreenJson(ScreenKind.input, { type: "up", x: 0.5, y: 0.5, button: 0, clicks: 1, mods: [] }));
  // A key frame asked after them is heard once the inputs before it were read: none of them was posted yet.
  view.send(encodeScreenFrame(ScreenKind.keyframe));
  await until(() => keyframes === 1);
  assert.deepEqual(posted, ["down began"]);
  release();
  await until(() => posted.length === 6);
  assert.deepEqual(posted, ["down began", "down done", "text began", "text done", "up began", "up done"]);
  view.finish();
});

// ── the clipboard and the system output (still.fail's station/test/screens.test.ts, "the clipboard …", "the Mac's
// desktop sends its system output …", on Cue's views and their in-place Watch and Control) ──

test("the Mac's desktop sends its system output to a view that asked for it, pulled packet by packet; never to one that did not, nor to a preview", async (t) => {
  const s = await setup(t);
  // Watch or Control alike: one that only looks hears it too (still.fail's rule).
  const view = await openView(s.client, s.peer, { codecs: ["h264"], control: false, audio: "pcm_s16le" });
  await until(() => s.helper.got.requests.length === 1);
  assert.equal(s.helper.got.requests[0]!.view.audio, true);
  await until(() => view.audios().length >= 2);
  // Its format before its first packet, then each packet as the helper captured it.
  const kinds = view.kinds().filter((k) => k === ScreenKind.audioConfig || k === ScreenKind.audio);
  assert.deepEqual(kinds.slice(0, 3), [ScreenKind.audioConfig, ScreenKind.audio, ScreenKind.audio]);
  const audioConfig = view.frames.find((f) => f.kind === ScreenKind.audioConfig)!;
  assert.deepEqual(JSON.parse(Buffer.from(audioConfig.payload).toString("utf8")), { codec: "pcm_s16le", sampleRate: 48000, channels: 2 });
  for (const [i, packet] of view.audios().slice(0, 2).entries()) {
    assert.equal(packet.ts, 1_000_000 + (i + 1) * 20_000);
    assert.deepEqual(Buffer.from(packet.data), Buffer.alloc(3840, i + 1));
  }
  view.finish();
  await until(() => s.helper.got.closed === 1);

  // Not asked: the helper is not asked to capture it, and none is pulled.
  const asked = s.helper.got.audios;
  const quiet = await openView(s.client, s.peer, { codecs: ["h264"], control: true });
  await until(() => s.helper.got.requests.length === 2);
  assert.equal(s.helper.got.requests[1]!.view.audio, undefined);
  await s.helper.give(s.helper.got.conns[1]!, config(64, 48), frame(true, 1000, 1));
  await until(() => quiet.videos().length === 1);
  assert.equal(s.helper.got.audios, asked, "no audio pulled from a view that did not ask");
  assert.deepEqual(quiet.audios(), []);
  quiet.finish();
  await until(() => s.helper.got.closed === 2);

  // A preview never asks for it, whatever it says.
  const display = helperSources(() => s.helpers.current())[1]!;
  const peek = await display.open({ maxWidth: 640, maxHeight: 360, codecs: ["h264"], audio: true, peek: true });
  await until(() => s.helper.got.requests.length === 3);
  assert.equal(s.helper.got.requests[2]!.view.audio, undefined);
  assert.equal(await peek.nextAudio!(), null);
  peek.close();
});

test("a view that takes Opus gets the helper's Opus packets, and none while its sound is off", async (t) => {
  const s = await setup(t);
  const view = await openView(s.client, s.peer, { codecs: ["h264"], control: false, audio: "opus" });
  await until(() => s.helper.got.requests.length === 1);
  assert.equal(s.helper.got.requests[0]!.view.audioCodec, "opus");
  await until(() => view.audios().length >= 2);
  const audioConfig = view.frames.find((f) => f.kind === ScreenKind.audioConfig)!;
  assert.deepEqual(JSON.parse(Buffer.from(audioConfig.payload).toString("utf8")), { codec: "opus", sampleRate: 48000, channels: 2 });
  assert.deepEqual(Buffer.from(view.audios()[0]!.data), Buffer.alloc(160, 1));

  // Muted: once the station has read it (a `control` sent after it is answered), at most the packet already asked
  // comes, and nothing more is asked of the helper, over two more answered round trips; on again, it goes on.
  const answered = async () => {
    const states = view.states().length;
    view.send(encodeScreenControl(false));
    await until(() => view.states().length > states);
  };
  view.send(encodeScreenSound(false));
  await answered();
  const asked = s.helper.got.audios;
  await answered();
  await answered();
  assert.ok(s.helper.got.audios <= asked + 1, `asked ${s.helper.got.audios - asked} more while muted`);
  const heard = view.audios().length;
  view.send(encodeScreenSound(true));
  await until(() => view.audios().length > heard + 1);
  view.finish();
});

test("the clipboard goes both ways only while the view drives: watched from Control, let go at Watch, a paste in order after the keys before it", async (t) => {
  const { client, peer, helper } = await setup(t);
  const view = await openView(client, peer, { codecs: ["h264"], control: false });
  await until(() => helper.got.requests.length === 1 && view.states().length === 1);
  const conn = helper.got.conns[0]!;
  /// What reached the helper after `send`, once a key frame asked after it did (the helper hears in order).
  const heard = async (send: () => void) => {
    const was = helper.got.said.length;
    send();
    view.send(encodeScreenFrame(ScreenKind.keyframe));
    await until(() => helper.got.said.at(-1)?.type === "keyframe" && helper.got.said.length > was);
    return helper.got.said.slice(was, -1);
  };
  const copy = (text: string) => conn.write(message(5, Buffer.concat([Buffer.from([1]), Buffer.from(text, "utf8")])));
  /// The helper's copy, then its pointer: once the pointer came, the copy would have before it.
  const copied = async (text: string, x: number) => {
    copy(text);
    conn.write(json(6, { x, y: 0.5, shape: "default" }));
    await until(() => view.states().some((state) => state.cursor?.x === x));
  };

  // Watching: not watched, so nothing of the Mac's clipboard is looked at, and a paste is dropped.
  assert.deepEqual(helper.got.watches, []);
  assert.deepEqual(await heard(() => view.send(encodeScreenClip({ type: "text", text: "nope" }, true))), []);

  // Control: watched; a copy on the Mac comes to the client (text, a picture).
  view.send(encodeScreenControl(true));
  await until(() => helper.got.watches.length === 1);
  assert.deepEqual(helper.got.watches, [1]);
  await copied("复制的", 0.1);
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
  conn.write(message(5, Buffer.concat([Buffer.from([2]), png])));
  await until(() => view.clips().length === 2);
  assert.deepEqual(view.clips(), [{ type: "text", text: "复制的" }, { type: "png", data: new Uint8Array(png) }]);

  // A paste: after the key before it, then a picture set without a paste.
  const meta = { type: "keydown", code: "MetaLeft", key: "Meta", mods: ["meta"] };
  assert.deepEqual(
    await heard(() => {
      view.send(encodeScreenJson(ScreenKind.input, meta));
      view.send(encodeScreenClip({ type: "text", text: "粘贴的" }, true));
      view.send(encodeScreenClip({ type: "png", data: png }, false));
    }),
    [meta, { clip: Buffer.concat([Buffer.from([1, 1]), Buffer.from("粘贴的", "utf8")]) }, { clip: Buffer.concat([Buffer.from([0, 2]), png]) }],
  );

  // Watch again: no longer watched; a copy made now does not come, a paste is dropped.
  view.send(encodeScreenControl(false));
  await until(() => helper.got.watches.length === 2);
  assert.deepEqual(helper.got.watches, [1, 0]);
  await copied("after", 0.2);
  assert.equal(view.clips().length, 2);
  assert.deepEqual(await heard(() => view.send(encodeScreenClip({ type: "text", text: "nope" }, true))), []);
  // Control once more: watched again, on the same capture.
  view.send(encodeScreenControl(true));
  await until(() => helper.got.watches.length === 3);
  assert.equal(helper.got.conns.length, 1);
  view.finish();
});

test("the clipboard's bounds and types: past its bound or of a type the source does not carry, dropped; a frame past the most ends the view", async (t) => {
  const asks: { clip: unknown; paste: boolean }[] = [];
  let copied: ((clip: any) => void) | null = null;
  let ended!: () => void;
  let closed = false;
  const source: ScreenSource = {
    id: "display",
    kind: "desktop",
    clipboard: () => ["text"],
    open: async () => ({
      next: () => new Promise((resolve) => (ended = () => resolve(null))),
      keyframe: () => {},
      async input() {},
      async setClipboard(clip, paste) {
        asks.push({ clip, paste });
        changed();
      },
      watchClipboard(heard) {
        copied = heard;
        return () => (copied = null);
      },
      close: () => {
        closed = true;
        ended?.();
        changed();
      },
    }),
  };
  const s = await setup(t, { helper: false, sources: [source] });
  const view = await openView(s.client, s.peer);
  await until(() => copied !== null);
  // A picture to a source of text only; text past 1 MB; no type; nothing; then one within bounds.
  const clipFrame = (flags: number, type: number, body: Buffer) => encodeScreenFrame(ScreenKind.setClipboard, Buffer.concat([Buffer.from([flags, type]), body]));
  view.send(clipFrame(1, 2, Buffer.from([0x89, 0x50, 0x4e, 0x47])));
  view.send(clipFrame(1, 1, Buffer.alloc(CLIP_TEXT_MAX + 1, 0x61)));
  view.send(clipFrame(1, 9, Buffer.from("x")));
  view.send(clipFrame(1, 1, Buffer.alloc(0)));
  view.send(clipFrame(1, 1, Buffer.alloc(CLIP_TEXT_MAX, 0x62)));
  await until(() => asks.length === 1);
  assert.deepEqual([(asks[0]!.clip as { type: string }).type, (asks[0]!.clip as { text: string }).text.length, asks[0]!.paste], ["text", CLIP_TEXT_MAX, true]);
  // A copy past its bound is not sent; one of a type not carried is not either.
  copied!({ type: "text", text: "a".repeat(CLIP_TEXT_MAX + 1) });
  copied!({ type: "png", data: new Uint8Array([1]) });
  copied!({ type: "text", text: "fits" });
  await until(() => view.clips().length === 1);
  assert.deepEqual(view.clips(), [{ type: "text", text: "fits" }]);
  // A clipboard frame may be a picture's size (an input frame may not); past it, the view ends.
  const head = Buffer.alloc(5);
  head[0] = ScreenKind.setClipboard;
  head.writeUInt32BE(MAX_CLIP_IN + 1, 1);
  view.send(head);
  await until(() => closed);
  assert.equal(asks.length, 1);
  assert.equal(copied, null, "no longer watched once the view ended");
});

test("Windows' display carries its clipboard and system output through its process: a copy said, a paste set, packets pulled one at a time", async (t) => {
  const fake = fakeScreen();
  const desktop = new WindowsDesktop({ binary: "comma-desktop-screen.exe", start: fake.start });
  t.after(async () => (await desktop.close(), fake.done()));
  const s = await setup(t, { helper: false, sources: [desktop] });
  const view = await openView(s.client, s.peer, { codecs: ["h264"], control: true, audio: "pcm_s16le" });
  await until(() => view.audios().length >= 2 && view.clips().length === 1);
  assert.deepEqual(fake.lines()[0], { codec: "h264", audio: true, maxWidth: 1920, maxHeight: 1080, bitrate: START_RATE });
  assert.deepEqual(view.audios().slice(0, 2).map((a) => [a.ts, a.data[0]]), [[20_000, 1], [40_000, 2]]);
  // The process copies as soon as it is watched (the fake's), and the view hears it.
  assert.deepEqual(view.clips(), [{ type: "text", text: "复制的" }]);
  view.send(encodeScreenClip({ type: "text", text: "粘贴的" }, true));
  await until(() => fake.lines().some((line: { clip?: unknown }) => line.clip));
  assert.deepEqual(fake.lines().find((line: { clip?: unknown }) => line.clip), { clip: 1, paste: true, text: "粘贴的" });
  assert.deepEqual(fake.lines().filter((line: { watch?: unknown }) => "watch" in line), [{ watch: 1 }]);
  view.finish();
  await view.read;
});

test("Windows' display gives its system output as Opus to a view that asked it", async (t) => {
  const fake = fakeScreen();
  const desktop = new WindowsDesktop({ binary: "comma-desktop-screen.exe", start: fake.start });
  t.after(async () => (await desktop.close(), fake.done()));
  const s = await setup(t, { helper: false, sources: [desktop] });
  const view = await openView(s.client, s.peer, { codecs: ["h264"], control: false, audio: "opus" });
  await until(() => view.audios().length >= 2);
  assert.deepEqual(fake.lines()[0], { codec: "h264", audio: true, audioCodec: "opus", maxWidth: 1920, maxHeight: 1080, bitrate: START_RATE });
  const audioConfig = view.frames.find((f) => f.kind === ScreenKind.audioConfig)!;
  assert.deepEqual(JSON.parse(Buffer.from(audioConfig.payload).toString("utf8")), { codec: "opus", sampleRate: 48000, channels: 2 });
  assert.deepEqual(view.audios().slice(0, 2).map((a) => [a.ts, a.data.length, a.data[0]]), [[20_000, 160, 1], [40_000, 160, 2]]);
  view.finish();
  await view.read;
});

test("Windows' display end to end: listed, viewed through a comma-desktop-screen process, its pointer said as the view's state, input posted as Windows does", async (t) => {
  const fake = fakeScreen();
  const desktop = new WindowsDesktop({ binary: "comma-desktop-screen.exe", start: fake.start });
  t.after(async () => (await desktop.close(), fake.done()));
  const s = await setup(t, { helper: false, sources: [desktop] });
  assert.deepEqual((await answer(await s.client.request(s.peer, { method: "GET", path: "/screens" }))).screens, [{ id: "display", kind: "desktop", clipboard: ["text", "png"] }]);
  // A client that takes H.265 gets it from a source that makes it.
  const view = await openView(s.client, s.peer, { codecs: ["h265", "h264"], control: true, maxWidth: 2560, maxHeight: 1600 });
  assert.equal(view.response.status, 200);
  await until(() => view.videos().length === 1);
  assert.deepEqual(fake.lines()[0], { codec: "h265", maxWidth: 2560, maxHeight: 1600, bitrate: START_RATE });
  assert.equal(view.configs()[0].codec, "h265");
  await until(() => view.states().some((state: { cursor?: unknown }) => state.cursor !== undefined));
  assert.deepEqual(view.states().find((state: { cursor?: unknown }) => state.cursor).cursor, { x: 0.5, y: 0.25, shape: "text" });
  view.send(encodeScreenJson(ScreenKind.input, { type: "move", x: 0.25, y: 0.75, mods: [] }));
  view.send(encodeScreenJson(ScreenKind.input, { type: "stop" }));
  view.send(encodeScreenAck(view.videos()[0]!.ts));
  // The pointer moved there (the process says it once it posted the move).
  await until(() => view.states().some((state: { cursor?: { x: number; y: number } }) => state.cursor?.x === 0.25 && state.cursor.y === 0.75));
  assert.deepEqual(fake.lines().filter((line: { op?: string }) => line.op), [{ op: "mouse", type: "move", x: 0.25, y: 0.75, button: 0 }]);
  view.finish();
  await view.read;
  assert.equal(view.states().at(-1).ended, "finished");
});

test("Windows' display goes by the view's Watch and Control: input dropped while it watches, posted after an in-place switch to Control, refused to one who may not drive", async (t) => {
  const fake = fakeScreen();
  const desktop = new WindowsDesktop({ binary: "comma-desktop-screen.exe", start: fake.start });
  t.after(async () => (await desktop.close(), fake.done()));
  const s = await setup(t, { helper: false, sources: [desktop] });
  const view = await openView(s.client, s.peer, { codecs: ["h264"], control: false });
  await until(() => view.videos().length === 1);
  view.send(encodeScreenAck(view.videos()[0]!.ts));
  assert.equal(view.states()[0].control, false);
  const move = (x: number) => encodeScreenJson(ScreenKind.input, { type: "move", x, y: 0.5, mods: [] });
  /// The pointer the process says once it posted a move there (the fake's follows each one, in order).
  const pointedAt = (x: number) => view.states().some((state: { cursor?: { x: number } }) => state.cursor?.x === x);
  const posted = () => fake.lines().filter((line: { op?: string }) => line.op === "mouse").map((line: { x: number }) => line.x);

  // Watching: dropped. Switched to Control on the same view: the next move is posted.
  view.send(move(0.1));
  view.send(encodeScreenControl(true));
  view.send(move(0.2));
  await until(() => pointedAt(0.2));
  // Back to Watch, then Control again: only the move made while driving went.
  view.send(encodeScreenControl(false));
  view.send(move(0.3));
  view.send(encodeScreenControl(true));
  view.send(move(0.4));
  await until(() => pointedAt(0.4));
  assert.deepEqual(posted(), [0.2, 0.4]);
  assert.deepEqual(view.states().filter((state) => "control" in state).map((state) => state.control), [false, true, false, true]);

  // One who may no longer drive: Control is refused and nothing goes, the picture still on.
  view.send(encodeScreenControl(false));
  s.world.drive = false;
  const was = view.states().length;
  view.send(encodeScreenControl(true));
  await until(() => view.states().slice(was).some((state) => "refused" in state));
  view.send(move(0.5));
  s.world.drive = true;
  view.send(encodeScreenControl(true));
  view.send(move(0.6));
  await until(() => pointedAt(0.6));
  assert.deepEqual(posted(), [0.2, 0.4, 0.6]);
  // One process the whole time: the switches start no new capture.
  assert.equal(fake.started.filter((args) => args[0] === "view").length, 1);
  view.finish();
});

test("a client that gives up while its view opens frees its place then, not once the screen has opened", async (t) => {
  // A phone's view takes seconds to open; a person who chose another screen meanwhile is not held to it.
  let release = () => {};
  const gate = new Promise<void>((resolve) => (release = resolve));
  let started = 0;
  const s = await setup(t, {
    ensure: () => {
      started++;
      changed();
      return gate;
    },
  });
  const asks = { method: "POST", path: "/screens/display/view", headers: [[SCREEN_HEADER, '{"codecs":["h264"]}']] as [string, string][], body: (async function* () { await new Promise(() => {}); })() };
  const opening = [];
  for (let i = 0; i < 3; i++) {
    const stop = new AbortController();
    opening.push({ stop, answer: s.client.request(s.peer, asks, stop.signal).catch((error: unknown) => error) });
  }
  await until(() => started === 3);
  for (const view of opening) view.stop.abort();
  await Promise.all(opening.map((view) => view.answer));
  // Each place is free though its screen is still opening.
  const next = s.client.request(s.peer, asks);
  let early: MeshResponse | undefined;
  void next.then((answered) => {
    early = answered;
    changed();
  });
  await until(() => started === 4 || early !== undefined);
  assert.equal(early?.status, undefined, "not refused while the others still open");
  release();
  const answered = await next;
  assert.equal(answered.status, 200);
  await until(() => s.helper.got.closed === 3);
  answered.cancel();
});

/// A simulator listed with its app's logs, their process played by the test (screens/app-logs.ts).
function loggedDevice() {
  const runs: { said: (line: AppLogSaid) => void; ended: () => void; stopped: boolean }[] = [];
  const logs = new AppLogs(() => (said, ended) => {
    const run = { said, ended, stopped: false };
    runs.push(run);
    changed();
    return { stop: () => void ((run.stopped = true), changed()) };
  });
  const source: ScreenSource = { id: "simulator:U", kind: "simulator", instance: "i1", name: "Demo", title: () => "Demo", size: () => ({ width: 100, height: 200 }), panels: [], logs, open: async () => { throw new Error("no picture here"); } };
  const line = (text: string, crash = false): AppLogSaid => ({ at: "", level: "Default", app: "Demo", text, ...(crash ? { crash: true as const } : {}) });
  return { source, runs, logs, line };
}

/// A device's app logs as a viewer reads them: its `state` frames as they come.
async function openLogs(client: MeshClient, peer: { id: string }, query = "mode=app&instance=i1", id = "simulator:U") {
  let finished = false;
  let wake = () => {};
  const body = (async function* () {
    while (!finished) await new Promise<void>((resolve) => (wake = resolve));
  })();
  const response = await client.request(peer, { method: "POST", path: `/screens/${encodeURIComponent(id)}/logs?${query}`, body });
  const states: Record<string, any>[] = [];
  const reader = new ScreenFrameReader(16 << 20);
  const read = response.status !== 200 ? Promise.resolve() : (async () => {
    for await (const chunk of response.body) {
      for (const f of reader.push(chunk)) if (f.kind === ScreenKind.state) states.push(JSON.parse(Buffer.from(f.payload).toString("utf8")));
      changed();
    }
  })().catch(() => {});
  return { response, states, read, texts: () => states.flatMap((s) => (s.lines ?? []).map((l: { text: string }) => l.text)), finish: () => ((finished = true), wake()) };
}

test("a device's app logs: listed, read as they come, a later reader given what was held, the process stopped when the last panel closes", async (t) => {
  const device = loggedDevice();
  const s = await setup(t, { sources: [device.source] });
  const listed = await answer(await s.client.request(s.peer, { method: "GET", path: "/screens?devices=1" }));
  assert.equal(listed.screens.find((one: { id: string }) => one.id === "simulator:U").capabilities.logs, true);
  assert.equal(listed.screens.find((one: { id: string }) => one.id === "display").capabilities, undefined, "a computer's screen has none");

  const first = await openLogs(s.client, s.peer);
  assert.equal(first.response.status, 200);
  await until(() => device.runs.length === 1 && first.states.length >= 1);
  assert.deepEqual(first.states[0], { logs: { mode: "app" } });
  device.runs[0]!.said(device.line("one"));
  device.runs[0]!.said(device.line("it crashed", true));
  await until(() => first.texts().length === 2);
  assert.equal(first.states.flatMap((one) => one.lines ?? []).find((l) => l.crash)?.text, "it crashed");

  const late = await openLogs(s.client, s.peer);
  await until(() => late.texts().length === 2);
  assert.deepEqual(late.texts(), ["one", "it crashed"]);
  assert.equal(device.runs.length, 1, "one process for both readers");

  first.finish();
  await first.read;
  assert.equal(first.states.at(-1)!.ended, "finished");
  assert.equal(device.runs[0]!.stopped, false, "another still reads");
  late.finish();
  await late.read;
  await until(() => device.runs[0]!.stopped);
});

test("app logs only to one who may drive this computer while its access is Full, of the instance listed, with a filter that is one", async (t) => {
  const device = loggedDevice();
  const s = await setup(t, { sources: [device.source] });
  s.world.drive = false;
  assert.equal((await openLogs(s.client, s.peer)).response.status, 403);
  s.world.drive = true;
  s.world.access = "read";
  assert.equal((await openLogs(s.client, s.peer)).response.status, 403);
  s.world.access = "full";
  assert.equal((await openLogs(s.client, s.peer, "mode=app&instance=i0")).response.status, 409, "another boot of it");
  assert.equal((await openLogs(s.client, s.peer, "mode=app&instance=i1&app=a;rm")).response.status, 400);
  assert.equal((await openLogs(s.client, s.peer, "mode=app", "display")).response.status, 405, "a computer's screen has no app logs");
  // A member who is not its owner: refused before any screen is named.
  const other = await setup(t, { sub: "user_3", sources: [device.source] });
  await assert.rejects(openLogs(other.client, other.peer), (error: MeshError) => error.code === "unauthorized" && /owner/.test(error.message));
  assert.equal(device.runs.length, 0, "no process was started");
});

test("app logs end when what allowed them goes, or the device does, and its process stops", async (t) => {
  const device = loggedDevice();
  const s = await setup(t, { sources: [device.source] });
  const reading = await openLogs(s.client, s.peer);
  await until(() => device.runs.length === 1);
  s.world.access = "read";
  s.changed();
  await reading.read;
  assert.equal(reading.states.at(-1)!.ended, "access changed");
  assert.equal(device.runs[0]!.stopped, true);

  s.world.access = "full";
  const again = await openLogs(s.client, s.peer, "mode=all&instance=i1");
  await until(() => device.runs.length === 2);
  device.logs.close();
  await again.read;
  assert.equal(again.states.at(-1)!.ended, "the device is gone");
  assert.equal(device.runs[1]!.stopped, true);
});

test("a client that reads none of its app logs has at most one word of being alive waiting for it", async (t) => {
  const device = loggedDevice();
  // (a window of a few bytes: what the station writes waits once the client has not read it)
  const s = await setup(t, { sources: [device.source], window: 64 });
  let finish = () => {};
  const body = (async function* () {
    await new Promise<void>((resolve) => (finish = resolve));
  })();
  const response = await s.client.request(s.peer, { method: "POST", path: `/screens/${encodeURIComponent("simulator:U")}/logs?mode=app&instance=i1`, body });
  assert.equal(response.status, 200);
  // Its heartbeat comes due many times while nothing is read.
  for (let i = 0; i < 50; i++) {
    await until(() => s.deadlines.length > 0);
    s.deadlines.shift()!();
  }
  finish();
  const states: Record<string, unknown>[] = [];
  const reader = new ScreenFrameReader(16 << 20);
  for await (const chunk of response.body) for (const f of reader.push(chunk)) if (f.kind === ScreenKind.state) states.push(JSON.parse(Buffer.from(f.payload).toString("utf8")));
  // (those the window took before it was full, and the one that waited: not one for each time it came due)
  const alive = states.filter((one) => one.alive).length;
  assert.ok(alive <= 5, `alive words: ${alive}`);
  assert.equal(states.at(-1)!.ended, "finished");
});
