// An emulator's screen end to end, in memory: `MeshClient` on @comma/mesh's memory mesh, the station's `comma/mesh/1`
// serving of a desktop's own station (mesh/comma.ts `deviceServing`) with a real credential for its owner, the view
// (mesh/screens.ts), and the Android source (screens/android.ts) on a fake adb at an absolute path and a fake scrcpy
// program. Never a real adb, device or emulator.
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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
import { deviceInput, makeScreenViews } from "../src/mesh/screens.ts";
import { AndroidScreens, stationAdbPort } from "../src/screens/android.ts";
import { makeScreens } from "../src/screens/source.ts";
import { GrantKey } from "./fake-control-plane.ts";
import { follow } from "./support/follow.ts";

const SKIP = { skip: process.platform === "win32" };
const EMULATOR = "emulator-5554";
const ID = `android:${EMULATOR}`;
const PHONE = "3B162S00P0N00000";
/// A person's phone first: taking a list's first device takes the phone.
const DEVICES = `${PHONE}\tdevice usb:1\nadb-${PHONE}-KLb58I._adb-tls-connect._tcp\tdevice\n127.0.0.1:${37715}\tdevice\n${EMULATOR}\tdevice\n`;
const SERVER_PORT = stationAdbPort("/a-station's-data");
const PANELS = "mBaseDisplayInfo=DisplayInfo{real 1080 x 2400, roundedCorners RoundedCorners{[RoundedCorner{position=TopLeft, radius=108}, RoundedCorner{position=TopRight, radius=108}, RoundedCorner{position=BottomRight, radius=108}, RoundedCorner{position=BottomLeft, radius=108}]}}";

// What the fake sees of these must be what the source says, not what the station's environment says.
process.env.ADB_MDNS = "1";
process.env.ADB_MDNS_AUTO_CONNECT = "1";
process.env.ADB_USB = "1";
process.env.ANDROID_ADB_SERVER_PORT = "5037";

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

/// What `cmd device_state print-states` says of a device that folds, and of one that does not (as a real findn6 AVD does).
const FOLDS = "Supported states: [\n  DeviceState{identifier=0, name='CLOSED', app_accessible=true},\n  DeviceState{identifier=1, name='HALF_OPENED', app_accessible=true},\n  DeviceState{identifier=2, name='OPENED', app_accessible=true},\n  DeviceState{identifier=3, name='REAR_DISPLAY_MODE', app_accessible=true},\n]";
const DOES_NOT = "Supported states: [\n  DeviceState{identifier=0, name='DEFAULT', app_accessible=true},\n]";

function fakeAdb(t: TestContext, forward: number, states: string = DOES_NOT) {
  const dir = mkdtempSync(join(tmpdir(), "fake-mesh-android-"));
  const write = (name: string, text: string) => {
    writeFileSync(join(dir, name), text);
    chmodSync(join(dir, name), 0o755);
  };
  write("wm", `#!/bin/sh
if [ "$2" = lock ]; then echo "$3" >> "${dir}/rotations"; echo "lock $3" > "${dir}/rotation"; else cat "${dir}/rotation"; fi
`);
  writeFileSync(join(dir, "rotation"), "free\n");
  writeFileSync(join(dir, "boot"), "0b5a6c2e-1d2f-4a3b-9c8d-7e6f5a4b3c2d\n");
  writeFileSync(join(dir, "pid"), "3534");
  writeFileSync(join(dir, "started"), "1000000");
  writeFileSync(join(dir, "state"), states === FOLDS ? "2\n" : "0\n");
  writeFileSync(join(dir, "scrcpy-server"), "a file for the push the fake does not do");
  write("adb", `#!/bin/sh
printf '%s\\t%s\\t%s\\t%s\\n' "$ADB_MDNS,$ADB_MDNS_AUTO_CONNECT" "\${ADB_USB-}" "$ANDROID_ADB_SERVER_PORT" "$*" >> "${dir}/calls"
case "$*" in
  track-devices*) printf '%04x%s' ${Buffer.byteLength(DEVICES)} '${DEVICES}'; exec sleep 60 ;;
  *sys.boot_completed*) echo 1 ;;
  *random/boot_id*) cat "${dir}/boot" ;;
  *"emu avd discoverypath"*) printf '/tmp/avd/running/pid_%s.ini\nOK\n' "$(cat "${dir}/pid")"
    # (armed: this emulator ends just after it said its pid, and another starts at its port)
    if [ -e "${dir}/swap" ]; then cat "${dir}/swap" > "${dir}/pid"; echo 9000000 > "${dir}/started"; rm "${dir}/swap"; fi ;;
  *"getprop ro.kernel.qemu"*) printf '\\n1\\n' ;;
  *ro.serialno*) printf 'EMULATOR30X\\nsdk\\n16\\nnull\\n' ;;
  *"emu avd name"*) printf 'Pixel_9\\nOK\\n' ;;
  *"wm size"*) echo 'Physical size: 1080x2400' ;;
  *"dumpsys display"*) echo '${PANELS}' ;;
  *"print-states"*) cat <<'STATES'
${states}
STATES
  ;;
  *"device_state state "*) echo "$4" | sed 's/.* //' > "${dir}/state"; echo "$4" >> "${dir}/poses" ;;
  *mCurrentRotation*) r=$(sed 's/lock //;s/free/0/' "${dir}/rotation"); echo "mCurrentRotation=ROTATION_$((r * 90))"; echo "Committed state: DeviceState{identifier=$(cat "${dir}/state"), name='X'}" ;;
  *" forward tcp:0 "*) echo ${forward} ;;
  *app_process*) exec sleep 60 ;;
  *"wm user-rotation"*) PATH="${dir}:$PATH" /bin/sh -c "$4" ;;
esac
`);
  const stop = follow(["calls", "rotations", "poses"].map((name) => join(dir, name)), changed);
  t.after(() => {
    stop();
    // (a fake adb call still in flight may write a line as the directory goes)
    rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  });
  const ended: number[] = [];
  const lines = (name: string) => (existsSync(join(dir, name)) ? readFileSync(join(dir, name), "utf8").split("\n").filter(Boolean) : []);
  return {
    path: join(dir, "adb"),
    /// Another boot at this port: the emulator closed and another took its place, with no offline adb saw.
    reboot: (boot: string) => writeFileSync(join(dir, "boot"), `${boot}\n`),
    /// Another emulator process, from a snapshot: its boot id the snapshot's, the same.
    restart: (pid: number) => (writeFileSync(join(dir, "pid"), String(pid)), writeFileSync(join(dir, "started"), "5000000")),
    /// The emulator ends just after it next says its pid, and another process `pid` starts at its port.
    restartAfterCheck: (pid: number) => writeFileSync(join(dir, "swap"), String(pid)),
    /// The machine's processes: only the emulator at the port runs (the one its pid file names), started when `started` says.
    processes: {
      startTimeOf: (pid: number) => (pid === Number(readFileSync(join(dir, "pid"), "utf8")) ? Number(readFileSync(join(dir, "started"), "utf8")) : null),
      end: (pid: number) => (ended.push(pid), changed()),
    },
    /// The processes a close ended.
    ended: () => [...ended],
    file: join(dir, "scrcpy-server"),
    calls: () => lines("calls").map((line) => {
      const [mdns, usb, port, args] = line.split("\t");
      return { mdns, usb, port, args: args! };
    }),
    rotations: () => lines("rotations"),
    poses: () => lines("poses"),
  };
}

