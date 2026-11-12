// A Linux computer's desktop end to end, in memory: `MeshClient` on @comma/mesh's memory mesh, a desktop's own station
// (mesh/comma.ts `deviceServing`) with a real member credential for its owner, the view (mesh/screens.ts) and the X11
// desktop (screens/x11-desktop.ts). On any machine with fake ffmpeg and xdotool (linux-screen-fakes.ts); with
// COMMA_TEST_X11=1, also on a real, disposable X server (never a person's desktop): `DISPLAY` names it, and ffmpeg
// (with libx264), xdotool and xev are on the PATH. Ported from still.fail's station/test/x11-desktop.test.ts (its view
// over the screen wire), on Cue's mesh and with Cue's wire input.
import assert from "node:assert/strict";
import { execFile, spawn, spawnSync } from "node:child_process";
import { watch } from "node:fs";
import { test, type TestContext } from "node:test";
import { promisify } from "node:util";
import { MESH_ALPN, MeshClient, type MeshResponse, SCREEN_HEADER, ScreenFrameReader, ScreenKind, encodeScreenAck, encodeScreenControl, encodeScreenJson, parseScreenVideo, serveMeshConnection } from "@comma/mesh";
import { MemoryMesh } from "@comma/mesh/testing";
import { makeScreenViews } from "../src/mesh/screens.ts";
import { deviceServing } from "../src/mesh/comma.ts";
import { DeviceMeshAdmissions, deviceMeshFacts } from "../src/mesh/device-mesh.ts";
import type { Access } from "../src/device/access.ts";
import type { ScreenSource } from "../src/screens/source.ts";
import { X11Desktop } from "../src/screens/x11-desktop.ts";
import { COMMA } from "../src/cloud/provider.ts";
import { GrantKey } from "./fake-control-plane.ts";
import { fakeX11Tools } from "./linux-screen-fakes.ts";

const run = promisify(execFile);
const realX11 = process.env.COMMA_TEST_X11 === "1";

let waiting: (() => void)[] = [];
const changed = () => {
  const woken = waiting;
  waiting = [];
  for (const wake of woken) wake();
};
async function until(what: () => boolean) {
  while (!what()) await new Promise<void>((resolve) => waiting.push(resolve));
}

const GRANT = new GrantKey();
const WS = "ws_1";
const ISSUED = 1_700_000_000;

/// A station serving Comma's mesh with this desktop as its only screen, and its owner's client on it.
async function setup(t: TestContext, desktop: ScreenSource, sub = "user_1") {
  const world = { access: "full" as Access, drive: true };
  const admissions = new DeviceMeshAdmissions();
  admissions.set({}, deviceMeshFacts({ workspace: WS, grant_keys: { keys: [GRANT.jwk] }, revocations: [], owner: "user_1", relay_urls: [] }));
  const changes = new Set<() => void>();
  const screens = makeScreenViews({
    sources: () => [desktop],
    access: () => world.access,
    up: () => true,
    mayView: (member) => admissions.mayView(member),
    mayControl: (member) => world.drive && admissions.mayControl(member),
    listen: (f) => {
      changes.add(f);
      return () => void changes.delete(f);
    },
    after: () => () => {},
  });
  const admin = { handle: async () => ({ status: 200, headers: {}, body: Buffer.from("{}") }) };
  const mesh = new MemoryMesh();
  const station = mesh.endpoint("station", [MESH_ALPN]);
  const app = mesh.endpoint("device");
  void (async () => {
    for (;;) {
      const connection = await station.accept();
      if (connection === null) return;
      void serveMeshConnection(connection, deviceServing({ admin, up: () => true, screens } as any, admissions));
    }
  })();
  const credential = GRANT.credential({ typ: COMMA.credential.types[0] }, { iss: COMMA.credential.issuers[0], ws: WS, device: "device", sub, email: "m@example.com", name: "M", role: "member", sid: "sess_1", iat: ISSUED, exp: ISSUED + 365 * 86400 * 100 });
  const client = new MeshClient({ endpoint: app, credential: async () => credential });
  t.after(async () => {
    client.close();
    await Promise.all([app.close(), station.close()]);
  });
  return { client, peer: { id: "station" }, world, changed: () => changes.forEach((f) => f()) };
}

