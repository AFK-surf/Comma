// An iOS Simulator's screen end to end, in memory: `MeshClient` on @comma/mesh's memory mesh, the station's `comma/mesh/1`
// serving of a desktop's own station (mesh/comma.ts `deviceServing`) with a real credential for its owner, the view
// (mesh/screens.ts), and the simulator source (screens/simulator.ts) on a fake simctl and ps and a fake Computer Use
// helper on a Unix socket. Never a real simctl, simulator or helper.
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { MESH_ALPN, MeshClient, type MeshResponse, SCREEN_HEADER, SCREEN_LIST_WITH_DEVICES, ScreenFrameReader, ScreenKind, encodeScreenAck, encodeScreenControl, encodeScreenJson, parseScreenVideo, serveMeshConnection } from "@comma/mesh";
import { MemoryMesh } from "@comma/mesh/testing";
import { COMMA } from "../src/cloud/provider.ts";
import type { Access } from "../src/device/access.ts";
import { deviceServing } from "../src/mesh/comma.ts";
import { DeviceMeshAdmissions, deviceMeshFacts } from "../src/mesh/device-mesh.ts";
import { makeScreenViews } from "../src/mesh/screens.ts";
import { NOT_SERVED, screenLinksOf } from "../src/screens/links.ts";
import { SIMCTL, Simulators } from "../src/screens/simulator.ts";
import { SimulatorAgents } from "../src/screens/simulator-agent.ts";
import { type DeviceDebug, makeScreens } from "../src/screens/source.ts";
import { GrantKey } from "./fake-control-plane.ts";
import { compositeCase } from "./sim-chrome-fixture.ts";

const SKIP = { skip: process.platform === "win32" };
const BOOTED = "0702F8CC-2E2A-4D0A-8401-C37FA01E1646";
const SHUT = "FEF50280-1320-41CC-9F03-B3FA444053A7";
const WATCH = "7D47C5A6-FEC2-4BBD-8260-2089A5456797";
const ID = `simulator:${BOOTED}`;

/// What the tests wait on says it changed here. A wait has no deadline of its own: the test runner's is the only bound.
let waiting: (() => void)[] = [];
const changed = () => {
  const woken = waiting;
  waiting = [];
  for (const wake of woken) wake();
};
async function until(what: () => boolean) {
  while (!what()) await new Promise<void>((resolve) => waiting.push(resolve));
}