/// scrcpy's program behind the forward: each view's first connection the video's, its second the control's.
async function fakeDevice(t: TestContext) {
  const sockets: net.Socket[] = [];
  const controlled: Buffer[] = [];
  const server = net.createServer((socket) => {
    socket.on("error", () => {});
    sockets.push(socket);
    if (sockets.length % 2 === 1) socket.write(Buffer.alloc(1 + 64 + 4));
    else socket.on("data", (d) => (controlled.push(d), changed()));
    changed();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => {
    for (const socket of sockets) socket.destroy();
    server.close();
  });
  return {
    port: (server.address() as net.AddressInfo).port,
    connected: () => sockets.length >= 2,
    connections: () => sockets.length,
    send: (...chunks: Buffer[]) => sockets[0]!.write(Buffer.concat(chunks)),
    controlled: () => Buffer.concat(controlled),
  };
}

const SPS = [0x67, 0x42, 0xc0, 0x1f, 0xaa], PPS = [0x68, 0xce], IDR = [0x65, 0x88, 0x84], DELTA = [0x41, 0x9a];
const annexB = (...nals: number[][]) => Buffer.from(nals.flatMap((n) => [0, 0, 0, 1, ...n]));
function session(width: number, height: number): Buffer {
  const b = Buffer.alloc(12);
  b[0] = 0x80;
  b.writeUInt32BE(width, 4);
  b.writeUInt32BE(height, 8);
  return b;
}
function packet(flags: number, pts: number, data: Buffer): Buffer {
  const b = Buffer.alloc(12);
  b.writeBigUInt64BE((BigInt(flags) << 56n) | BigInt(pts));
  b.writeUInt32BE(data.length, 8);
  return Buffer.concat([b, data]);
}
const CONFIG = 0x40, KEY = 0x20;
/// What scrcpy says as a capture starts: its size, its config and a key frame.
const capture = (width: number, height: number, pts: number) => [session(width, height), packet(CONFIG, 0, annexB(SPS, PPS)), packet(KEY, pts, annexB(IDR))];
/// A control socket's touch, as scrcpy reads it.
const touch = (b: Buffer, at: number) => ({ type: b[at], action: b[at + 1], x: b.readInt32BE(at + 10), y: b.readInt32BE(at + 14), width: b.readUInt16BE(at + 18), height: b.readUInt16BE(at + 20) });

const GRANT = new GrantKey();
const WS = "ws_1";
const ISSUED = 1_700_000_000;
const EXPIRES = 4_102_444_800;

async function setup(t: TestContext, options: { role?: string; sub?: string; states?: string; drive?: boolean; restoreAfter?: number; phones?: NonNullable<Parameters<typeof makeScreenViews>[0]["devices"]>["phones"] } = {}) {
  const device = await fakeDevice(t);
  const adb = fakeAdb(t, device.port, options.states);
  const world = { access: "full" as Access };
  const sources = makeScreens();
  sources.watch(changed);
  const androids = new AndroidScreens({ screens: sources, adb: () => adb.path, serverPort: SERVER_PORT, file: adb.file, processes: adb.processes, ...(options.restoreAfter === undefined ? {} : { restoreAfter: options.restoreAfter }) });
  t.after(async () => {
    androids.close();
    await androids.stopServer();
  });
  const admissions = new DeviceMeshAdmissions();
  admissions.set({}, deviceMeshFacts({ workspace: WS, grant_keys: { keys: [GRANT.jwk] }, revocations: [], owner: "user_1", relay_urls: [] }));
  const started: string[] = [];
  const screens = makeScreenViews({
    sources: () => sources.list(),
    devices: {
      refresh: () => androids.refresh(),
      unavailable: () => androids.unavailable(),
      startable: async () => ["Pixel_9"],
      start: async (avd) => (started.push(avd), avd === "Pixel_9" ? ID : null),
      ...(options.phones ? { phones: options.phones } : {}),
    },
    access: () => world.access,
    up: () => true,
    mayView: (member) => admissions.mayView(member),
    mayControl: (member) => options.drive !== false && admissions.mayControl(member),
    listen: () => () => {},
  });
  const admin = { handle: async () => ({ status: 200, headers: {}, body: Buffer.from("{}") }) };
  const members = { admin, up: () => true, screens } as any;
  const mesh = new MemoryMesh();
  const station = mesh.endpoint("station", [MESH_ALPN]);
  const app = mesh.endpoint("device");
  void (async () => {
    for (;;) {
      const connection = await station.accept();
      if (connection === null) return;
      void serveMeshConnection(connection, deviceServing(members, admissions));
    }
  })();
  const credential = GRANT.credential({ typ: COMMA.credential.types[0] }, { iss: COMMA.credential.issuers[0], ws: WS, device: "device", sub: options.sub ?? "user_1", email: "m@example.com", name: "M", role: options.role ?? "member", sid: "sess_1", iat: ISSUED, exp: EXPIRES });
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
  const list = async (path: string) => answer(await client.request(peer, { method: "GET", path }));
  /// Lists until the emulator is there: adb's answers come after the listing that started it.
  const listedEmulator = async () => {
    await list(SCREEN_LIST_WITH_DEVICES);
    await until(() => sources.get(ID) !== undefined);
    const answered = await list(SCREEN_LIST_WITH_DEVICES);
    return { answered, found: answered.screens.find((screen: { id: string }) => screen.id === ID) };
  };
  const post = async (path: string, body: unknown) => {
    const response = await client.request(peer, { method: "POST", path, body: Buffer.from(JSON.stringify(body)) } as never);
    return { status: response.status, answer: await answer(response) };
  };
  return { device, adb, world, sources, androids, list, listedEmulator, client, peer, started, post };
}

async function openView(s: Awaited<ReturnType<typeof setup>>, asked: Record<string, unknown> = { codecs: ["h264"], control: true }) {
  // (the device the list says is there now, unless the test names another)
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
    send: (bytes: Uint8Array) => {
      queue.push(bytes);
      wake();
    },
    input: (event: unknown) => {
      queue.push(encodeScreenJson(ScreenKind.input, event));
      wake();
    },
    finish: () => {
      finished = true;
      wake();
    },
  };
}

