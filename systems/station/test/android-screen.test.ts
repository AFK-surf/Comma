// The Android screen source (src/screens/android.ts) against a fake adb and a fake scrcpy program: never a real adb,
// device or emulator. The fake is reached by its absolute path alone, and no test here looks on PATH.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { wall } from "../src/ops/fibers.ts";
import { stationLang, tr } from "../src/ops/i18n.ts";
import { ScreenRefused } from "../src/screens/hub.ts";
import { makeScreens, type Frame } from "../src/screens/source.ts";
import { AndroidScreens, AndroidInput, restoreOf, KEYCODES, ScrcpyStream, adbEnv, avcCOf, avccOf, devicesOf, metaOf, nalsOf, bitrateOf, panelsOf, shownDevice, sideOf, sizeOf } from "../src/screens/android.ts";
import { follow } from "./support/follow.ts";

const SKIP = { skip: process.platform === "win32" };
const size = { width: 1000, height: 2000 };
const EMULATOR = "emulator-5554";
const PHONE = "3B162S00P0N00000";
const SERVER_PORT = 15939;
/// A phone lent through a member link, as adb names it: a serial here, which nothing connects to.
const LENT_PHONE = `${"127.0.0.1"}:37715`;
/// What `adb track-devices` says with a person's phone on adb, before the emulator: a list's first device is the phone.
const PHONE_FIRST = `${PHONE}\tdevice usb:1\nadb-${PHONE}-KLb58I._adb-tls-connect._tcp\tdevice\n${LENT_PHONE}\tdevice\n${EMULATOR}\tdevice\n`;
const H264 = { maxWidth: 800, maxHeight: 800, codecs: ["h264" as const] };
const refused = (status: number, key: string, said?: RegExp) => (e: unknown) =>
  e instanceof ScreenRefused && e.status === status && e.key === key && (said === undefined || said.test(String(e.args.said)));

// What the fake sees of these must be what the source says, not what the station's environment says.
process.env.ADB_MDNS_AUTO_CONNECT = "1";
process.env.ADB_USB = "1";
process.env.ANDROID_ADB_SERVER_PORT = "5037";
const OTHER_SERVERS = ["ADB_SERVER_SOCKET", "ANDROID_ADB_SERVER_ADDRESS", "ADB_SERVER_PORT", "ADBHOST", "ADB_LOCAL_TRANSPORT_MAX_PORT", "ANDROID_SERIAL"];
for (const name of OTHER_SERVERS) process.env[name] = "the person's";
delete process.env.STILLFAIL_SCRCPY_SERVER;

const dirs: string[] = [];
const follows: (() => void)[] = [];
after(() => {
  for (const stop of follows) stop();
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

/// Everything the tests wait on says it changed here: what a fake adb writes down, the list of sources, what a fake
/// device hears. A wait has no deadline of its own: the test runner's is the only bound.
let waiting: (() => void)[] = [];
function changed() {
  const woken = waiting;
  waiting = [];
  for (const wake of woken) wake();
}
async function until<T>(what: () => T | null | undefined | false): Promise<T> {
  for (;;) {
    const got = what();
    if (got) return got;
    await new Promise<void>((resolve) => waiting.push(resolve));
  }
}
/// Files a fake writes down in, made before anything writes to them and followed from then on.
function followed(...paths: string[]) {
  follows.push(follow(paths, changed));
}

/// A display with rounded corners, as `dumpsys display` says it.
const roundedLine = (w: number, h: number, r: number) =>
  `    mBaseDisplayInfo=DisplayInfo{"x", real ${w} x ${h}, roundedCorners RoundedCorners{[RoundedCorner{position=TopLeft, radius=${r}, center=Point(1, 1)}, RoundedCorner{position=TopRight, radius=${r}, center=Point(1, 1)}, RoundedCorner{position=BottomRight, radius=${r}, center=Point(1, 1)}, RoundedCorner{position=BottomLeft, radius=${r}, center=Point(1, 1)}]}, FLAG}`;
const DUMPSYS = roundedLine(1080, 2400, 108);

/// A fake adb, each call written down with its server's environment. `port`: what `forward tcp:0` says. `scrcpy`: the
/// shell body of the program's run on the device (default: it stays until killed). `qemu`: the shell body that answers
/// the emulator check. `hold`: the call that waits until `release`. `wm` follows `wm user-rotation`, and
/// `shell` runs the source's real rotate command through /bin/sh.
function fakeAdb(devices: string, o: { port?: number; scrcpy?: string; qemu?: string; hold?: "push" | "forward" } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "fake-android-adb-"));
  dirs.push(dir);
  const write = (name: string, text: string) => {
    writeFileSync(join(dir, name), text);
    chmodSync(join(dir, name), 0o755);
  };
  followed(join(dir, "calls"), join(dir, "rotations"));
  write("wm", `#!/bin/sh
if [ "$2" = lock ]; then echo "$3" >> "${dir}/rotations"; echo "lock $3" > "${dir}/rotation"; else cat "${dir}/rotation"; fi
`);
  writeFileSync(join(dir, "rotation"), "free\n");
  writeFileSync(join(dir, "scrcpy-server"), "a file for the push the fake does not do");
  const held = (call: "push" | "forward") => (o.hold === call ? `until [ -e "${dir}/release" ]; do sleep 0.01; done;` : "");
  write("adb", `#!/bin/sh
strays=${OTHER_SERVERS.map((name) => `"\${${name}-}"`).join("")}
printf '%s\\t%s\\t%s\\t%s\\t%s\\n' "$ADB_MDNS_AUTO_CONNECT" "\${ADB_USB-}" "$ANDROID_ADB_SERVER_PORT" "$strays" "$*" >> "${dir}/calls"
case "$*" in
  track-devices*) printf '%04x%s' ${Buffer.byteLength(devices)} '${devices}'; exec sleep 60 ;;
  *sys.boot_completed*) echo 1 ;;
  *random/boot_id*) echo 0b5a6c2e-1d2f-4a3b-9c8d-7e6f5a4b3c2d ;;
  *"emu avd discoverypath"*) printf '/tmp/avd/running/pid_77.ini\nOK\n' ;;
  *"getprop ro.kernel.qemu"*) ${o.qemu ?? "printf '\\n1\\n'"} ;;
  *ro.serialno*) printf 'PHONE-SERIALNO\\nsdk\\n16\\nnull\\n' ;;
  *"emu avd name"*) printf 'pixel\\nOK\\n' ;;
  *"wm size"*) echo 'Physical size: 1080x2400' ;;
  *"dumpsys display"*) echo '${DUMPSYS}' ;;
  *" push "*) ${held("push")} : ;;
  *" forward tcp:0 "*) ${held("forward")} echo ${o.port ?? 1} ;;
  *app_process*) ${o.scrcpy ?? "exec sleep 60"} ;;
  *"wm user-rotation"*) PATH="${dir}:$PATH" /bin/sh -c "$4" ;;
esac
`);
  const lines = (name: string) => (existsSync(join(dir, name)) ? readFileSync(join(dir, name), "utf8").split("\n").filter(Boolean) : []);
  return {
    dir,
    path: join(dir, "adb"),
    file: join(dir, "scrcpy-server"),
    called: (what: string) => until(() => lines("calls").some((line) => line.includes(what))),
    calls: () => lines("calls").map((line) => {
      const [mdns, usb, port, strays, args] = line.split("\t");
      return { mdns, usb, port, strays, args: args! };
    }),
    rotations: () => lines("rotations"),
    release: () => writeFileSync(join(dir, "release"), ""),
  };
}