/// CoreSimulator as simctl and ps say it: an iPhone booted (its launchd_sim a process), another shut down, a watch.
/// `cased`: the booted iPhone's device type is a bundle whose case Xcode has (sim-chrome-fixture.ts), read by plutil.
function fakeSimulators(cased?: { bundlePath: string }, foldable = false) {
  const state = { booted: new Set([BOOTED]), launchd: new Map([[BOOTED, 4100]]), calls: [] as string[][] };
  const device = (udid: string, name: string, type: string) => ({ udid, name, deviceTypeIdentifier: `com.apple.CoreSimulator.SimDeviceType.${type}`, isAvailable: true, state: state.booted.has(udid) ? "Booted" : "Shutdown" });
  const run = async (file: string, args: string[]) => {
    state.calls.push([file, ...args]);
    changed();
    if (file === "/bin/ps")
      return [...state.launchd].map(([udid, pid]) => `${pid} Fri Nov  6 12:${String(pid % 60).padStart(2, "0")}:00 2026     launchd_sim /Users/m/Library/Developer/CoreSimulator/Devices/${udid}/data/var/run/launchd_bootstrap.plist`).join("\n") + "\n  12 Thu Nov  5 09:00:00 2026     /sbin/launchd\n";
    if (cased && file === "/usr/bin/plutil") {
      const plist = args.at(-1)!;
      if (plist === join(cased.bundlePath, "Contents/Resources/capabilities.plist"))
        return JSON.stringify({
          capabilities: {
            ScreenDimensionsCapability: { "main-screen-width": 240, "main-screen-height": 540, "main-screen-scale": 3 },
            displays: [{ displayType: "integrated", hasDigitizer: true, chromeIdentifier: "com.apple.dt.devicekit.chrome.phone8", framebufferMaskIdentifier: "Mask", width: 240, height: 540, scale: 3 }],
          },
        });
      if (plist === join(cased.bundlePath, "Contents/Resources/profile.plist")) return JSON.stringify({ chromeIdentifier: "com.apple.dt.devicekit.chrome.phone8" });
    }
    if (file === "/bin/sh") return JSON.stringify({ "fail.still.a": { ApplicationType: "User", CFBundleName: "Alpha" } });
    if (file !== SIMCTL) throw new Error(`no such program here: ${file}`);
    if (args[0] === "spawn" && args.includes("launchctl")) return "812\t0\tUIKitApplication:fail.still.a[1][rb-legacy]\n";
    if (args[0] === "launch") return "";
    if (args[0] === "ui") return args.length > 3 ? "" : "light\n";
    if (args.join(" ") === "list -j devices")
      return JSON.stringify({
        devices: {
          "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [device(BOOTED, foldable ? "iPhone Duo" : "iPhone 17 Pro", foldable ? "iPhone-Duo" : "iPhone-17-Pro"), device(SHUT, "iPhone 17", "iPhone-17")],
          "com.apple.CoreSimulator.SimRuntime.watchOS-27-2": [device(WATCH, "Apple Watch", "Apple-Watch")],
        },
      });
    if (args.join(" ") === "list -j devicetypes") return JSON.stringify({ devicetypes: cased ? [{ identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", name: "iPhone 17 Pro", bundlePath: cased.bundlePath }] : [] });
    if (args[0] === "boot" || args[0] === "shutdown") return "";
    throw new Error(`simctl ${args.join(" ")}`);
  };
  return {
    state,
    run,
    simctl: () => state.calls.filter((c) => c[0] === SIMCTL).map((c) => c.slice(1).join(" ")),
    /// The device booted again: another launchd_sim.
    reboot: (pid: number) => state.launchd.set(BOOTED, pid),
  };
}

/// The Computer Use helper on a Unix socket, speaking still.fail Helper's messages: each view's request, its info, what
/// came on it (input, and `{keyframe: true}`; rates and `next`s apart), and a way to give it a frame once one is asked.
const message = (kind: number, payload: Buffer) => {
  const head = Buffer.alloc(5);
  head[0] = kind;
  head.writeUInt32BE(payload.length, 1);
  return Buffer.concat([head, payload]);
};
async function fakeHelper(t: TestContext, refuse?: string) {
  const dir = mkdtempSync(join(tmpdir(), "fake-sim-helper-"));
  const socketPath = join(dir, "cu.sock");
  type Stream = { request: any; got: any[]; rates: number[]; nexts: number; given: number; send: (kind: number, payload: Buffer) => void; give: (...bytes: Buffer[]) => Promise<void>; socket: net.Socket };
  const streams: Stream[] = [];
  const server = net.createServer((socket) => {
    socket.on("error", () => {});
    socket.on("close", changed);
    let carry = Buffer.alloc(0);
    let stream: Stream | null = null;
    socket.on("data", (chunk: Buffer) => {
      carry = Buffer.concat([carry, chunk]);
      if (stream === null) {
        const end = carry.indexOf(10);
        if (end < 0) return;
        const made: Stream = {
          request: JSON.parse(carry.subarray(0, end).toString("utf8")),
          got: [],
          rates: [],
          nexts: 0,
          given: 0,
          send: (kind, payload) => void socket.write(message(kind, payload)),
          give: async (...bytes) => {
            await until(() => made.nexts > made.given);
            made.given++;
            socket.write(Buffer.concat(bytes));
          },
          socket,
        };
        stream = made;
        carry = carry.subarray(end + 1);
        streams.push(made);
        // (a helper that will not show it says why and ends, before any picture)
        if (refuse !== undefined) {
          socket.end(message(4, Buffer.from(JSON.stringify({ stopped: refuse }))));
          changed();
          return;
        }
        made.send(1, Buffer.from(JSON.stringify({ width: 1206, height: 2622, encoder: "hardware, low latency, HEVC_Main_AutoLevel, 1500000 bps", codec: made.request.view.codec, capture: "CoreSimulator" })));
        changed();
      }
      while (carry.length >= 5 && carry.length >= 5 + carry.readUInt32BE(1)) {
        const kind = carry[0]!;
        const payload = carry.subarray(5, 5 + carry.readUInt32BE(1));
        carry = carry.subarray(5 + payload.length);
        if (kind === 1) stream.nexts++;
        else if (kind === 2) stream.got.push({ keyframe: true });
        else if (kind === 3) stream.got.push(JSON.parse(payload.toString("utf8")));
        else if (kind === 7) stream.rates.push(payload.readUInt32BE(0));
        changed();
      }
    });
  });
  await new Promise<void>((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    for (const s of streams) s.socket.destroy();
    server.close();
    rmSync(dir, { recursive: true, force: true });
  });
  return { helper: { ensure: async () => {}, authToken: () => "token", socketPath }, streams };
}

/// A config (message 2): the picture's size, then the codec's description.
const config = (width: number, height: number, description: number[]) => {
  const size = Buffer.alloc(8);
  size.writeUInt32BE(width, 0);
  size.writeUInt32BE(height, 4);
  return message(2, Buffer.concat([size, Buffer.from(description)]));
};

const GRANT = new GrantKey();
const WS = "ws_1";

async function setup(t: TestContext, options: { drive?: boolean; cased?: ReturnType<typeof compositeCase>; foldable?: boolean; refuse?: string } = {}) {
  const sims = fakeSimulators(options.cased, options.foldable);
  const { helper, streams } = await fakeHelper(t, options.refuse);
  const world = { access: "full" as Access };
  const sources = makeScreens();
  sources.watch(changed);
  const devicesDir = mkdtempSync(join(tmpdir(), "fake-sim-devices-"));
  // (an agent's screenshot: a PNG's header of a phone's size, never simctl's)
  const capture = async () => {
    const png = Buffer.alloc(24);
    png.writeUInt32BE(0x89504e47, 0);
    png.write("IHDR", 12, "latin1");
    png.writeUInt32BE(1206, 16);
    png.writeUInt32BE(2622, 20);
    return png;
  };
  const simulators = new Simulators({ screens: sources, helper: () => helper, devices: devicesDir, run: sims.run, here: true, capture, ...(options.cased ? { chrome: options.cased.root } : {}) });
  t.after(() => {
    simulators.close();
    rmSync(devicesDir, { recursive: true, force: true });
  });
  const admissions = new DeviceMeshAdmissions();
  admissions.set({}, deviceMeshFacts({ workspace: WS, grant_keys: { keys: [GRANT.jwk] }, revocations: [], owner: "user_1", relay_urls: [] }));
  const screens = makeScreenViews({
    sources: () => sources.list(),
    simulators,
    access: () => world.access,
    up: () => true,
    mayView: (member) => admissions.mayView(member),
    mayControl: (member) => options.drive !== false && admissions.mayControl(member),
    listen: () => () => {},
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
  const credential = GRANT.credential({ typ: COMMA.credential.types[0] }, { iss: COMMA.credential.issuers[0], ws: WS, device: "device", sub: "user_1", email: "m@example.com", name: "M", role: "member", sid: "sess_1", iat: 1_700_000_000, exp: 4_102_444_800 });
  const client = new MeshClient({ endpoint: app, credential: async () => credential });
  const peer = { id: "station" };
  t.after(async () => {
    client.close();
    await Promise.all([app.close(), station.close()]);
  });
  const answer = async (response: MeshResponse) => {
    const parts: Uint8Array[] = [];
    for await (const chunk of response.body) parts.push(chunk);
    return JSON.parse(Buffer.concat(parts).toString("utf8"));
  };
  const list = async (path = SCREEN_LIST_WITH_DEVICES) => answer(await client.request(peer, { method: "GET", path }));
  const get = async (path: string) => {
    const response = await client.request(peer, { method: "GET", path });
    return { status: response.status, answer: await answer(response) };
  };
  /// Another of the owner's computers, with its own endpoint and its own credential.
  const other = (device: string) => {
    const endpoint = mesh.endpoint(device);
    const credential = GRANT.credential({ typ: COMMA.credential.types[0] }, { iss: COMMA.credential.issuers[0], ws: WS, device, sub: "user_1", email: "m@example.com", name: "M", role: "member", sid: `sess_${device}`, iat: 1_700_000_000, exp: 4_102_444_800 });
    const client = new MeshClient({ endpoint, credential: async () => credential });
    t.after(async () => {
      client.close();
      await endpoint.close();
    });
    return client;
  };
  const post = async (path: string, body: unknown) => {
    const response = await client.request(peer, { method: "POST", path, body: Buffer.from(JSON.stringify(body)) } as never);
    return { status: response.status, answer: await answer(response) };
  };
  return { sims, streams, world, sources, simulators, screens, client, other, peer, list, get, post };
}

async function openView(s: Awaited<ReturnType<typeof setup>>, asked: Record<string, unknown> = { codecs: ["h265", "h264"], control: true }) {
  const ask = { instance: s.sources.get(ID)?.instance, ...asked };
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
  const response = await s.client.request(s.peer, { method: "POST", path: `/screens/${encodeURIComponent(ID)}/view`, headers: [[SCREEN_HEADER, JSON.stringify(ask)]], body });
  const frames: { kind: number; payload: Uint8Array }[] = [];
  const reader = new ScreenFrameReader(1 << 20);
  const read = (async () => {
    for await (const chunk of response.body) {
      frames.push(...reader.push(chunk));
      changed();
    }
  })().catch(() => {});
  const of = (kind: number) => frames.filter((f) => f.kind === kind).map((f) => JSON.parse(Buffer.from(f.payload).toString("utf8")));
  return {
    response,
    read,
    videos: () => frames.filter((f) => f.kind === ScreenKind.video).map((f) => parseScreenVideo(f.payload)!),
    configs: () => of(ScreenKind.config),
    states: () => of(ScreenKind.state),
    send: (bytes: Uint8Array) => (queue.push(bytes), wake()),
    input: (event: unknown) => (queue.push(encodeScreenJson(ScreenKind.input, event)), wake()),
    finish: () => ((finished = true), wake()),
  };
}

const video = (key: boolean, ts: number, data: number[]) => {
  const head = Buffer.alloc(9);
  head[0] = key ? 1 : 0;
  head.writeBigUInt64BE(BigInt(ts), 1);
  return message(3, Buffer.concat([head, Buffer.from(data)]));
};

test("a booted simulator is listed with what it can do, and those shut down as what could boot; nothing without the ask", SKIP, async (t) => {
  const s = await setup(t);
  // A listing that does not ask for devices runs no simctl.
  assert.deepEqual((await s.list("/screens")).screens, []);
  assert.deepEqual(s.sims.simctl(), []);
  const answered = await s.list();
  const found = answered.screens.find((screen: { id: string }) => screen.id === ID);
  assert.deepEqual(found, {
    id: ID,
    kind: "simulator",
    peek: true,
    title: "iPhone 17 Pro · iOS 27.2",
    name: "iPhone 17 Pro",
    instance: found.instance,
    width: 0,
    height: 0,
    capabilities: { input: "touch", buttons: ["home", "lock", "volume", "rotate"], panels: [], closable: true, logs: true, debug: { actions: ["restart", "screenshot", "record", "install", "appearance"], install: [".ipa", ".zip"] } },
  });
  assert.match(found.instance, /^[0-9a-f]{16}$/);
  // A watch is no touchscreen to drive from here, booted or not.
  assert.deepEqual(answered.simulators, [{ udid: SHUT, title: "iPhone 17 · iOS 27.2" }]);
  // Only CoreSimulator's own simctl, never Xcode's script.
  assert.ok(s.sims.state.calls.every((c) => c[0] === SIMCTL || c[0] === "/bin/ps"));
});

/// What debugs its app, as a client asks it: the status, and the answer as JSON or as bytes.
async function debugAct(s: Awaited<ReturnType<typeof setup>>, action: string, o: { query?: string; body?: Uint8Array[] | AsyncIterable<Uint8Array>; instance?: string | null; client?: MeshClient } = {}) {
  const instance = o.instance === undefined ? s.sources.get(ID)!.instance! : o.instance;
  const query = [instance === null ? "" : `instance=${instance}`, o.query ?? ""].filter(Boolean).join("&");
  const response = await (o.client ?? s.client).request(s.peer, { method: "POST", path: `/screens/${encodeURIComponent(ID)}/debug/${action}?${query}`, body: (async function* () { yield* o.body ?? []; })() });
  const parts: Uint8Array[] = [];
  for await (const chunk of response.body) parts.push(chunk);
  const bytes = Buffer.concat(parts);
  const type = response.headers.find(([name]) => name === "content-type")?.[1];
  return { status: response.status, type, bytes, json: type === "application/json" ? JSON.parse(bytes.toString("utf8")) : undefined };
}

test("what debugs an app is done only by a client driving the device now: not one that watches, not another's, not with a lower access", SKIP, async (t) => {
  const s = await setup(t);
  await s.list();
  const launched = () => s.sims.simctl().filter((c) => c.startsWith("launch"));

  assert.equal((await debugAct(s, "restart")).status, 403, "no view at all");
  const watching = await openView(s, { codecs: ["h264"], control: false });
  await until(() => s.streams.length === 1);
  assert.equal((await debugAct(s, "restart")).status, 403, "a view in Watch");
  assert.equal((await debugAct(s, "screenshot")).status, 403, "looking at a picture is refused in Watch too");
  assert.deepEqual(launched(), []);

  watching.send(encodeScreenControl(true));
  await until(() => watching.states().some((state) => state.control === true));
  const done = await debugAct(s, "restart");
  assert.deepEqual([done.status, done.json], [200, { app: "fail.still.a", name: "Alpha" }]);
  assert.equal(launched().length, 1);
  assert.deepEqual((await debugAct(s, "state")).json, { recording: false, appearance: "light" });
  assert.deepEqual((await debugAct(s, "appearance", { query: "value=dark" })).json, { appearance: "dark" });
  assert.ok(s.sims.simctl().includes(`ui ${BOOTED} appearance dark`));
  assert.equal((await debugAct(s, "appearance", { query: "value=sepia" })).status, 400);

  // Another of the owner's computers, with no view of it in Control.
  assert.equal((await debugAct(s, "restart", { client: s.other("laptop") })).status, 403);
  // Not the boot it was picked as.
  assert.equal((await debugAct(s, "restart", { instance: "0".repeat(16) })).status, 409);
  assert.equal((await debugAct(s, "restart", { instance: null })).status, 409);
  assert.equal((await debugAct(s, "no-such")).status, 404);

  s.world.access = "read";
  assert.equal((await debugAct(s, "restart")).status, 403, "access lowered");
  s.world.access = "full";

  watching.send(encodeScreenControl(false));
  await until(() => watching.states().at(-1)?.control === false);
  assert.equal((await debugAct(s, "restart")).status, 403, "back to Watch");
  assert.equal(launched().length, 1);
  watching.finish();
  await watching.read;
});

test("debug re-reads the boot before dispatch, even before the next list refresh", SKIP, async (t) => {
  const s = await setup(t);
  await s.list();
  const view = await openView(s);
  await until(() => s.streams.length === 1);
  s.sims.reboot(4200);
  assert.equal((await debugAct(s, "restart")).status, 409);
  assert.ok(!s.sims.simctl().some((c) => c.startsWith("launch")));
  view.finish();
  await view.read;
});

for (const change of ["watch", "access", "boot"] as const) {
  test(`an upload cannot install after ${change} changes while its body arrives`, SKIP, async (t) => {
    const s = await setup(t);
    await s.list();
    const view = await openView(s);
    await until(() => s.streams.length === 1);
    const folder = mkdtempSync(join(tmpdir(), "debug-revoked-"));
    t.after(() => rmSync(folder, { recursive: true, force: true }));
    let installs = 0;
    const original = s.sources.get(ID)!.debug!;
    Object.defineProperty(s.sources.get(ID)!, "debug", { value: {
      actions: original.actions, installTypes: original.installTypes,
      installFolder: () => folder, install: async () => { installs++; return {}; },
      close: () => { void original.close(); },
    } });
    let release!: () => void;
    const held = new Promise<void>((resolve) => { release = resolve; });
    let arrived!: () => void;
    const sent = new Promise<void>((resolve) => { arrived = resolve; });
    const answer = debugAct(s, "install", { query: "name=Demo.zip", body: (async function* () {
      yield Buffer.from("part");
      arrived();
      await held;
      yield Buffer.from("rest");
    })() });
    await sent;
    if (change === "watch") {
      view.send(encodeScreenControl(false));
      await until(() => view.states().at(-1)?.control === false);
    } else if (change === "access") s.world.access = "read";
    else s.sims.reboot(4200);
    release();
    assert.equal((await answer).status, change === "boot" ? 409 : 403);
    assert.equal(installs, 0);
    const { readdirSync } = await import("node:fs");
    assert.deepEqual(readdirSync(folder), []);
    view.finish();
    await view.read;
  });
}

test("one who may only look has none of it, even with a view open", SKIP, async (t) => {
  const s = await setup(t, { drive: false });
  await s.list();
  const view = await openView(s, { codecs: ["h264"], control: true });
  await until(() => s.streams.length === 1);
  assert.equal((await debugAct(s, "restart")).status, 403);
  assert.ok(!s.sims.simctl().some((c) => c.startsWith("launch")));
  view.finish();
  await view.read;
});

test("a picture, a movie and an app as bytes over the mesh; only a file of its type goes up, and what could not be installed is not left", SKIP, async (t) => {
  const s = await setup(t);
  await s.list();
  const folder = mkdtempSync(join(tmpdir(), "debug-files-"));
  t.after(() => rmSync(folder, { recursive: true, force: true }));
  const movie = join(folder, "movie.mp4");
  writeFileSync(movie, Buffer.alloc(300_000, 7));
  const got: { path: string; bytes: string }[] = [];
  let installs = 0;
  const fake: DeviceDebug = {
    actions: ["screenshot", "record", "install"],
    installTypes: [".ipa", ".zip"],
    state: async () => ({ recording: false }),
    restart: async () => null,
    screenshot: async () => Buffer.from("a png"),
    recordStart: async () => {},
    recordStop: async () => ({ path: movie }),
    setAppearance: async () => {},
    installFolder: () => folder,
    install: async (path) => {
      installs++;
      got.push({ path, bytes: readFileSync(path, "utf8") });
      return path.endsWith(".zip") ? null : { app: "fail.still.demo" };
    },
    close: () => {},
  };
  Object.defineProperty(s.sources.get(ID)!, "debug", { value: fake });
  const view = await openView(s);
  await until(() => s.streams.length === 1);

  const shot = await debugAct(s, "screenshot");
  assert.deepEqual([shot.status, shot.type, shot.bytes.toString()], [200, "image/png", "a png"]);
  const stopped = await debugAct(s, "record-stop");
  assert.deepEqual([stopped.status, stopped.type, stopped.bytes.length], [200, "video/mp4", 300_000]);
  // What it does not list is refused, whatever the station could do of another device.
  assert.equal((await debugAct(s, "appearance", { query: "value=dark" })).status, 405);
  assert.equal((await debugAct(s, "restart")).status, 405);

  const installed = await debugAct(s, "install", { query: "name=Demo.ipa", body: [Buffer.from("par"), Buffer.from("ts")] });
  assert.deepEqual([installed.status, installed.json], [200, { app: "fail.still.demo" }]);
  assert.equal(got[0]!.bytes, "parts");
  assert.match(got[0]!.path, /[0-9a-f]{16}\.ipa$/, "named here, not by the client");
  assert.equal((await debugAct(s, "install", { query: "name=notes.txt", body: [Buffer.from("x")] })).status, 400);
  assert.equal((await debugAct(s, "install", { query: "name=Empty.zip", body: [Buffer.from("x")] })).status, 400);
  assert.equal(installs, 2);
  view.finish();
  await view.read;
});

test("no simulator is looked at or listed where the computer's access is not Full", SKIP, async (t) => {
  const s = await setup(t);
  s.world.access = "read";
  const answered = await s.list();
  assert.deepEqual(answered.screens, []);
  assert.equal(answered.simulators, undefined);
  assert.deepEqual(s.sims.state.calls, []);
});

test("the station's agents get each screen's link: the booted simulator, and those that could boot", SKIP, async (t) => {
  const s = await setup(t);
  // (a device id with characters a path part escapes, as a client parses it back: screenLinks.ts `parseScreenLink`)
  const linked = await screenLinksOf("dev 1/a", () => s.screens.catalog());
  assert.deepEqual(linked, {
    device_id: "dev 1/a",
    screens: [{ link: `comma:screen/dev%201%2Fa/simulator%3A${BOOTED}`, kind: "simulator", title: "iPhone 17 Pro · iOS 27.2" }],
    bootable_simulators: [{ udid: SHUT, title: "iPhone 17 · iOS 27.2" }],
    startable_avds: [],
  });
  const [, device, screen] = /^comma:screen\/([^/]+)\/([^/]+)$/.exec(linked.screens[0]!.link)!;
  assert.deepEqual([decodeURIComponent(device!), decodeURIComponent(screen!)], ["dev 1/a", ID]);
  // Where its screen may not be viewed, nothing is looked at, and the agent is told why.
  s.world.access = "read";
  const calls = s.sims.state.calls.length;
  assert.match((await screenLinksOf("dev", () => s.screens.catalog())).unavailable!, /access is not Full/);
  assert.equal(s.sims.state.calls.length, calls);
  // A station that serves no views now (its owner's app is not on the mesh) links to none.
  assert.deepEqual(await screenLinksOf("dev", null), { device_id: "dev", screens: [], bootable_simulators: [], startable_avds: [], unavailable: NOT_SERVED });
});

test("a view of a simulator: the helper's frames, a finger, Simulator.app's home shortcut and a rotate", SKIP, async (t) => {
  const s = await setup(t);
  await s.list();
  const view = await openView(s);
  assert.equal(view.response.status, 200);
  await until(() => s.streams.length === 1);
  const asked = s.streams[0]!.request;
  assert.equal(asked.control, "screen.view");
  assert.deepEqual({ ...asked.view }, { target: "simulator", udid: BOOTED, codec: "h265", control: true, maxWidth: 1920, maxHeight: 1920, bitrate: asked.view.bitrate, boot: asked.view.boot });
  assert.equal(typeof asked.view.boot, "string");

  // H.265 as the helper encodes it: its config, then the frames as they are, each once asked for.
  await s.streams[0]!.give(config(1206, 2622, [1, 2, 3]), video(true, 1000, [0, 0, 0, 2, 0x26, 0x01]));
  await until(() => view.videos().length === 1);
  assert.deepEqual(view.configs(), [{ codec: "h265", width: 1206, height: 2622, description: "AQID" }]);
  // How its pictures are made, for the statistics: what captures it and the encoder its info named.
  await until(() => view.states().some((state) => state.video));
  assert.deepEqual(view.states().find((state) => state.video).video, { capture: "CoreSimulator", encoder: "hardware, low latency, HEVC_Main_AutoLevel, 1500000 bps", hardware: true });
  assert.deepEqual([...view.videos()[0]!.data], [0, 0, 0, 2, 0x26, 0x01]);
  view.send(encodeScreenAck(view.videos()[0]!.ts));

  view.input({ t: "pointer", kind: "down", x: 0.5, y: 0.25, buttons: 1 });
  view.input({ t: "pointer", kind: "up", x: 0.5, y: 0.25, buttons: 0 });
  view.input({ t: "key", kind: "down", key: "h", code: "KeyH", mods: 12 });
  view.input({ t: "device", name: "rotate" });
  // What is no device's input does not reach the helper as a command of its own.
  view.input({ type: "stop" });
  view.input({ t: "device", name: "reboot" });
  const ops = () => s.streams[0]!.got;
  await until(() => ops().length >= 4);
  assert.deepEqual(ops(), [
    { op: "touch", type: "begin", x: 0.5, y: 0.25 },
    { op: "touch", type: "end", x: 0.5, y: 0.25 },
    { op: "button", name: "home" },
    { op: "rotate" },
  ]);

  // The active screen and its direction, as the helper reports them.
  s.streams[0]!.send(65, Buffer.from(JSON.stringify({ orientation: 90, pose: "closed" })));
  await until(() => view.states().some((state) => state.orientation === 90));
  assert.equal(view.states().at(-1)!.pose, "closed");
  s.streams[0]!.send(65, Buffer.from(JSON.stringify({ orientation: 90, pose: "open" })));
  await until(() => view.states().some((state) => state.pose === "open"));
  view.finish();
  await view.read;
});

test("a helper that refuses a view before its first picture is a refusal the client hears, and the station stays up", SKIP, async (t) => {
  const reason = "Open one separate Device Hub window for still.fail-try – iOS 27.1 to show its half fold.";
  const s = await setup(t, { refuse: reason });
  await s.list();
  const refused = await openView(s);
  assert.equal(refused.response.status, 503);
  // The station goes on: the next view is asked of the helper as the first was.
  const again = await openView(s);
  assert.equal(again.response.status, 503);
  assert.equal(s.streams.length, 2);
});

test("a person driving a simulator in Control holds an agent's input off it; once they let go, the agent's tap reaches it", SKIP, async (t) => {
  const s = await setup(t);
  await s.list();
  const source = s.simulators.sourceOf(ID)!;
  // (an agent's short waits, a tap's, pass at once; its lease's own timer never fires here)
  const agents = new SimulatorAgents(s.simulators, { now: () => 1_000_000, after: (ms, f) => (ms < 10_000 && queueMicrotask(f), () => {}) });
  t.after(() => agents.close());
  const started = await agents.call({ action: "start", target: ID, consent: true }, null);
  assert.equal(started.ok, true, JSON.stringify(started));
  const lease = { lease_id: started.lease_id, lease_epoch: started.lease_epoch };

  const person = await openView(s);
  await until(() => s.streams.length === 1 && source.held());
  assert.equal((await agents.call({ ...lease, action: "tap", x: 603, y: 1311 }, null)).error_code, "screen_held_by_person");
  // Nothing of the agent's reached the simulator: no view of its own was opened.
  assert.equal(s.streams.length, 1);

  person.finish();
  await person.read;
  await until(() => !source.held());
  const kept = async () => ({ ok: true, image_path: "shot.png" });
  assert.equal((await agents.call({ ...lease, action: "observe" }, kept)).image_width, 1206);
  assert.deepEqual(await agents.call({ ...lease, action: "tap", x: 603, y: 1311 }, null), { ok: true });
  // The agent's input went through a small view of its own that drives the device, as a finger.
  const own = s.streams[1]!;
  assert.deepEqual({ ...own.request.view }, { target: "simulator", udid: BOOTED, boot: own.request.view.boot, codec: "h264", control: true, maxWidth: 320, maxHeight: 320 });
  await until(() => own.got.length === 2);
  assert.deepEqual(own.got, [
    { op: "touch", type: "begin", x: 0.5, y: 0.5 },
    { op: "touch", type: "end", x: 0.5, y: 0.5 },
  ]);
});

test("a person watching a simulator is told when an agent's lease on it starts and ends, and where the agent's finger is", SKIP, async (t) => {
  const s = await setup(t);
  await s.list();
  const agents = new SimulatorAgents(s.simulators, { now: () => 1_000_000, after: (ms, f) => (ms < 10_000 && queueMicrotask(f), () => {}) });
  t.after(() => agents.close());

  // A view on Watch: it holds no agent's input off, and is told at once that no lease lasts.
  const person = await openView(s, { codecs: ["h264"], control: false, maxWidth: 640, maxHeight: 640 });
  await until(() => person.states().some((state) => state.agent === false));

  const started = await agents.call({ action: "start", target: ID, consent: true }, null);
  assert.equal(started.ok, true, JSON.stringify(started));
  const lease = { lease_id: started.lease_id, lease_epoch: started.lease_epoch };
  await until(() => person.states().some((state) => state.agent === true));

  const kept = async () => ({ ok: true, image_path: "shot.png" });
  assert.equal((await agents.call({ ...lease, action: "observe" }, kept)).image_width, 1206);
  assert.deepEqual(await agents.call({ ...lease, action: "tap", x: 603, y: 1311 }, null), { ok: true });
  await until(() => person.states().filter((state) => state.agentPointer).length === 2);
  assert.deepEqual(
    person.states().flatMap((state) => (state.agentPointer ? [state.agentPointer] : [])),
    [
      { x: 0.5, y: 0.5, down: true },
      { x: 0.5, y: 0.5, down: false },
    ],
  );

  assert.deepEqual(await agents.call({ ...lease, action: "end" }, null), { ok: true, ended: true });
  await until(() => person.states().at(-1)?.agent === false);
  person.finish();
  await person.read;
});

test("a card's preview of a simulator is a JPEG now and then, and only looks", SKIP, async (t) => {
  const s = await setup(t);
  await s.list();
  const view = await openView(s, { codecs: ["jpeg", "h264"], control: true, peek: true, maxWidth: 640, maxHeight: 640 });
  assert.equal(view.response.status, 200);
  await until(() => s.streams.length === 1 && view.states().length > 0);
  assert.deepEqual({ ...s.streams[0]!.request.view }, { target: "simulator", udid: BOOTED, boot: s.streams[0]!.request.view.boot, codec: "jpeg", control: false, maxWidth: 640, maxHeight: 640, fps: 2 });
  assert.equal(view.states()[0].control, false);
  await s.streams[0]!.give(config(294, 640, []), video(true, 1000, [0xff, 0xd8, 0xff, 0xd9]));
  await until(() => view.videos().length === 1);
  assert.deepEqual(view.configs(), [{ codec: "jpeg", width: 294, height: 640, description: "" }]);
  assert.deepEqual([...view.videos()[0]!.data], [0xff, 0xd8, 0xff, 0xd9]);
  view.input({ t: "pointer", kind: "down", x: 0.5, y: 0.5, buttons: 1 });
  // A view that asks for no video it decodes is refused.
  const refused = await s.client.request(s.peer, { method: "POST", path: `/screens/${encodeURIComponent(ID)}/view`, headers: [[SCREEN_HEADER, JSON.stringify({ codecs: ["jpeg"], control: false, instance: s.sources.get(ID)!.instance })]] });
  assert.equal(refused.status, 415);
  view.finish();
  await view.read;
  assert.deepEqual(s.streams[0]!.got, []);
});

const PEEK = { codecs: ["jpeg", "h264"], control: false, peek: true, maxWidth: 640, maxHeight: 640 };

test("one computer's previews leave another computer's room, and an ended preview gives its place back", SKIP, async (t) => {
  const s = await setup(t);
  await s.list();
  const windows = { ...s, client: s.other("windows") };
  // One computer has two cards on the screen: the old limit of the whole station.
  const held = [await openView(s, PEEK), await openView(s, PEEK)];
  assert.deepEqual(held.map((view) => view.response.status), [200, 200]);
  // The other computer's cards show all the same.
  const theirs = await openView(windows, PEEK);
  assert.equal(theirs.response.status, 200);
  // A third card of the first computer waits for its own, not for the other's.
  assert.equal((await openView(s, PEEK)).response.status, 503);
  await until(() => s.streams.length === 3);
  held[0]!.finish();
  await held[0]!.read;
  await until(() => s.streams[0]!.socket.closed);
  const again = await openView(s, PEEK);
  assert.equal(again.response.status, 200);
  for (const view of [held[1]!, theirs, again]) view.finish();
});

test("the station's previews are bounded over all its clients, and a refusal leaves one line in its log", SKIP, async (t) => {
  const s = await setup(t);
  await s.list();
  const lines: string[] = [];
  const write = process.stderr.write.bind(process.stderr);
  t.mock.method(process.stderr, "write", (chunk: string | Uint8Array, ...rest: never[]) => {
    lines.push(String(chunk));
    return (write as (...all: unknown[]) => boolean)(chunk, ...rest);
  });
  const clients = [s, { ...s, client: s.other("second") }, { ...s, client: s.other("third") }];
  const views = [];
  for (const one of clients) for (let i = 0; i < 2; i++) views.push(await openView(one, PEEK));
  assert.deepEqual(views.map((view) => view.response.status), [200, 200, 200, 200, 200, 200]);
  const late = { ...s, client: s.other("fourth") };
  assert.equal((await openView(late, PEEK)).response.status, 503);
  assert.equal((await openView(late, PEEK)).response.status, 503);
  const refusals = lines.filter((line) => line.includes("a view was refused"));
  assert.equal(refusals.length, 1, refusals.join(""));
  assert.match(refusals[0]!, /status=503 .*at most 6 screens .*device=fourth/);
  for (const view of views) view.finish();
});

test("a person boots a simulator the list has as shut down; nothing else boots, and not for one who may only look", SKIP, async (t) => {
  const s = await setup(t);
  await s.list();
  assert.deepEqual(await s.post("/screens/start", { simulator: SHUT }), { status: 200, answer: { id: `simulator:${SHUT}` } });
  // One booted already, a watch, one that is no device, a UDID that is not one: none.
  for (const simulator of [BOOTED, WATCH, "00000000-0000-0000-0000-000000000000", "../x"]) assert.equal((await s.post("/screens/start", { simulator })).status, 422);
  assert.deepEqual(s.sims.simctl().filter((c) => c.startsWith("boot")), [`boot ${SHUT}`]);
  s.world.access = "read";
  assert.equal((await s.post("/screens/start", { simulator: SHUT })).status, 403);
  const viewer = await setup(t, { drive: false });
  assert.equal((await viewer.post("/screens/start", { simulator: SHUT })).status, 403);
  assert.deepEqual(viewer.sims.simctl().filter((c) => c.startsWith("boot")), []);
});

test("a person shuts a simulator down at their word, the boot they picked and no later one", SKIP, async (t) => {
  const viewer = await setup(t, { drive: false });
  await viewer.list();
  assert.equal((await viewer.post(`/screens/${encodeURIComponent(ID)}/close`, { instance: viewer.sources.get(ID)!.instance })).status, 403);
  assert.deepEqual(viewer.sims.simctl().filter((c) => c.startsWith("shutdown")), []);

  const s = await setup(t);
  await s.list();
  const picked = s.sources.get(ID)!.instance!;
  assert.equal((await s.post(`/screens/${encodeURIComponent(ID)}/close`, { instance: "another" })).status, 409);
  // Booted again since the list: the card's or tab's boot is gone, and this one is neither shut down nor viewed.
  s.sims.reboot(4200);
  assert.equal((await s.post(`/screens/${encodeURIComponent(ID)}/close`, { instance: picked })).status, 409);
  const stale = await openView(s, { codecs: ["h264"], control: true, instance: picked });
  assert.equal(stale.response.status, 409);
  assert.deepEqual(s.sims.simctl().filter((c) => c.startsWith("shutdown")), []);
  // The list says the new boot, which is shut down by its own instance.
  await until(() => s.sources.get(ID) !== undefined && s.sources.get(ID)!.instance !== picked);
  assert.equal((await s.post(`/screens/${encodeURIComponent(ID)}/close`, { instance: s.sources.get(ID)!.instance })).status, 200);
  assert.deepEqual(s.sims.simctl().filter((c) => c.startsWith("shutdown")), [`shutdown ${BOOTED}`]);
});

test("a simulator whose boot cannot be told is only looked at, and not shut down from here", SKIP, async (t) => {
  const s = await setup(t);
  s.sims.state.launchd.clear();
  const found = (await s.list()).screens.find((screen: { id: string }) => screen.id === ID);
  assert.equal(found.instance, undefined);
  assert.equal(found.capabilities.closable, undefined);
  assert.equal((await s.post(`/screens/${encodeURIComponent(ID)}/close`, {})).status, 409);
  assert.deepEqual(s.sims.simctl().filter((c) => c.startsWith("shutdown")), []);
});

test("a simulator whose case Xcode has: listed with it, its pictures to one who may see, its buttons pressed by HID usage", SKIP, async (t) => {
  const cased = compositeCase();
  t.after(() => rmSync(cased.root, { recursive: true, force: true }));
  const s = await setup(t, { cased });
  const found = (await s.list()).screens.find((screen: { id: string }) => screen.id === ID);
  assert.equal(found.model, "iPhone 17 Pro");
  await s.simulators.refresh();
  assert.equal(s.sims.simctl().filter((call) => call === "list -j devicetypes").length, 1);
  // The case's geometry in its own points, and the panel's corners and buttons, upright as its framebuffer is.
  assert.deepEqual(found.capabilities.chrome, [
    {
      key: found.capabilities.chrome[0].key,
      width: 240,
      height: 540,
      frame: { width: 106, height: 200 },
      screen: { x: 10, y: 10, width: 80, height: 180 },
      corners: [],
      buttons: [{ name: "power", x: 99, y: 40, width: 4, height: 30, dx: -3, dy: 0, page: 12, usage: 48 }],
    },
  ]);
  // Its pictures: none of a panel it does not have, nor where the computer's access is not Full.
  assert.equal((await s.get(`/screens/${encodeURIComponent(ID)}/chrome/1/0`)).status, 404);
  assert.notEqual((await s.get(`/screens/${encodeURIComponent(ID)}/chrome/0/4`)).status, 200);
  if (existsSync("/usr/bin/sips")) {
    const pictures = await s.get(`/screens/${encodeURIComponent(ID)}/chrome/0/1`);
    assert.equal(pictures.status, 200);
    assert.deepEqual(Object.keys(pictures.answer.buttons), ["power"]);
    assert.ok(typeof pictures.answer.body === "string" && pictures.answer.body.length > 0);
  }
  s.world.access = "read";
  assert.equal((await s.get(`/screens/${encodeURIComponent(ID)}/chrome/0/0`)).status, 403);
  s.world.access = "full";

  // A button held and let go reaches the helper by its usage; one that is no HID usage does not.
  const view = await openView(s);
  await until(() => s.streams.length === 1);
  view.input({ t: "button", page: 12, usage: 48, down: true });
  view.input({ t: "button", page: 12, usage: 0x10000, down: true });
  view.input({ t: "button", page: 12, usage: 48, down: false });
  await until(() => s.streams[0]!.got.length >= 2);
  assert.deepEqual(s.streams[0]!.got, [
    { op: "hid", page: 12, usage: 48, down: true },
    { op: "hid", page: 12, usage: 48, down: false },
  ]);
  view.finish();
  await view.read;
});


test("a Duo exposes its outer and inner screens through direct framebuffer views", SKIP, async (t) => {
  const s = await setup(t, { foldable: true });
  await s.list();
  assert.deepEqual(s.simulators.sourceOf(ID)!.poseNames(), ["closed", "open"]);
  const full = await openView(s, { codecs: ["h265", "h264"], control: true });
  assert.equal(full.response.status, 200);
  await until(() => s.streams.length === 1);
  const request = s.streams[0]!.request.view;
  assert.deepEqual(request, {
    target: "simulator", udid: BOOTED, codec: "h265", control: true,
    maxWidth: 1920, maxHeight: 1920, bitrate: request.bitrate, boot: request.boot,
  });
  full.input({ t: "pose", name: "closed" });
  full.input({ t: "pose", name: "open" });
  full.input({ t: "pose", name: "book" });
  await until(() => s.streams[0]!.got.length === 2);
  assert.deepEqual(s.streams[0]!.got, [{ op: "pose", name: "closed" }, { op: "pose", name: "open" }]);
  full.finish();
  await full.read;
});