test("an emulator is listed with what it can do; a phone on the list never is, and is asked nothing", SKIP, async (t) => {
  const s = await setup(t);
  // A listing that does not ask for devices does not wake adb, which a computer's own screen has no need of.
  assert.deepEqual((await s.list("/screens")).screens, []);
  assert.deepEqual(s.adb.calls(), []);

  const { answered, found } = await s.listedEmulator();
  assert.deepEqual(answered.screens.map((screen: { id: string }) => screen.id), [ID]);
  assert.deepEqual(found, {
    id: ID,
    kind: "android",
    peek: true,
    title: "Pixel_9 · Android 16",
    name: "Pixel_9",
    instance: found.instance,
    width: 1080,
    height: 2400,
    capabilities: { input: "touch", buttons: ["home", "lock", "volume", "rotate"], panels: [{ width: 1080, height: 2400, corners: [0.1, 0.1, 0.1, 0.1] }], closable: true, logs: true, debug: { actions: ["restart", "screenshot", "record", "install"], install: [".apk"] } },
  });

  assert.deepEqual(answered.avds, ["Pixel_9"]);

  const calls = s.adb.calls();
  // The server is the station's own, and no call reaches anything but the emulator.
  assert.ok(SERVER_PORT !== 5037);
  assert.deepEqual([...new Set(calls.map((c) => [c.mdns, c.usb, c.port].join()))], [`0,0,0,${SERVER_PORT}`]);
  assert.deepEqual(calls.filter((c) => c.args !== "track-devices -l" && !c.args.startsWith(`-s ${EMULATOR} `)).map((c) => c.args), []);
  assert.equal(calls.some((c) => c.args.includes(PHONE) || c.args.includes("37715")), false);
});