function source(adb: ReturnType<typeof fakeAdb>, more: { phones?: string[]; file?: string; connectTimeout?: number } = {}) {
  const screens = makeScreens();
  screens.watch(changed);
  const androids = new AndroidScreens({ screens, adb: () => adb.path, serverPort: SERVER_PORT, file: adb.file, ...more });
  androids.start();
  return { screens, androids };
}

/// A fake of scrcpy's program behind a forward: its first connection is the video socket, over which it says it listens,
/// its second the control socket. `silent`: it takes connections and says nothing.
async function fakeDevice(o: { silent?: boolean } = {}) {
  let video: net.Socket | null = null;
  let control: net.Socket | null = null;
  const controlled: Buffer[] = [];
  const server = net.createServer((socket) => {
    socket.on("error", () => {});
    if (video === null) {
      video = socket;
      if (!o.silent) socket.write(HEAD);
    } else {
      control = socket;
      socket.on("data", (d) => {
        controlled.push(d);
        changed();
      });
    }
    changed();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    port: (server.address() as net.AddressInfo).port,
    send: (...chunks: Buffer[]) => video!.write(Buffer.concat(chunks)),
    controlled: () => Buffer.concat(controlled),
    connected: () => control !== null,
    close() {
      video?.destroy();
      control?.destroy();
      server.close();
    },
  };
}

const SPS = [0x67, 0x42, 0xc0, 0x1f, 0xaa], PPS = [0x68, 0xce], IDR = [0x65, 0x88, 0x84], DELTA = [0x41, 0x9a];
const annexB = (...nals: number[][]) => Buffer.from(nals.flatMap((n) => [0, 0, 0, 1, ...n]));
const HEAD = Buffer.alloc(1 + 64 + 4);
function session(width: number, height: number): Buffer {
  const b = Buffer.alloc(12);
  b[0] = 0x80;
  b.writeUInt32BE(width, 4);
  b.writeUInt32BE(height, 8);
  return b;
}
function packet(flags: number, pts: number, data: Buffer): Buffer {
  const h = Buffer.alloc(12);
  h.writeBigUInt64BE(BigInt(pts), 0);
  h[0]! |= flags;
  h.writeUInt32BE(data.length, 8);
  return Buffer.concat([h, data]);
}
const CONFIG = 0x40, KEY = 0x20;

/// The emulator's source open on a fake device: `listed` first, as the source is listed on its own.
async function opened(o: { peek?: boolean; fps?: number } = {}) {
  const device = await fakeDevice();
  const adb = fakeAdb(PHONE_FIRST, { port: device.port });
  const { screens, androids } = source(adb);
  const emulator = await until(() => screens.get(`android:${EMULATOR}`));
  const view = await emulator.open({ ...H264, ...(o.peek ? { peek: true } : {}), ...(o.fps === undefined ? {} : { fps: o.fps }) });
  await until(() => device.connected());
  return { device, adb, androids, screens, view, finish: () => (view.close(), androids.close(), device.close()) };
}

test("adb's devices: only those ready", () => {
  assert.deepEqual(devicesOf("emulator-5554          device product:a model:b\nABC unauthorized usb:1\n123 offline\n\n"), ["emulator-5554"]);
});

test("a screen: an emulator, or a phone asked for by its exact serial; never what adb found by itself, nor a lent phone", () => {
  assert.equal(shownDevice("emulator-5554"), true);
  for (const serial of [PHONE, "192.168.1.20:5555", "emulator-", "emulator-5554x", `adb-${PHONE}._adb-tls-connect._tcp`, LENT_PHONE]) assert.equal(shownDevice(serial), false, serial);
  assert.equal(shownDevice(PHONE, [PHONE]), true);
  assert.equal(shownDevice("3B162S00P0N00001", [PHONE]), false);
  for (const serial of [`adb-${PHONE}._adb-tls-connect._tcp`, LENT_PHONE]) assert.equal(shownDevice(serial, [serial]), false, serial);
});

test("adb's environment: its own server, no phone connected by itself, USB only with a phone asked for", () => {
  const env = adbEnv(SERVER_PORT, false, { PATH: "/bin", ADB_MDNS_AUTO_CONNECT: "1", ANDROID_ADB_SERVER_PORT: "5037", ADB_USB: "1" });
  assert.deepEqual(env, { PATH: "/bin", ADB_MDNS: "0", ADB_MDNS_AUTO_CONNECT: "0", ANDROID_ADB_SERVER_PORT: String(SERVER_PORT), ADB_USB: "0" });
  assert.equal(adbEnv(SERVER_PORT, true, { ADB_USB: "0" }).ADB_USB, undefined);
});

for (const name of OTHER_SERVERS) {
  test(`adb's environment: ${name} does not choose its server or device`, () => {
    assert.equal(adbEnv(SERVER_PORT, false, { PATH: "/bin", [name]: "elsewhere" })[name], undefined);
    assert.equal(adbEnv(SERVER_PORT, true, { PATH: "/bin", [name]: "elsewhere" })[name], undefined);
    assert.equal(adbEnv(SERVER_PORT, false, { PATH: "/bin", [name]: "x" }).PATH, "/bin");
  });
}

test("a person's adb server is refused, not used", () => {
  for (const serverPort of [5037, 0, -1, 70000, Number.NaN]) {
    assert.throws(() => new AndroidScreens({ screens: makeScreens(), adb: () => null, serverPort }), /not an adb server of the station's own/);
  }
});

test("a phone and an emulator on adb: the phone is listed and asked nothing, whatever comes first", SKIP, async () => {
  const adb = fakeAdb(PHONE_FIRST);
  const { screens, androids } = source(adb);
  try {
    await until(() => screens.list().length > 0);
    assert.deepEqual(screens.list().map((s) => s.id), [`android:${EMULATOR}`]);
    assert.equal(screens.get(`android:${PHONE}`), undefined);
    await androids.refresh();
    assert.deepEqual(adb.calls().filter((c) => !c.args.startsWith(`-s ${EMULATOR} `) && c.args !== "track-devices -l"), []);
  } finally {
    androids.close();
  }
});

test("a phone asked for by its serial: listed under its own id, each call pinned to it", SKIP, async () => {
  const adb = fakeAdb(PHONE_FIRST);
  const { screens, androids } = source(adb, { phones: [PHONE] });
  try {
    await until(() => screens.list().length === 2);
    assert.deepEqual(screens.list().map((s) => s.id).sort(), [`android:${EMULATOR}`, "android:PHONE-SERIALNO"].sort());
    assert.ok(adb.calls().some((c) => c.args.startsWith(`-s ${PHONE} shell`)));
    assert.deepEqual(adb.calls().filter((c) => /_adb-tls|127\.0\.0\.1/.test(c.args)), []);
    // (USB is on for it: no ADB_USB=0, whatever the station's environment says)
    assert.deepEqual([...new Set(adb.calls().map((c) => [c.mdns, c.usb, c.port].join()))], [`0,,${SERVER_PORT}`]);
  } finally {
    androids.close();
  }
});

for (const [said, answer] of [["nothing", "printf '\\n\\n'"], ["no", "printf '0\\n0\\n'"]] as const) {
  test(`a phone named as an emulator (qemu says ${said}) is not listed, and gets no call after the check`, SKIP, async () => {
    const adb = fakeAdb(`${EMULATOR}\tdevice\n`, { qemu: answer });
    const { screens, androids } = source(adb);
    try {
      await adb.called("getprop ro.kernel.qemu");
      await androids.refresh();
      assert.deepEqual(screens.list(), []);
      assert.deepEqual(adb.calls().map((c) => c.args), ["track-devices -l", `-s ${EMULATOR} shell getprop sys.boot_completed`, `-s ${EMULATOR} shell getprop ro.kernel.qemu; getprop ro.boot.qemu`]);
    } finally {
      androids.close();
    }
  });
}

for (const [prop, answer] of [["ro.kernel.qemu", "printf '1\\n\\n'"], ["ro.boot.qemu", "printf '\\n1\\n'"]] as const) {
  test(`an emulator that says ${prop} is listed`, SKIP, async () => {
    const { screens, androids } = source(fakeAdb(`${EMULATOR}\tdevice\n`, { qemu: answer }));
    try {
      await until(() => screens.get(`android:${EMULATOR}`));
    } finally {
      androids.close();
    }
  });
}

for (const call of ["push", "forward"] as const) {
  test(`a view closed during its ${call}: no program runs, and no forward stays`, SKIP, async () => {
    const adb = fakeAdb(`${EMULATOR}\tdevice\n`, { hold: call });
    const { screens, androids } = source(adb);
    try {
      const emulator = await until(() => screens.get(`android:${EMULATOR}`));
      const opening = emulator.open(H264);
      await adb.called(call === "push" ? " push " : " forward tcp:0 ");
      androids.close();
      adb.release();
      await assert.rejects(opening, refused(503, "station.screen.failed", /the view was closed/));
      await adb.called("rm -f");
      if (call === "forward") await adb.called("forward --remove tcp:1");
      assert.deepEqual(adb.calls().filter((c) => c.args.includes("app_process") || (call === "push" && c.args.includes("forward"))), []);
    } finally {
      androids.close();
    }
  });
}

test("adb that does not answer is cut off at 15 seconds: opening fails, and the program's file is removed", SKIP, async () => {
  const adb = fakeAdb(`${EMULATOR}\tdevice\n`, { hold: "push" });
  const { screens, androids } = source(adb);
  const saved = wall.after;
  const due = new Set<() => void>();
  try {
    const emulator = await until(() => screens.get(`android:${EMULATOR}`));
    wall.after = (ms, f) => {
      if (ms !== 15_000) return saved(ms, f);
      due.add(f);
      return () => due.delete(f);
    };
    const opening = emulator.open(H264);
    await adb.called(" push ");
    assert.equal(due.size, 1, "the push alone is waited for");
    for (const f of due) f();
    await assert.rejects(opening, refused(503, "station.screen.failed", /adb did not answer in time/));
    await adb.called("rm -f");
    assert.deepEqual(adb.calls().filter((c) => c.args.includes("forward") || c.args.includes("app_process")), []);
  } finally {
    wall.after = saved;
    androids.close();
  }
});

test("adb's devices let go of: a device still booting is not looked at again", SKIP, async () => {
  const dir = mkdtempSync(join(tmpdir(), "android-looks-"));
  dirs.push(dir);
  const adb = join(dir, "adb");
  writeFileSync(adb, `#!/bin/sh
case "$*" in
  track-devices*) printf '0015emulator-5554\\tdevice\\n'; exec sleep 60 ;;
  *sys.boot_completed*) echo 0 ;;
esac
`);
  chmodSync(adb, 0o755);
  const saved = wall.after;
  const due = new Map<() => void, number>();
  wall.after = (ms, f) => {
    if (ms === 15_000) return saved(ms, f);
    due.set(f, ms);
    changed();
    return () => due.delete(f);
  };
  const androids = new AndroidScreens({ screens: makeScreens(), adb: () => adb, serverPort: SERVER_PORT, file: adb, lookAgain: 77 });
  try {
    void androids.refresh();
    await until(() => [...due.values()].includes(77));
    for (const [f, ms] of [...due]) {
      if (ms < 60_000) continue;
      due.delete(f);
      f();
    }
    assert.deepEqual([...due.values()], []);
  } finally {
    wall.after = saved;
    androids.close();
  }
});

test("a packet too long to be one ends the view, and the stream is not read on", SKIP, async () => {
  const { device, view, finish } = await opened();
  try {
    const head = Buffer.alloc(12);
    head.writeUInt32BE(0xffffffff, 8);
    device.send(session(556, 1280), head);
    assert.equal(await view.next(), null);
  } finally {
    finish();
  }
  let long = 0, packets = 0;
  const stream = new ScrcpyStream(() => {}, () => packets++, () => long++);
  const head = Buffer.alloc(12);
  head.writeUInt32BE((32 << 20) + 1, 8);
  stream.heard(Buffer.concat([HEAD, head, packet(0, 1, Buffer.from([1]))]));
  stream.heard(packet(0, 2, Buffer.from([2])));
  assert.deepEqual([long, packets], [1, 0]);
});

test("a tampered scrcpy-server fails its build, and nothing stays in the cache", SKIP, () => {
  const dir = mkdtempSync(join(tmpdir(), "scrcpy-sha-"));
  dirs.push(dir);
  const curl = join(dir, "curl");
  writeFileSync(curl, `#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = --output ]; then echo tampered > "$2"; fi
  shift
done
`);
  chmodSync(curl, 0o755);
  const cache = join(dir, "cache");
  const native = fileURLToPath(new URL("../scripts/native.ts", import.meta.url));
  const done = spawnSync(process.execPath, [native, "build", "scrcpy-server", "linux-x64"], {
    encoding: "utf8",
    env: { ...process.env, PATH: `${dir}:${process.env.PATH ?? ""}`, STILLFAIL_NATIVE_CACHE: cache, STILLFAIL_NATIVE: "build" },
  });
  assert.notEqual(done.status, 0);
  assert.match(done.stderr, /sha256 [0-9a-f]{64}, expected 764eb6f7/);
  const kept = existsSync(join(cache, "scrcpy-server")) ? readdirSync(join(cache, "scrcpy-server")).filter((name) => !name.endsWith(".lock")) : [];
  assert.deepEqual(kept.filter((name) => existsSync(join(cache, "scrcpy-server", name, "scrcpy-server"))), []);
});

test("a listed emulator's panels are its display's corners", SKIP, async () => {
  const { screens, androids } = source(fakeAdb(`${EMULATOR}\tdevice\n`));
  try {
    const emulator = await until(() => screens.get(`android:${EMULATOR}`));
    assert.deepEqual(emulator.panels, [{ width: 1080, height: 2400, corners: [0.1, 0.1, 0.1, 0.1] }]);
  } finally {
    androids.close();
  }
});

test("a whole view: every adb call on its own server, pinned to the emulator's serial", SKIP, async () => {
  const { adb, view, device, finish } = await opened();
  try {
    device.send(session(556, 1280));
    await view.input({ t: "device", name: "rotate" });
    view.close();
    await adb.called("forward --remove");
    await adb.called("rm -f");
    const calls = adb.calls();
    assert.deepEqual(calls.filter((c) => c.args !== "track-devices -l" && !c.args.startsWith(`-s ${EMULATOR} `)).map((c) => c.args), []);
    assert.deepEqual([...new Set(calls.map((c) => [c.mdns, c.usb, c.port, c.strays].join()))], [`0,0,${SERVER_PORT},`]);
  } finally {
    finish();
  }
});

test("a view's program: H.264 alone, no audio, the pinned version, the screen on only for a view that drives", SKIP, async () => {
  const of = async (peek: boolean) => {
    const { adb, finish } = await opened({ peek });
    // (the fake device listens before the run is written down)
    await adb.called("app_process");
    const run = adb.calls().find((c) => c.args.includes("app_process"))!.args;
    finish();
    return run;
  };
  const view = await of(false);
  for (const word of [" com.genymobile.scrcpy.Server 5.0.1 ", " video_codec=h264", " audio=false", " control=true", " tunnel_forward=true", " power_on=true", " max_size=800"]) assert.ok(view.includes(word), word);
  assert.ok((await of(true)).includes(" power_on=false"));
});

test("a viewer that takes no H.264 is refused before anything runs on the device", SKIP, async () => {
  const adb = fakeAdb(`${EMULATOR}\tdevice\n`);
  const { screens, androids } = source(adb);
  try {
    const emulator = await until(() => screens.get(`android:${EMULATOR}`));
    const before = adb.calls().length;
    await assert.rejects(emulator.open({ ...H264, codecs: [] }), refused(415, "station.screen.codec"));
    assert.equal(adb.calls().length, before);
  } finally {
    androids.close();
  }
});

test("the program's stream reaches a view as the source interface says: a config with its avcC, AVCC data, rising times, then the end", SKIP, async () => {
  const { device, view, finish } = await opened();
  try {
    const nexts: Promise<Frame | null>[] = [view.next(), view.next(), view.next()];
    device.send(session(556, 1280), packet(CONFIG, 0, annexB(SPS, PPS)), packet(KEY, 500, annexB(IDR)), packet(0, 400, annexB(DELTA)), packet(0, 900, annexB(DELTA)));
    const [key, older, later] = (await Promise.all(nexts)) as Frame[];
    assert.deepEqual([key!.key, key!.ts, [...key!.data]], [true, 500, [0, 0, 0, 3, ...IDR]]);
    const { codec, width, height, description } = key!.config!;
    assert.deepEqual([codec, width, height, [...description!]], ["h264", 556, 1280, [1, 0x42, 0xc0, 0x1f, 0xff, 0xe1, 0, 5, ...SPS, 1, 0, 2, ...PPS]]);
    // A new capture's clock may start lower: the times still rise, and only a key frame carries a config.
    assert.deepEqual([older!.key, older!.ts, older!.config, [...older!.data]], [false, 501, undefined, [0, 0, 0, 2, ...DELTA]]);
    assert.deepEqual([later!.ts, later!.config], [900, undefined]);
    const pending = view.next();
    view.close();
    assert.equal(await pending, null);
    assert.equal(await view.next(), null);
  } finally {
    finish();
  }
});

test("a keyframe on request: one reset message on the control socket", SKIP, async () => {
  const { device, view, finish } = await opened();
  try {
    assert.equal(device.controlled().length, 0);
    view.keyframe();
    await until(() => device.controlled().length > 0);
    assert.deepEqual([...device.controlled()], [17]);
  } finally {
    finish();
  }
});

test("a view that asks too slowly drops whole frames up to a new key frame, which it asked for", SKIP, async () => {
  const { device, view, finish } = await opened();
  try {
    device.send(session(556, 1280), packet(CONFIG, 0, annexB(SPS, PPS)), packet(KEY, 1, annexB(IDR)), ...Array.from({ length: 31 }, (_, i) => packet(0, i + 2, annexB(DELTA))));
    await until(() => device.controlled().includes(17));
    device.send(packet(0, 100, annexB(DELTA)), packet(CONFIG, 0, annexB(SPS, PPS)), packet(KEY, 200, annexB(IDR)));
    const frame = (await view.next())!;
    assert.equal(frame.key, true);
    assert.ok(frame.config !== undefined, "with the new capture's config");
    assert.equal(frame.ts, 200);
  } finally {
    finish();
  }
});

test("a person's finger reaches the control socket once the program has said its size", SKIP, async () => {
  const { device, view, finish } = await opened();
  try {
    // (no size yet: nothing to place it by. The reset comes after it on the one socket, so it would come first.)
    await view.input({ t: "pointer", kind: "down", x: 0.5, y: 0.25, buttons: 1 });
    view.keyframe();
    await until(() => device.controlled().length > 0);
    assert.deepEqual([...device.controlled()], [17]);
    device.send(session(1000, 2000), packet(CONFIG, 0, annexB(SPS, PPS)), packet(KEY, 1, annexB(IDR)));
    await view.next();
    await view.input({ t: "pointer", kind: "down", x: 0.5, y: 0.25, buttons: 1 });
    await until(() => device.controlled().length === 33);
    const m = device.controlled().subarray(1);
    assert.deepEqual([m[0], m[1], m.readInt32BE(10), m.readInt32BE(14)], [2, 0, 500, 500]);
  } finally {
    finish();
  }
});

test("rotate turns a device a quarter each time, all four ways and round again, by the window manager alone", SKIP, async () => {
  const { adb, device, view, finish } = await opened();
  try {
    for (let i = 0; i < 5; i++) await view.input({ t: "device", name: "rotate" });
    // From following its sensor ("free"): 1, 2, 3, 0, and on round.
    assert.deepEqual(adb.rotations(), ["1", "2", "3", "0", "1"]);
    assert.equal(device.controlled().length, 0, "not scrcpy's own ROTATE_DEVICE, which does nothing on an Android 16 emulator");
  } finally {
    finish();
  }
});

test("rotation's name is checked: another device input runs nothing on the device", SKIP, async () => {
  const { adb, view, finish } = await opened();
  try {
    // Wait for startup to remove its temporary server file before counting input effects.
    await adb.called("shell rm -f /data/local/tmp/stillfail-scrcpy-");
    const before = adb.calls().length;
    await view.input({ t: "pointer", kind: "up", x: 0, y: 0, buttons: 0 });
    await view.input({ t: "device", name: "turn; rm -rf /" } as never);
    assert.deepEqual(adb.rotations(), []);
    assert.equal(adb.calls().length, before);
  } finally {
    finish();
  }
});

test("no adb on the machine: it says so at once, lists nothing and does not hang", async () => {
  const screens = makeScreens();
  const androids = new AndroidScreens({ screens, adb: () => null, serverPort: SERVER_PORT });
  try {
    assert.equal(androids.unavailable(), null, "nothing looked for yet");
    await androids.refresh();
    assert.equal(androids.unavailable(), tr(stationLang(), "station.adb.noAdb"));
    assert.deepEqual(screens.list(), []);
  } finally {
    androids.close();
  }
});

test("adb's path no longer runs: it says so, lists nothing and does not hang", SKIP, async () => {
  const screens = makeScreens();
  screens.watch(changed);
  const androids = new AndroidScreens({ screens, adb: () => join(tmpdir(), "no-such-dir-for-adb", "adb"), serverPort: SERVER_PORT });
  try {
    await androids.refresh();
    assert.equal(await until(() => androids.unavailable()), tr(stationLang(), "station.adb.noAdb"));
    assert.deepEqual(screens.list(), []);
  } finally {
    androids.close();
  }
});

test("adb gone after the device was listed: opening fails with what happened", SKIP, async () => {
  const adb = fakeAdb(`${EMULATOR}\tdevice\n`);
  const { screens, androids } = source(adb);
  try {
    const emulator = await until(() => screens.get(`android:${EMULATOR}`));
    rmSync(adb.path);
    await assert.rejects(emulator.open(H264), refused(503, "station.screen.failed", /adb could not be run: .*ENOENT/));
  } finally {
    androids.close();
  }
});

test("no scrcpy-server: refused before anything runs on the device", SKIP, async () => {
  const adb = fakeAdb(`${EMULATOR}\tdevice\n`);
  const { screens, androids } = source(adb, { file: join(adb.dir, "no-scrcpy-server") });
  try {
    const emulator = await until(() => screens.get(`android:${EMULATOR}`));
    const before = adb.calls().length;
    await assert.rejects(emulator.open(H264), refused(503, "station.screen.noScrcpy"));
    assert.equal(adb.calls().length, before);
  } finally {
    androids.close();
  }
});

test("scrcpy's program ends at once: opening fails with what it said, its forward and file taken off", SKIP, async () => {
  const closed = net.createServer();
  await new Promise<void>((resolve) => closed.listen(0, "127.0.0.1", resolve));
  const port = (closed.address() as net.AddressInfo).port;
  await new Promise((resolve) => closed.close(resolve));
  const adb = fakeAdb(`${EMULATOR}\tdevice\n`, { port, scrcpy: "echo 'Aborted: no display' >&2; exit 1" });
  const { screens, androids } = source(adb);
  try {
    const emulator = await until(() => screens.get(`android:${EMULATOR}`));
    await assert.rejects(emulator.open(H264), refused(503, "station.screen.failed", /Aborted: no display/));
    await adb.called(`forward --remove tcp:${port}`);
    await adb.called("rm -f");
  } finally {
    androids.close();
  }
});

test("scrcpy's program takes the connection and says nothing: opening fails in its time, not never", SKIP, async () => {
  const silent = await fakeDevice({ silent: true });
  const adb = fakeAdb(`${EMULATOR}\tdevice\n`, { port: silent.port });
  const { screens, androids } = source(adb, { connectTimeout: 200 });
  try {
    const emulator = await until(() => screens.get(`android:${EMULATOR}`));
    await assert.rejects(emulator.open(H264), refused(503, "station.screen.failed", /did not start/));
  } finally {
    androids.close();
    silent.close();
  }
});

test("an emulator that has not booted yet is listed once it has, adb saying nothing more", SKIP, async () => {
  const dir = mkdtempSync(join(tmpdir(), "android-screens-"));
  dirs.push(dir);
  const booted = join(dir, "booted");
  const asked = join(dir, "asked");
  followed(asked);
  const adb = join(dir, "adb");
  writeFileSync(adb, `#!/bin/sh
case "$*" in
  track-devices*) printf '0015emulator-5554\\tdevice\\n'; exec sleep 60 ;;
  *sys.boot_completed*) echo x >> "${asked}"; [ -e "${booted}" ] && echo 1 || echo 0 ;;
  *"getprop ro.kernel.qemu"*) printf '\\n1\\n' ;;
  *ro.serialno*) printf 'EMU\\nsdk\\n16\\nnull\\n' ;;
  *"emu avd name"*) printf 'pixel\\nOK\\n' ;;
  *"wm size"*) echo 'Physical size: 1080x2400' ;;
esac
`);
  chmodSync(adb, 0o755);
  const screens = makeScreens();
  screens.watch(changed);
  const androids = new AndroidScreens({ screens, adb: () => adb, serverPort: SERVER_PORT, file: adb, lookAgain: 20 });
  try {
    androids.start();
    // Looked at again means the first look ended, with nothing listed.
    await until(() => readFileSync(asked, "utf8").length >= 4);
    assert.deepEqual(screens.list(), []);
    writeFileSync(booted, "");
    await until(() => screens.list().length === 1);
    const [s] = screens.list();
    assert.deepEqual([s!.id, s!.kind, s!.title!(), s!.size!()], ["android:emulator-5554", "android", "pixel · Android 16", { width: 1080, height: 2400 }]);
  } finally {
    androids.close();
  }
});

test("adb's devices are followed as the screens are asked for, and let go of a while after with none there", SKIP, async () => {
  const saved = wall.after;
  const due: [number, () => void][] = [];
  wall.after = (ms, f) => (due.push([ms, f]), () => {});
  const dir = mkdtempSync(join(tmpdir(), "android-rest-"));
  dirs.push(dir);
  const adb = join(dir, "adb");
  const started = join(dir, "started"), stopped = join(dir, "stopped");
  followed(started, stopped);
  writeFileSync(adb, `#!/bin/sh
case "$*" in
  track-devices*)
    trap 'echo x >> "${stopped}"; kill "$held"; exit 0' TERM
    sleep 60 > /dev/null 2>&1 &
    held=$!
    printf '0000'
    echo x >> "${started}"
    wait ;;
esac
`);
  chmodSync(adb, 0o755);
  let looked = 0;
  const androids = new AndroidScreens({ screens: makeScreens(), adb: () => (looked++, adb), serverPort: SERVER_PORT, file: adb });
  const count = (path: string) => readFileSync(path, "utf8").length / 2;
  try {
    assert.equal(looked, 0, "not from the start");
    void androids.refresh();
    await until(() => count(started) === 1);
    // The while after it, none there: let go of, and not followed again by itself.
    for (const [ms, f] of due.splice(0)) if (ms >= 60_000) f();
    await until(() => count(stopped) === 1);
    // (a wrong follow-up of the process's end has no event: turns of the loop give it the time to show, and a passing
    // run does not rest on them)
    for (let i = 0; i < 200; i++) await readFile(started);
    assert.deepEqual(due.map(([ms]) => ms), []);
    assert.equal(count(started), 1);
    void androids.refresh();
    await until(() => count(started) === 2);
  } finally {
    wall.after = saved;
    androids.close();
  }
});

test("the size wm says: the override over the physical", () => {
  assert.deepEqual(sizeOf("Physical size: 1140x2616\n"), { width: 1140, height: 2616 });
  assert.deepEqual(sizeOf("Physical size: 1140x2616\nOverride size: 720x1652\n"), { width: 720, height: 1652 });
  assert.deepEqual(sizeOf("nothing"), { width: 0, height: 0 });
});

test("each display's corners as shares of its width, 0 where it has none", () => {
  const line = roundedLine;
  const panels = panelsOf([line(1000, 2000, 100), "other", line(2000, 2200, 50), line(1000, 2000, 100), line(9, 9, 0), `mBaseDisplayInfo=DisplayInfo{real 5 x 5, roundedCorners null}`].join("\n"));
  assert.deepEqual(panels, [
    { width: 1000, height: 2000, corners: [0.1, 0.1, 0.1, 0.1] },
    { width: 2000, height: 2200, corners: [0.025, 0.025, 0.025, 0.025] },
    { width: 9, height: 9, corners: [0, 0, 0, 0] },
    { width: 5, height: 5, corners: [0, 0, 0, 0] },
  ]);
});

test("a panel's corners as Android 16 says them, of its device and not its base info", () => {
  const device = (width: number, height: number, radius: number, id: string) =>
    `  DisplayDeviceInfo{"Built-in Screen": uniqueId="local:${id}", ${width} x ${height}, modeId 1, roundedCorners RoundedCorners{[RoundedCorner{position=TopLeft, radius=${radius}, center=Point(85, 85)}, RoundedCorner{position=TopRight, radius=${radius}, center=Point(1991, 85)}, RoundedCorner{position=BottomRight, radius=${radius}, center=Point(1991, 2067)}, RoundedCorner{position=BottomLeft, radius=${radius}, center=Point(85, 2067)}]}, FLAG_DEFAULT_DISPLAY}`;
  const base = (id: number, width: number, height: number) => `    mBaseDisplayInfo=DisplayInfo{"Built-in Screen", displayId ${id}, FLAG_SECURE, real ${width} x ${height}, largest app ${width} x ${height}}`;
  // As a Pixel 9 Pro Fold AVD's `dumpsys display` has them: the base info before and after what says the corners.
  const panels = panelsOf([device(2000, 2152, 80, "1"), device(1000, 2424, 110, "2"), base(0, 2000, 2152), base(3, 1000, 2424)].join("\n"));
  assert.deepEqual(panels, [
    { width: 2000, height: 2152, corners: [0.04, 0.04, 0.04, 0.04] },
    { width: 1000, height: 2424, corners: [0.11, 0.11, 0.11, 0.11] },
  ]);
});

test("a view's size: the longer of what it asked, as the client shows it, at most 2560", () => {
  const options = { codecs: ["h264" as const] };
  assert.equal(sideOf({ ...options, maxWidth: 723, maxHeight: 723 }), 720);
  assert.equal(sideOf({ ...options, maxWidth: 400, maxHeight: 800, peek: true }), 800);
  assert.equal(sideOf({ ...options, maxWidth: 3840, maxHeight: 2160 }), 2560);
});

// Ported from still.fail#4384 (station/test/android-screen.test.ts): twice the rates they were.
test("a view's rate by its side: 2 Mbit/s at 480, 3 at 720, 5 at 1080, 7 at 1440, 8 above", () => {
  assert.deepEqual([320, 480, 481, 720, 1080, 1280, 1440, 1600, 2560].map(bitrateOf), [2e6, 2e6, 3e6, 3e6, 5e6, 7e6, 7e6, 8e6, 8e6]);
});

test("a finger: down, moves, up, in the picture's pixels with its size", () => {
  const input = new AndroidInput();
  assert.deepEqual(input.messages({ t: "pointer", kind: "move", x: 0.5, y: 0.5, buttons: 0 }, size), []);
  const [down] = input.messages({ t: "pointer", kind: "down", x: 0.5, y: 0.25, buttons: 1 }, size);
  assert.equal(down!.length, 32);
  assert.deepEqual([down![0], down![1]], [2, 0]);
  assert.equal(down!.readBigInt64BE(2), -2n);
  assert.deepEqual([down!.readInt32BE(10), down!.readInt32BE(14), down!.readUInt16BE(18), down!.readUInt16BE(20), down!.readUInt16BE(22)], [500, 500, 1000, 2000, 0xffff]);
  assert.equal(input.messages({ t: "pointer", kind: "move", x: 1, y: 1, buttons: 1 }, size)[0]![1], 2);
  // (at the very edge: within the picture)
  assert.equal(input.messages({ t: "pointer", kind: "move", x: 1, y: 1, buttons: 1 }, size)[0]!.readInt32BE(10), 999);
  const [up] = input.messages({ t: "pointer", kind: "up", x: 1, y: 1, buttons: 0 }, size);
  assert.deepEqual([up![1], up!.readUInt16BE(22)], [1, 0]);
  assert.deepEqual(input.messages({ t: "pointer", kind: "up", x: 1, y: 1, buttons: 0 }, size), []);
});

test("a wheel: 21 bytes, down as a negative vertical scroll in 16ths", () => {
  const [m] = new AndroidInput().messages({ t: "wheel", x: 0.5, y: 0.5, dx: 0, dy: 100 }, size);
  assert.equal(m!.length, 21);
  assert.equal(m![0], 3);
  assert.equal(m!.readInt16BE(13), 0);
  assert.equal(m!.readInt16BE(15), -2048);
  assert.deepEqual(new AndroidInput().messages({ t: "wheel", x: 0, y: 0, dx: 0, dy: 0 }, size), []);
});

test("text as scrcpy takes it: printable ASCII typed as keys, anything else pasted through the device's clipboard", () => {
  const size = { width: 1080, height: 2400 };
  const input = new AndroidInput();
  const [typed, ...more] = input.messages({ t: "text", text: "hi there" }, size);
  assert.equal(more.length, 0);
  // INJECT_TEXT: its type, the length, the UTF-8.
  assert.equal(typed![0], 1);
  assert.equal(typed!.readUInt32BE(1), 8);
  assert.equal(typed!.subarray(5).toString("utf8"), "hi there");
  // SET_CLIPBOARD with paste: its type, a sequence of 0 (no answer), paste, the length, the UTF-8.
  const [pasted] = input.messages({ t: "text", text: "你好" }, size);
  assert.equal(pasted![0], 9);
  assert.equal(pasted!.readBigUInt64BE(1), 0n);
  assert.equal(pasted![9], 1);
  assert.equal(pasted!.readUInt32BE(10), 6);
  assert.equal(pasted!.subarray(14).toString("utf8"), "你好");
  // A line break, or more than scrcpy injects as keys, is pasted too.
  assert.equal(input.messages({ t: "text", text: "a\nb" }, size)[0]![0], 9);
  assert.equal(input.messages({ t: "text", text: "x".repeat(301) }, size)[0]![0], 9);
  assert.deepEqual(input.messages({ t: "text", text: "" }, size), []);
});

test("keys: keycode and meta state; the app's device buttons press the device's", () => {
  const input = new AndroidInput();
  const [a] = input.messages({ t: "key", kind: "down", key: "a", code: "KeyA", mods: 8 }, size);
  assert.equal(a!.length, 14);
  assert.deepEqual([a![0], a![1], a!.readInt32BE(2), a!.readInt32BE(10)], [0, 0, KEYCODES.KeyA, metaOf(8)]);
  assert.equal(metaOf(1 | 2 | 4 | 8), 0x12 | 0x3000 | 0x30000 | 0x41);
  const keycodes = (mods: number, code: string, kind: "down" | "up" = "down") => input.messages({ t: "key", kind, key: "", code, mods }, size).map((m) => [m[1], m.readInt32BE(2)]);
  assert.deepEqual(keycodes(4 | 8, "KeyH"), [[0, 3], [1, 3]]);
  assert.deepEqual(keycodes(4 | 8, "KeyH", "up"), []);
  assert.deepEqual(keycodes(2 | 4 | 8, "KeyH"), [[0, 187], [1, 187]]);
  assert.deepEqual(keycodes(4, "KeyL"), [[0, 26], [1, 26]]);
  assert.deepEqual(keycodes(4, "KeyK"), []);
  assert.deepEqual(keycodes(0, "Escape"), [[0, 4]]);
  assert.deepEqual(keycodes(0, "Nothing"), []);
  assert.deepEqual(input.messages({ t: "device", name: "volume_up" }, size).map((m) => m.readInt32BE(2)), [24, 24]);
  // (not a control message: AndroidView turns it by adb)
  assert.deepEqual(input.messages({ t: "device", name: "rotate" }, size), []);
  assert.deepEqual(input.messages({ t: "pose", name: "open" }, size), []);
});

test("Annex B to AVCC: start codes of both lengths, the config's units in its avcC", () => {
  const nals = nalsOf(new Uint8Array([0, 0, 0, 1, ...SPS, 0, 0, 1, ...PPS, 0, 0, 0, 1, ...IDR]));
  assert.deepEqual(nals.map((n) => [...n]), [SPS, PPS, IDR]);
  assert.deepEqual([...avcCOf(nals)!], [1, 0x42, 0xc0, 0x1f, 0xff, 0xe1, 0, 5, ...SPS, 1, 0, 2, ...PPS]);
  assert.equal(avcCOf([new Uint8Array(IDR)]), null);
  // (its lengths are 16 bits: a larger one is no avcC, and no RangeError in a socket's handler)
  assert.equal(avcCOf([new Uint8Array(70_000).fill(0x67), new Uint8Array(PPS)]), null);
  assert.equal(avcCOf([new Uint8Array(SPS), new Uint8Array(70_000).fill(0x68)]), null);
  assert.deepEqual([...avccOf(nals)], [0, 0, 0, 3, ...IDR]);
});

test("the video socket's stream, however it is cut", () => {
  const whole = Buffer.concat([HEAD, session(556, 1280), packet(0x40, 0, Buffer.from([1, 2])), packet(0x20, 500, Buffer.from([3])), packet(0, 533, Buffer.from([4, 5, 6]))]);
  for (const cut of [whole.length, 1, 7]) {
    const sizes: unknown[] = [], packets: unknown[] = [];
    const stream = new ScrcpyStream((s) => sizes.push(s), (p) => packets.push([p.config, p.key, Number(p.pts), [...p.data]]), () => assert.fail("not too long"));
    for (let at = 0; at < whole.length; at += cut) stream.heard(whole.subarray(at, at + cut));
    assert.deepEqual(sizes, [{ width: 556, height: 1280 }]);
    assert.deepEqual(packets, [[true, false, 0, [1, 2]], [false, true, 500, [3]], [false, false, 533, [4, 5, 6]]]);
  }
});

test("a foldable is put back to the lock it was found with, or the system's own where it said none", () => {
  assert.equal(restoreOf("enabled\nlock 2\n"), "cmd device_state state reset; wm fixed-to-user-rotation enabled; wm user-rotation lock 2");
  assert.equal(restoreOf("default\nfree\n"), "cmd device_state state reset; wm fixed-to-user-rotation default; wm user-rotation free");
  assert.equal(restoreOf("x; reboot\nlock 9; reboot"), "cmd device_state state reset; wm fixed-to-user-rotation default; wm user-rotation free");
});