async function openView(client: MeshClient, peer: { id: string }, ask: Record<string, unknown>) {
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
  const response: MeshResponse = await client.request(peer, { method: "POST", path: "/screens/display/view", headers: [[SCREEN_HEADER, JSON.stringify(ask)]], body });
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
    read,
    videos: () => frames.filter((f) => f.kind === ScreenKind.video).map((f) => parseScreenVideo(f.payload)!),
    states: () => frames.filter((f) => f.kind === ScreenKind.state).map((f) => JSON.parse(Buffer.from(f.payload).toString("utf8"))),
    configs: () => frames.filter((f) => f.kind === ScreenKind.config).map((f) => JSON.parse(Buffer.from(f.payload).toString("utf8"))),
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
const input = (event: object) => encodeScreenJson(ScreenKind.input, event);

test("a Linux desktop end to end: listed as the display, viewed as H.264 from ffmpeg, input posted through xdotool only while the view drives", async (t) => {
  const fake = fakeX11Tools();
  const watching = watch(fake.log, changed);
  t.after(() => watching.close());
  const desktop = new X11Desktop({ env: fake.env, changed: () => {} });
  t.after(async () => (await desktop.close(), fake.done()));
  const s = await setup(t, desktop);
  assert.deepEqual((await answer(await s.client.request(s.peer, { method: "GET", path: "/screens" }))).screens, [{ id: "display", kind: "desktop" }]);

  const view = await openView(s.client, s.peer, { codecs: ["h265", "h264"], control: false, maxWidth: 640, maxHeight: 400 });
  assert.equal(view.response.status, 200);
  await until(() => view.videos().length === 1);
  const config = view.configs()[0];
  assert.deepEqual([config.codec, config.width, config.height], ["h264", 640, 400]);
  assert.ok(config.description, "the config carries the avcC");
  assert.equal(view.videos()[0]!.key, true);
  // Captured at the screen's size and scaled to the view's, at 15 frames a second at most.
  const capture = fake.lines().find((l) => l.ffmpeg?.includes("x11grab"))!.ffmpeg!;
  assert.deepEqual([capture[capture.indexOf("-video_size") + 1], capture[capture.indexOf("-framerate") + 1], capture[capture.indexOf("-i") + 1]], ["1280x800", "15", ":99"]);
  view.send(encodeScreenAck(view.videos()[0]!.ts));
  await until(() => view.videos().length >= 2);
  assert.equal(view.videos()[1]!.key, false);

  // Watching: dropped. Switched to Control in place: posted, as still.fail's X11Input posts it.
  view.send(input({ type: "move", x: 0.1, y: 0.1, mods: [] }));
  view.send(encodeScreenControl(true));
  view.send(input({ type: "move", x: 0.25, y: 0.5, mods: [] }));
  view.send(input({ type: "down", x: 0.25, y: 0.5, button: 0, clicks: 1, mods: [] }));
  view.send(input({ type: "move", x: 0.5, y: 0.5, mods: [] }));
  view.send(input({ type: "up", x: 0.5, y: 0.5, button: 0, clicks: 1, mods: [] }));
  view.send(input({ type: "scroll", x: 0.5, y: 0.5, dx: 0, dy: 300, mods: [] }));
  view.send(input({ type: "keydown", code: "KeyC", key: "c", mods: ["ctrl"] }));
  view.send(input({ type: "keyup", code: "KeyC", key: "c", mods: ["ctrl"] }));
  view.send(input({ type: "keydown", code: "", key: "é", mods: [] }));
  view.send(input({ type: "text", text: "你好" }));
  const expected = [
    "mousemove 320 400", "mousemove 320 400", "mousedown 1", "mousemove 640 400", "mousemove 640 400", "mouseup 1",
    "mousemove 640 400", "click --repeat 3 --delay 0 5",
    "keydown 37", "keydown 54", "keyup 37", "keyup 54",
    "type --delay 20 -- é", "type --delay 20 -- 你好",
  ];
  await until(() => fake.posted().length >= expected.length);
  assert.deepEqual(fake.posted(), expected);

  // One who may no longer drive: Control is refused, nothing more is posted, the picture goes on.
  view.send(encodeScreenControl(false));
  s.world.drive = false;
  view.send(encodeScreenControl(true));
  view.send(input({ type: "move", x: 0.9, y: 0.9, mods: [] }));
  await until(() => view.states().some((state) => "refused" in state));
  assert.deepEqual(fake.posted(), expected);
  view.finish();
  await view.read;
});

test("a Linux desktop is refused to a member who is not the computer's owner, and while its access is not Full", async (t) => {
  const fake = fakeX11Tools();
  const desktop = new X11Desktop({ env: fake.env, changed: () => {} });
  t.after(async () => (await desktop.close(), fake.done()));
  const stranger = await setup(t, desktop, "user_9");
  await assert.rejects(openView(stranger.client, stranger.peer, { codecs: ["h264"], control: true }), { code: "unauthorized" });
  const owner = await setup(t, desktop);
  owner.world.access = "read";
  const lowered = await openView(owner.client, owner.peer, { codecs: ["h264"], control: true });
  assert.equal(lowered.response.status, 403);
  // Neither started a capture.
  assert.equal(fake.lines().filter((l) => l.ffmpeg).length, 0);
});

/// Runs `args` until what it says passes `ok` (each run waits on the X server, nothing else).
async function untilSaid(args: string[], env: NodeJS.ProcessEnv, ok: (said: string) => boolean): Promise<string> {
  for (;;) {
    const said = (await run(args[0]!, args.slice(1), { env })).stdout;
    if (ok(said)) return said;
  }
}

test("a real X11 desktop over the mesh carries a decodable H.264 picture and takes a click and typed text", { skip: !realX11 }, async (t) => {
  const env = { ...process.env };
  // xev's window notes the keys it gets; xdotool focuses it as a click would.
  const observer = spawn("stdbuf", ["-oL", "xev", "-event", "keyboard"], { env });
  let observed = "";
  observer.stdout.on("data", (chunk: Buffer) => {
    observed += chunk.toString();
    changed();
  });
  const desktop = new X11Desktop({ env, changed: () => {} });
  t.after(async () => (await desktop.close(), observer.kill()));
  const window = (await untilSaid(["xdotool", "search", "--sync", "--name", "Event Tester"], env, (said) => said.trim() !== "")).trim().split("\n")[0]!;
  await run("xdotool", ["windowfocus", "--sync", window], { env });
  const s = await setup(t, desktop);
  const view = await openView(s.client, s.peer, { codecs: ["h264"], control: true, maxWidth: 640, maxHeight: 400 });
  assert.equal(view.response.status, 200);
  await until(() => view.videos().length === 1);
  const config = view.configs()[0];
  assert.equal(config.codec, "h264");
  // An independent decoder takes the avcC and the key frame (as Annex B).
  const avcC = Buffer.from(config.description, "base64");
  const START = Buffer.from([0, 0, 0, 1]);
  const annex: Buffer[] = [];
  let at = 6;
  for (let n = avcC[5]! & 31, sets = 0; sets < 2; sets++, n = avcC[at++]!) {
    for (; n > 0; n--) {
      const length = avcC.readUInt16BE(at);
      annex.push(START, avcC.subarray(at + 2, at + 2 + length));
      at += 2 + length;
    }
  }
  const picture = Buffer.from(view.videos()[0]!.data);
  for (let i = 0; i < picture.length; ) {
    const length = picture.readUInt32BE(i);
    annex.push(START, picture.subarray(i + 4, i + 4 + length));
    i += 4 + length;
  }
  const decoded = spawnSync("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "h264", "-i", "pipe:0", "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"], { input: Buffer.concat(annex), env, maxBuffer: 640 * 400 * 3 * 2 });
  assert.equal(decoded.status, 0, decoded.stderr.toString());
  assert.equal(decoded.stdout.length, 640 * 400 * 3);

  const { width, height } = desktop.size();
  view.send(input({ type: "move", x: 0.25, y: 0.35, mods: [] }));
  await untilSaid(["xdotool", "getmouselocation", "--shell"], env, (said) => said.includes(`X=${Math.round(0.25 * (width - 1))}\n`) && said.includes(`Y=${Math.round(0.35 * (height - 1))}\n`));
  view.send(input({ type: "keydown", code: "KeyA", key: "a", mods: [] }));
  view.send(input({ type: "keyup", code: "KeyA", key: "a", mods: [] }));
  view.send(input({ type: "text", text: "你好" }));
  await until(() => observed.includes("keysym 0x61, a") && observed.includes("KeyRelease event") && observed.includes("U4F60") && observed.includes("U597D"));
  view.finish();
  await view.read;
});