test("no device is looked for or listed where a computer's access is not Full, and a view is refused", SKIP, async (t) => {
  const s = await setup(t);
  s.world.access = "read";
  assert.deepEqual((await s.list(SCREEN_LIST_WITH_DEVICES)).screens, []);
  assert.deepEqual(s.adb.calls(), []);

  s.world.access = "full";
  await s.listedEmulator();
  s.world.access = "read";
  assert.deepEqual((await s.list(SCREEN_LIST_WITH_DEVICES)).screens, []);
  const refused = await s.client.request(s.peer, { method: "POST", path: `/screens/${encodeURIComponent(ID)}/view`, headers: [[SCREEN_HEADER, '{"codecs":["h264"],"control":true}']] });
  assert.equal(refused.status, 403);
  assert.equal(s.device.connected(), false);
});

test("a view of an emulator: frames, touch and keys on its picture, and a rotate that turns the picture", SKIP, async (t) => {
  const s = await setup(t);
  await s.listedEmulator();
  const view = await openView(s);
  assert.equal(view.response.status, 200);
  await until(() => s.device.connected());

  // Frames: scrcpy's capture as a config and AVCC, its parameter sets in the config alone.
  s.device.send(...capture(1080, 2400, 1000));
  await until(() => view.videos().length === 1);
  assert.deepEqual(view.configs().map(({ codec, width, height }) => ({ codec, width, height })), [{ codec: "h264", width: 1080, height: 2400 }]);
  assert.deepEqual([...view.videos()[0]!.data], [0, 0, 0, 3, ...IDR]);
  assert.equal(view.videos()[0]!.key, true);
  view.send(encodeScreenAck(1000));
  s.device.send(packet(0, 2000, annexB(DELTA)));
  await until(() => view.videos().length === 2);
  assert.equal(view.videos()[1]!.key, false);
  view.send(encodeScreenAck(view.videos()[1]!.ts));

  // Touch as the app's stage sends it: fractions of the picture, in the device's pixels.
  view.input({ t: "pointer", kind: "down", x: 0.5, y: 0.25, buttons: 1 });
  await until(() => s.device.controlled().length === 32);
  assert.deepEqual(touch(s.device.controlled(), 0), { type: 2, action: 0, x: 540, y: 600, width: 1080, height: 2400 });
  view.input({ t: "pointer", kind: "up", x: 0.5, y: 0.25, buttons: 0 });
  await until(() => s.device.controlled().length === 64);
  assert.equal(touch(s.device.controlled(), 32).action, 1);

  // Home, as the app's button says it: a key press of the device's home keycode.
  view.input({ t: "key", kind: "down", key: "h", code: "KeyH", mods: 12 });
  await until(() => s.device.controlled().length === 92);
  assert.equal(s.device.controlled().readInt32BE(66), 3);

  // What is no device's name does not reach it, and no shell runs for it.
  view.input({ t: "device", name: "reboot" });

  // Rotate: the source turns the device, then its next capture is the picture turned, and touch follows it.
  view.input({ t: "device", name: "rotate" });
  await until(() => s.adb.rotations().length === 1);
  assert.deepEqual(s.adb.rotations(), ["1"]);
  assert.equal(s.adb.calls().filter((c) => c.args.includes("reboot")).length, 0);
  s.device.send(...capture(2400, 1080, 3000));
  await until(() => view.configs().length === 2);
  assert.deepEqual([view.configs()[1].width, view.configs()[1].height], [2400, 1080]);
  await until(() => view.videos().length === 3);
  view.send(encodeScreenAck(view.videos()[2]!.ts));
  const before = s.device.controlled().length;
  view.input({ t: "pointer", kind: "down", x: 0.5, y: 0.5, buttons: 1 });
  await until(() => s.device.controlled().length === before + 32);
  assert.deepEqual(touch(s.device.controlled(), before), { type: 2, action: 0, x: 1200, y: 540, width: 2400, height: 1080 });

  // The listing follows its new shape.
  await until(() => {
    const source = s.sources.get(ID);
    return source !== undefined && source.size!().width === 2400;
  });
  assert.deepEqual((await s.list(SCREEN_LIST_WITH_DEVICES)).screens[0].width, 2400);

  view.finish();
  await view.read;
  await until(() => s.adb.calls().some((c) => c.args.includes("forward --remove")));
});

test("Control switched on an open view of a device drives it and holds agents off; Watch lets go at once; the capture goes on", SKIP, async (t) => {
  const s = await setup(t);
  await s.listedEmulator();
  const view = await openView(s, { codecs: ["h264"], control: false });
  await until(() => s.device.connected() && view.states().length > 0);
  const source = s.androids.sourceOf(ID)!;
  s.device.send(...capture(1080, 2400, 1000));
  await until(() => view.videos().length === 1);
  view.send(encodeScreenAck(1000));
  const answered = async (on: boolean) => {
    const was = view.states().length;
    view.send(encodeScreenControl(on));
    await until(() => view.states().slice(was).some((state) => "control" in state));
    return view.states().slice(was).find((state) => "control" in state);
  };
  const down = { t: "pointer", kind: "down", x: 0.5, y: 0.25, buttons: 1 };

  // Watching: a person's view holds nothing, and its touch does not reach the device.
  assert.equal(view.states()[0].control, false);
  assert.equal(source.held(), false);
  view.input(down);

  // Control: the person drives (agents are refused meanwhile), and touch goes.
  assert.deepEqual(await answered(true), { control: true });
  assert.equal(source.held(), true);
  view.input(down);
  await until(() => s.device.controlled().length === 32);
  assert.equal(touch(s.device.controlled(), 0).action, 0);

  // Watch: let go at once, and the very next touch is dropped.
  view.send(encodeScreenControl(false));
  view.input(down);
  await until(() => view.states().filter((state) => "control" in state).length === 3);
  assert.equal(source.held(), false);
  assert.deepEqual(await answered(true), { control: true });
  view.input({ ...down, kind: "up", buttons: 0 });
  await until(() => s.device.controlled().length === 64);
  assert.equal(touch(s.device.controlled(), 32).action, 1);

  // One capture all along: no new program or connection, no reset asked of scrcpy, and its frames go on.
  const programs = () => s.adb.calls().filter((c) => c.args.includes("app_process")).length;
  s.device.send(packet(0, 2000, annexB(DELTA)));
  await until(() => view.videos().length === 2 && programs() > 0);
  assert.equal(view.videos()[1]!.key, false);
  assert.equal(s.device.connections(), 2);
  assert.equal(programs(), 1);

  // The view's end lets go of what it held.
  view.finish();
  await view.read;
  assert.equal(source.held(), false);
});

test("a person closes an emulator at their word; one who may only look does not", SKIP, async (t) => {
  const viewer = await setup(t, { drive: false });
  await viewer.listedEmulator();
  assert.equal((await viewer.post(`/screens/${encodeURIComponent(ID)}/close`, {})).status, 403);
  assert.deepEqual(viewer.adb.ended(), []);
  const s = await setup(t);
  await s.listedEmulator();
  assert.equal((await s.post("/screens/android%3Anone/close", {})).status, 404);
  assert.equal((await s.post(`/screens/${encodeURIComponent(ID)}/close`, { instance: s.sources.get(ID)!.instance })).status, 200);
  // Its process is ended, not whatever is at its serial.
  assert.deepEqual(s.adb.ended(), [3534]);
  assert.equal(s.adb.calls().some((c) => c.args.includes("emu kill")), false);
});

test("an emulator that ends just after its close is checked, and another at its port: neither is closed, and the new one is listed", SKIP, async (t) => {
  const s = await setup(t);
  const { found } = await s.listedEmulator();
  s.adb.restartAfterCheck(4242);
  assert.equal((await s.post(`/screens/${encodeURIComponent(ID)}/close`, { instance: found.instance })).status, 409);
  assert.deepEqual(s.adb.ended(), []);
  assert.equal(s.adb.calls().some((c) => c.args.includes("emu kill")), false);
  await until(() => s.sources.get(ID) !== undefined && s.sources.get(ID)!.instance !== found.instance);
  // The new one is closed by its own process.
  assert.equal((await s.post(`/screens/${encodeURIComponent(ID)}/close`, { instance: s.sources.get(ID)!.instance })).status, 200);
  assert.deepEqual(s.adb.ended(), [4242]);
});

test("a person starts an AVD from the list; one who may only look starts nothing, nor where the access is not Full", SKIP, async (t) => {
  const s = await setup(t);
  assert.deepEqual(await s.post("/screens/start", { avd: "Pixel_9" }), { status: 200, answer: { id: ID } });
  assert.equal((await s.post("/screens/start", { avd: "Nope" })).status, 422);
  assert.equal((await s.post("/screens/start", { avd: 3 })).status, 400);
  s.world.access = "read";
  assert.equal((await s.post("/screens/start", { avd: "Pixel_9" })).status, 403);
  assert.deepEqual(s.started, ["Pixel_9", "Nope"]);
  const viewer = await setup(t, { drive: false });
  assert.equal((await viewer.post("/screens/start", { avd: "Pixel_9" })).status, 403);
  assert.deepEqual(viewer.started, []);
});

test("only the computer's owner reaches its devices: another member is refused before adb is asked anything", SKIP, async (t) => {
  for (const options of [{ sub: "user_2" }, { role: "viewer" }]) {
    const s = await setup(t, options);
    await assert.rejects(s.list(SCREEN_LIST_WITH_DEVICES));
    assert.deepEqual(s.adb.calls(), []);
  }
});

test("a preview only looks: small, slow, the screen not woken, input dropped, and none past its bound", SKIP, async (t) => {
  const s = await setup(t);
  await s.listedEmulator();
  const view = await openView(s, { codecs: ["h264"], control: true, peek: true, maxWidth: 640, maxHeight: 640 });
  assert.equal(view.response.status, 200);
  await until(() => s.device.connected() && view.states().length > 0);
  assert.equal(view.states()[0].control, false);
  await until(() => s.adb.calls().some((c) => c.args.includes("app_process")));
  const program = s.adb.calls().find((c) => c.args.includes("app_process"))!.args;
  assert.match(program, /max_size=640 /);
  assert.match(program, /max_fps=2 /);
  assert.match(program, /video_bit_rate=300000 /);
  assert.match(program, /power_on=false/);
  s.device.send(...capture(288, 640, 1000));
  await until(() => view.videos().length === 1);
  view.input({ t: "pointer", kind: "down", x: 0.5, y: 0.5, buttons: 1 });
  // Nor does it take Control as it runs.
  view.send(encodeScreenControl(true));
  await until(() => view.states().filter((state) => "control" in state).length === 2);
  assert.deepEqual(view.states().filter((state) => "control" in state)[1], { control: false, refused: "a preview only looks" });
  // A second is taken and a third refused; the real view still has its room.
  const second = await openView(s, { codecs: ["h264"], control: false, peek: true, maxWidth: 640, maxHeight: 640 });
  assert.equal(second.response.status, 200);
  const third = await s.client.request(s.peer, { method: "POST", path: `/screens/${encodeURIComponent(ID)}/view`, headers: [[SCREEN_HEADER, JSON.stringify({ codecs: ["h264"], control: false, peek: true, instance: s.sources.get(ID)!.instance })]] });
  assert.equal(third.status, 503);
  const real = await openView(s);
  assert.equal(real.response.status, 200);
  view.finish();
  second.finish();
  real.finish();
  await Promise.all([view.read, second.read, real.read]);
  assert.equal(s.device.controlled().length, 0);
});

test("what a client says reaches a device only as what it knows", () => {
  assert.equal(deviceInput({ type: "keydown", code: "KeyA" }), null);
  assert.equal(deviceInput({ t: "device", name: "reboot" }), null);
  assert.equal(deviceInput({ t: "pose", name: "reboot" }), null);
  assert.equal(deviceInput({ t: "pointer", kind: "drag", x: 0, y: 0 }), null);
  // Text is only text: typed or pasted, never a command (sim-input.ts, android.ts), and none past what one event carries.
  assert.deepEqual(deviceInput({ t: "text", text: "rm -rf", extra: "x" }), { t: "text", text: "rm -rf" });
  assert.equal(deviceInput({ t: "text", text: "" }), null);
  assert.equal(deviceInput({ t: "text", text: "x".repeat(4097) }), null);
  assert.deepEqual(deviceInput({ t: "pointer", kind: "down", x: 7, y: -1, buttons: 255, extra: "x" }), { t: "pointer", kind: "down", x: 1, y: 0, buttons: 7 });
  assert.deepEqual(deviceInput({ t: "key", kind: "up", code: "KeyA", mods: 255, key: "$(x)" }), { t: "key", kind: "up", key: "", code: "KeyA", mods: 15 });
});

test("the station's adb server stops with it, and on no port of a person's", SKIP, async (t) => {
  const s = await setup(t);
  assert.throws(() => new AndroidScreens({ screens: s.sources, adb: () => s.adb.path, serverPort: 5037 }));
  for (const data of ["/a", "/b", "/c", "/d"]) {
    const port = stationAdbPort(data);
    assert.ok(port >= 15100 && port < 16100);
  }
  const none = new AndroidScreens({ screens: s.sources, adb: () => s.adb.path, serverPort: SERVER_PORT });
  await none.stopServer();
  assert.deepEqual(s.adb.calls(), []);
  await s.listedEmulator();
  const followed = new AndroidScreens({ screens: makeScreens(), adb: () => s.adb.path, serverPort: SERVER_PORT, file: s.adb.file });
  followed.start();
  t.after(() => followed.close());
  await followed.stopServer();
  assert.equal(s.adb.calls().filter((c) => c.args === "kill-server" && c.port === String(SERVER_PORT)).length, 1);
});

test("a foldable says its poses, takes them by the device's own state, and says how it stands as that changes", SKIP, async (t) => {
  const s = await setup(t, { states: FOLDS });
  const { found } = await s.listedEmulator();
  assert.deepEqual(found.capabilities.poses, ["closed", "book", "open"]);
  const view = await openView(s);
  await until(() => s.device.connected());
  s.device.send(...capture(1080, 2400, 1000));
  await until(() => view.videos().length === 1);
  const devices = () => view.states().filter((state) => state.orientation !== undefined || state.pose !== undefined);
  await until(() => devices().length === 1);
  assert.deepEqual(devices()[0], { orientation: 0, pose: "open" });

  view.input({ t: "pose", name: "closed" });
  await until(() => s.adb.poses().length === 1);
  assert.deepEqual(s.adb.poses(), ["cmd device_state state 0"]);
  await until(() => devices().length === 2);
  assert.deepEqual(devices()[1], { orientation: 0, pose: "closed" });

  // The outer screen comes as a new capture of another size: touch goes by it.
  view.send(encodeScreenAck(1000));
  s.device.send(...capture(720, 1600, 3000));
  await until(() => view.configs().length === 2);
  assert.deepEqual([view.configs()[1].width, view.configs()[1].height], [720, 1600]);
  await until(() => view.videos().length === 2);
  view.send(encodeScreenAck(view.videos()[1]!.ts));
  view.input({ t: "pointer", kind: "down", x: 0.5, y: 0.5, buttons: 1 });
  await until(() => s.device.controlled().length === 32);
  assert.deepEqual(touch(s.device.controlled(), 0), { type: 2, action: 0, x: 360, y: 800, width: 720, height: 1600 });

  // Turned: said too, the two together.
  view.input({ t: "device", name: "rotate" });
  await until(() => devices().length === 3);
  assert.deepEqual(devices()[2], { orientation: 90, pose: "closed" });

  // What no device names does not reach it.
  view.input({ t: "pose", name: "reboot" });
  view.finish();
  await view.read;
  assert.equal(s.adb.poses().length, 1);
});

test("a device that does not fold has no poses, and a pose asks it nothing", SKIP, async (t) => {
  const s = await setup(t);
  const { found } = await s.listedEmulator();
  assert.equal(found.capabilities.poses, undefined);
  const view = await openView(s);
  await until(() => s.device.connected());
  s.device.send(...capture(1080, 2400, 1000));
  await until(() => view.videos().length === 1);
  view.input({ t: "pose", name: "closed" });
  view.finish();
  await view.read;
  assert.deepEqual(s.adb.poses(), []);
});

test("a foldable turned or folded from here is put back once nobody drives it, and as the station stops", SKIP, async (t) => {
  const s = await setup(t, { states: FOLDS, restoreAfter: 50 });
  await s.listedEmulator();
  const restored = () => s.adb.calls().filter((c) => c.args.includes("device_state state reset")).map((c) => c.args);
  // Only looked at: nothing to put back (two put back in all, below, are the two turned and folded).
  const looking = await openView(s);
  await until(() => s.device.connected());
  looking.finish();
  await looking.read;

  const view = await openView(s);
  await until(() => view.states().length > 0);
  view.input({ t: "device", name: "rotate" });
  view.input({ t: "pose", name: "closed" });
  await until(() => s.adb.poses().includes("cmd device_state state 0"));
  view.finish();
  await view.read;
  await until(() => restored().length === 1);
  assert.deepEqual(restored(), [`-s ${EMULATOR} shell cmd device_state state reset; wm fixed-to-user-rotation default; wm user-rotation free`]);

  // Folded again, and the station stops with it open: put back before the server goes.
  const last = await openView(s);
  await until(() => last.states().length > 0);
  last.input({ t: "pose", name: "book" });
  await until(() => s.adb.poses().includes("cmd device_state state 1"));
  s.androids.close();
  await s.androids.stopServer();
  assert.equal(restored().length, 2, JSON.stringify(s.adb.calls().map((c) => c.args).slice(-8)));
  const calls = s.adb.calls().map((c) => c.args);
  assert.ok(calls.lastIndexOf("kill-server") > calls.findLastIndex((args) => args.includes("device_state state reset")));
});

test("a device is driven and closed only as the instance picked: another in its place is refused", SKIP, async (t) => {
  const s = await setup(t);
  const { found } = await s.listedEmulator();
  assert.match(found.instance, /^[0-9a-f]{16}$/);
  const stale = await s.client.request(s.peer, { method: "POST", path: `/screens/${encodeURIComponent(ID)}/view`, headers: [[SCREEN_HEADER, JSON.stringify({ codecs: ["h264"], control: true, instance: "0000000000000000" })]] });
  assert.equal(stale.status, 409);
  const none = await s.client.request(s.peer, { method: "POST", path: `/screens/${encodeURIComponent(ID)}/view`, headers: [[SCREEN_HEADER, JSON.stringify({ codecs: ["h264"], control: true })]] });
  assert.equal(none.status, 409);
  assert.equal((await s.post(`/screens/${encodeURIComponent(ID)}/close`, { instance: "0000000000000000" })).status, 409);
  assert.equal((await s.post(`/screens/${encodeURIComponent(ID)}/close`, {})).status, 409);
  assert.deepEqual(s.adb.ended(), []);
  assert.equal((await s.post(`/screens/${encodeURIComponent(ID)}/close`, { instance: found.instance })).status, 200);
});

test("a start is judged again once its body has come: access lowered meanwhile starts nothing", SKIP, async (t) => {
  const s = await setup(t);
  let send: () => void = () => {};
  let reading: () => void = () => {};
  const read = new Promise<void>((resolve) => (reading = resolve));
  const body = (async function* () {
    yield Buffer.from('{"avd":');
    // (the station is reading the body: its first part went)
    reading();
    await new Promise<void>((resolve) => (send = resolve));
    yield Buffer.from('"Pixel_9"}');
  })();
  const asked = s.client.request(s.peer, { method: "POST", path: "/screens/start", body } as never);
  await read;
  s.world.access = "read";
  send();
  assert.equal((await asked).status, 403);
  assert.deepEqual(s.started, []);
});

test("another emulator at the same port with no offline between: the old instance is refused and the list says the new", SKIP, async (t) => {
  const s = await setup(t);
  const { found } = await s.listedEmulator();
  s.adb.reboot("1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f");
  const stale = await openView(s, { codecs: ["h264"], control: true, instance: found.instance });
  assert.equal(stale.response.status, 409);
  assert.equal(s.device.connected(), false);
  await until(() => s.sources.get(ID) !== undefined && s.sources.get(ID)!.instance !== found.instance);
  const now = (await s.list(SCREEN_LIST_WITH_DEVICES)).screens.find((screen: { id: string }) => screen.id === ID);
  assert.notEqual(now.instance, found.instance);
  assert.equal((await s.post(`/screens/${encodeURIComponent(ID)}/close`, { instance: found.instance })).status, 409);
  assert.deepEqual(s.adb.ended(), []);
});

test("a device whose boot cannot be told is only looked at, and not closed from here", SKIP, async (t) => {
  const s = await setup(t);
  s.adb.reboot("not a boot id");
  const { found } = await s.listedEmulator();
  assert.equal(found.instance, undefined);
  const view = await openView(s, { codecs: ["h264"], control: true });
  assert.equal(view.response.status, 409);
  assert.equal((await s.post(`/screens/${encodeURIComponent(ID)}/close`, {})).status, 409);
  assert.equal(found.capabilities.closable, undefined);
  assert.deepEqual(s.adb.ended(), []);
});

test("a foldable is not put back on another boot at its place, and is put back as it was found", SKIP, async (t) => {
  const s = await setup(t, { states: FOLDS, restoreAfter: 1 });
  await s.listedEmulator();
  const boots = () => s.adb.calls().filter((c) => c.args.includes("random/boot_id")).length;
  const resets = () => s.adb.calls().filter((c) => c.args.includes("device_state state reset")).map((c) => c.args);
  const view = await openView(s);
  await until(() => view.states().length > 0);
  view.input({ t: "pose", name: "closed" });
  await until(() => s.adb.poses().includes("cmd device_state state 0"));
  // What it was is read before it is first folded.
  assert.ok(s.adb.calls().some((c) => c.args.endsWith("shell wm fixed-to-user-rotation; wm user-rotation")));
  s.adb.reboot("1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f");
  const before = boots();
  view.finish();
  await view.read;
  // Its put-back reads the boot, finds another, and does nothing to it.
  await until(() => boots() > before);
  assert.deepEqual(resets(), []);
});

test("a foldable closed from its own open view is put back first, then closed", SKIP, async (t) => {
  const s = await setup(t, { states: FOLDS });
  await s.listedEmulator();
  const view = await openView(s);
  await until(() => view.states().length > 0);
  view.input({ t: "device", name: "rotate" });
  await until(() => s.adb.rotations().length === 1);
  assert.equal((await s.post(`/screens/${encodeURIComponent(ID)}/close`, { instance: s.sources.get(ID)!.instance })).status, 200);
  const calls = s.adb.calls().map((c) => c.args);
  const reset = calls.findIndex((args) => args.includes("device_state state reset"));
  assert.ok(reset >= 0, JSON.stringify(calls.slice(-6)));
  assert.deepEqual(s.adb.ended(), [3534]);
  view.finish();
  await view.read;
});

test("an emulator started again from its snapshot keeps its boot id: its process tells it from the one before", SKIP, async (t) => {
  const s = await setup(t);
  const { found } = await s.listedEmulator();
  s.adb.restart(4242);
  const stale = await openView(s, { codecs: ["h264"], control: true, instance: found.instance });
  assert.equal(stale.response.status, 409);
  await until(() => s.sources.get(ID) !== undefined && s.sources.get(ID)!.instance !== found.instance);
  assert.equal((await s.post(`/screens/${encodeURIComponent(ID)}/close`, { instance: found.instance })).status, 409);
  assert.deepEqual(s.adb.ended(), []);
});

test("phones: their owner lists and chooses them over the mesh; one who may not drive the computer may not", SKIP, async (t) => {
  const asked: unknown[] = [];
  const listedPhone = { serial: PHONE, state: "device", model: "Pixel 8", transport: "usb" as const, shown: false, agents: false };
  const phones = {
    choices: () => ({ usb: true, chosen: {} }),
    phones: () => [listedPhone],
    setUsb: async (on: boolean) => void asked.push({ usb: on }),
    choose: async (serial: string, choice: { agents: boolean } | null) => void asked.push({ serial, choice }),
    connect: async (address: string) => (asked.push({ connect: address }), `connected to ${address}`),
    disconnect: async (address: string) => (asked.push({ disconnect: address }), "disconnected"),
  };
  const owner = await setup(t, { phones });
  assert.deepEqual((await owner.list(SCREEN_LIST_WITH_DEVICES)).phones, { usb: true, list: [listedPhone] });
  assert.equal((await owner.post("/screens/phones", { serial: PHONE, shown: true, agents: true })).status, 200);
  assert.equal((await owner.post("/screens/phones", { usb: false })).status, 200);
  const connected = await owner.post("/screens/phones", { connect: "192.168.1.20:41234" });
  assert.deepEqual([connected.status, connected.answer.said], [200, "connected to 192.168.1.20:41234"]);
  assert.equal((await owner.post("/screens/phones", { what: "else" })).status, 400);
  assert.deepEqual(asked, [{ serial: PHONE, choice: { agents: true } }, { usb: false }, { connect: "192.168.1.20:41234" }]);
  const watcher = await setup(t, { phones, drive: false });
  assert.equal((await watcher.post("/screens/phones", { usb: true })).status, 403);
  owner.world.access = "read";
  assert.equal((await owner.post("/screens/phones", { usb: true })).status, 403);
  assert.equal((await owner.list(SCREEN_LIST_WITH_DEVICES)).phones, undefined);
  assert.equal(asked.length, 3);
});
