// A computer's phones and the agents' leases (src/screens/devices.ts, src/screens/android-agent.ts) against a fake adb
// at an absolute path: never a real adb, phone or emulator, never the person's server (5037), never the first device of
// a list. Every device call names one exact serial, and a phone its owner did not choose gets none.
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { ConfigFile } from "../src/ops/config.ts";
import { AGENT_KEYS, pngSize, stateOf, textCommand } from "../src/screens/android-agent.ts";
import { phoneCandidate, transportsOf, wirelessAddress } from "../src/screens/android.ts";
import { AndroidDevices, phoneChoicesOf } from "../src/screens/devices.ts";
import { follow } from "./support/follow.ts";

const SKIP = { skip: process.platform === "win32" };
const EMULATOR = "emulator-5554";
const PHONE = "3B162S00P0N00000";
/// Another phone on the same machine that its owner never chose.
const OTHER = "R5CT10ABCDE";
const WIFI = "192.168.1.20:41234";
const SERVER_PORT = 15931;
/// Addresses on this machine, as adb names devices there (no test listens on them): a lent phone's, an emulator's.
const at = (host: string, port: number) => `${host}:${port}`;
const LENT = at("127.0.0.1", 37715);
/// The person's phones first: a list's first device is never the one meant.
const DEVICES = `${OTHER}\tdevice usb:1-1 product:x model:Galaxy_S24 device:y\n${PHONE}\tdevice usb:1-2 product:p model:Pixel_8 device:d\nadb-${PHONE}-KLb58I._adb-tls-connect._tcp\tdevice\n${LENT}\tdevice\n${EMULATOR}\tdevice product:sdk model:sdk_gphone64 device:emu\n`;

process.env.ADB_USB = "1";
process.env.ANDROID_ADB_SERVER_PORT = "5037";
delete process.env.COMMA_STATION_CONFIG;
delete process.env.EMBER_CONFIG;

let waiting: (() => void)[] = [];
const changed = () => {
  const woken = waiting;
  waiting = [];
  for (const wake of woken) wake();
};
async function until(what: () => boolean) {
  while (!what()) await new Promise<void>((resolve) => waiting.push(resolve));
}

/// A PNG's signature and header: what the source reads its size from.
function png(width: number, height: number): Buffer {
  const b = Buffer.alloc(33);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(b, 0);
  b.writeUInt32BE(13, 8);
  b.write("IHDR", 12, "latin1");
  b.writeUInt32BE(width, 16);
  b.writeUInt32BE(height, 20);
  return b;
}

function fakeAdb(t: TestContext) {
  const dir = mkdtempSync(join(tmpdir(), "fake-android-phones-"));
  writeFileSync(join(dir, "calls"), "");
  // (as a device with several displays says it: which display it took, then the picture)
  writeFileSync(join(dir, "shot.png"), Buffer.concat([Buffer.from("[Warning] Multiple displays were found, but no display id was specified! Defaulting to the first display found, however this default is not guaranteed to be consistent across captures. A display id should be specified.\n"), png(1080, 2400)]));
  writeFileSync(join(dir, "adb"), `#!/bin/sh
printf '%s\\t%s\\t%s\\n' "\${ADB_USB-}" "$ANDROID_ADB_SERVER_PORT" "$*" >> "${dir}/calls"
case "$*" in
  track-devices*) printf '%04x%s' ${Buffer.byteLength(DEVICES)} '${DEVICES}'; exec sleep 60 ;;
  kill-server) : ;;
  connect*) echo "connected to $2" ;;
  disconnect*) echo "disconnected $2" ;;
  *sys.boot_completed*) echo 1 ;;
  *random/boot_id*) echo "boot" >> "${dir}/boots"; while [ -e "${dir}/hold" ]; do sleep 0.01; done; echo 0b5a6c2e-1d2f-4a3b-9c8d-7e6f5a4b3c2d ;;
  *"emu avd discoverypath"*) printf '/tmp/avd/running/pid_77.ini\\nOK\\n' ;;
  *"getprop ro.kernel.qemu"*) printf '\\n1\\n' ;;
  "-s ${PHONE} shell getprop ro.serialno"*) printf '${PHONE}\\nPixel 8\\n15\\nnull\\n' ;;
  *ro.serialno*) printf 'EMULATOR30X\\nsdk\\n16\\nnull\\n' ;;
  *"emu avd name"*) printf 'Pixel_9\\nOK\\n' ;;
  *"wm size"*) echo 'Physical size: 1080x2400' ;;
  *"dumpsys power"*) echo "state" >> "${dir}/states"; while [ -e "${dir}/holdstate" ]; do sleep 0.01; done; echo '  mWakefulness=Awake'; if [ -e "${dir}/locked" ]; then echo '    mShowingDream=false mDreamingLockscreen=true'; else echo '    mShowingDream=false mDreamingLockscreen=false'; fi ;;
  *"exec-out screencap -p"*) cat "${dir}/shot.png" ;;
  *"settings get system show_touches"*) echo 0 ;;
  *"settings put system show_touches 0"*) sleep 0.2; printf '\t\tput back\n' >> "${dir}/calls" ;;
esac
`);
  chmodSync(join(dir, "adb"), 0o755);
  const stop = follow(["calls", "boots", "states"].map((name) => join(dir, name)), changed);
  t.after(() => {
    stop();
    rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
  });
  const calls = () => readFileSync(join(dir, "calls"), "utf8").split("\n").filter(Boolean).map((line) => {
    const [usb, port, args] = line.split("\t");
    return { usb, port, args: args! };
  });
  return {
    path: join(dir, "adb"),
    calls,
    /// The device's boot read waits until `hold(false)`: a start stands in the middle of its look.
    hold: (on: boolean) => (on ? writeFileSync(join(dir, "hold"), "") : existsSync(join(dir, "hold")) && unlinkSync(join(dir, "hold"))),
    /// The phone's lock state read waits until `holdState(false)`: an action stands between its look and its input.
    holdState: (on: boolean) => (on ? writeFileSync(join(dir, "holdstate"), "") : existsSync(join(dir, "holdstate")) && unlinkSync(join(dir, "holdstate"))),
    /// How many times its lock state was asked for.
    states: () => (existsSync(join(dir, "states")) ? readFileSync(join(dir, "states"), "utf8").split("\n").filter(Boolean).length : 0),
    /// How many times its boot was asked for.
    boots: () => (existsSync(join(dir, "boots")) ? readFileSync(join(dir, "boots"), "utf8").split("\n").filter(Boolean).length : 0),
    lock: (on: boolean) => (on ? writeFileSync(join(dir, "locked"), "") : existsSync(join(dir, "locked")) && unlinkSync(join(dir, "locked"))),
  };
}

/// The leases' time, moved by the test alone; its timers never fire by themselves (the lease's own timer is queued
/// behind the action under way, as it can be on a busy station).
function testClock() {
  let now = 1_000_000;
  return { now: () => now, after: (_ms: number, _f: () => void) => () => {}, set: (at: number) => void (now = at) };
}

function devicesOn(t: TestContext, adb: ReturnType<typeof fakeAdb>, config?: unknown, clock?: ReturnType<typeof testClock>) {
  const data = mkdtempSync(join(tmpdir(), "android-phones-data-"));
  if (config !== undefined) writeFileSync(join(data, "config.json"), JSON.stringify(config));
  const devices = new AndroidDevices({ config: new ConfigFile(data), adb: () => adb.path, serverPort: SERVER_PORT, ...(clock ? { clock } : {}) });
  devices.screens.watch(changed);
  t.after(async () => {
    await devices.close();
    rmSync(data, { recursive: true, force: true });
  });
  return { devices, data };
}

const stored: Buffer[] = [];
const images = async (shot: Buffer) => (stored.push(shot), { ok: true, image_path: `capture-${stored.length}.png`, image_content_type: "image/png", image_size_bytes: shot.length });

test("what adb says of its devices, before anything asks one: model and transport, and which may be chosen", () => {
  assert.deepEqual(transportsOf(DEVICES).filter((d) => phoneCandidate(d.serial)), [
    { serial: OTHER, state: "device", model: "Galaxy S24", transport: "usb" },
    { serial: PHONE, state: "device", model: "Pixel 8", transport: "usb" },
  ]);
  assert.equal(transportsOf(`${WIFI}\tunauthorized\n`)[0]!.transport, "wifi");
  for (const serial of [EMULATOR, LENT, `adb-${PHONE}._adb-tls-connect._tcp`, at("localhost", 5555)]) assert.equal(phoneCandidate(serial), false, serial);
});

test("an address to connect over Wi-Fi: a host and a port, never this machine", () => {
  assert.equal(wirelessAddress(` ${WIFI} `), WIFI);
  assert.equal(wirelessAddress("Pixel.local:5555"), "pixel.local:5555");
  for (const said of [at("127.0.0.1", 5555), at("localhost", 5555), at("0.0.0.0", 1), at("[::1]", 5555), "192.168.1.20", "192.168.1.20:0", "192.168.1.20:70000", "a b:1", "x:1; rm -rf /"]) assert.equal(wirelessAddress(said), null, said);
});

test("the owner's choices in config.json: nothing chosen and USB off unless it says so", () => {
  assert.deepEqual(phoneChoicesOf({}), { usb: false, chosen: {} });
  assert.deepEqual(phoneChoicesOf({ screens: { phones: { usb: true, chosen: { [PHONE]: { agents: true }, [EMULATOR]: { agents: true }, [LENT]: {} } } } }), { usb: true, chosen: { [PHONE]: { agents: true } } });
});

test("the phones are listed for their owner from what adb says; a phone not chosen gets no adb call at all", SKIP, async (t) => {
  const adb = fakeAdb(t);
  const { devices } = devicesOn(t, adb);
  await devices.androids.refresh();
  await until(() => devices.screens.list().length === 1);
  assert.deepEqual(devices.screens.list().map((s) => s.id), [`android:${EMULATOR}`]);
  assert.deepEqual(devices.phones().map((p) => [p.serial, p.shown, p.agents]), [[OTHER, false, false], [PHONE, false, false]]);
  for (const call of adb.calls()) {
    assert.ok(call.args === "track-devices -l" || call.args.startsWith(`-s ${EMULATOR} `), call.args);
    assert.equal(call.port, String(SERVER_PORT));
    // (USB stays off until its owner turns it on)
    assert.equal(call.usb, "0");
  }
});

test("USB turned on starts the station's own server again without ADB_USB; a chosen phone is a screen, the other is never asked", SKIP, async (t) => {
  const adb = fakeAdb(t);
  const { devices, data } = devicesOn(t, adb);
  await devices.androids.refresh();
  await until(() => devices.screens.list().length === 1);
  await devices.setUsb(true);
  assert.equal(JSON.parse(readFileSync(join(data, "config.json"), "utf8")).screens.phones.usb, true);
  const kill = adb.calls().findIndex((c) => c.args === "kill-server");
  assert.ok(kill > 0);
  // (asked of the server as it was: its port, USB off)
  assert.deepEqual(adb.calls()[kill], { usb: "0", port: String(SERVER_PORT), args: "kill-server" });
  await until(() => adb.calls().slice(kill + 1).some((c) => c.args === "track-devices -l"));
  assert.equal(adb.calls().slice(kill + 1).find((c) => c.args === "track-devices -l")!.usb, "");
  await devices.choose(PHONE, { agents: false });
  await until(() => devices.screens.get(`android:${PHONE}`) !== undefined);
  assert.equal(devices.phones().find((p) => p.serial === PHONE)!.screen, `android:${PHONE}`);
  assert.deepEqual(adb.calls().filter((c) => c.args.includes(OTHER) || /_adb-tls|127\.0\.0\.1/.test(c.args)), []);
  assert.ok(adb.calls().every((c) => c.port === String(SERVER_PORT)));
  // Let go of: no longer a screen.
  await devices.choose(PHONE, null);
  await until(() => devices.screens.get(`android:${PHONE}`) === undefined);
});

test("a phone over Wi-Fi: connected on the station's server at its owner's word, and shown", SKIP, async (t) => {
  const adb = fakeAdb(t);
  const { devices } = devicesOn(t, adb);
  assert.equal(await devices.connect(WIFI), `connected to ${WIFI}`);
  assert.ok(adb.calls().some((c) => c.args === `connect ${WIFI}` && c.port === String(SERVER_PORT)));
  assert.deepEqual(devices.choices().chosen, { [WIFI]: { agents: false } });
  await assert.rejects(devices.connect(LENT), /not an address/);
  assert.equal(await devices.disconnect(WIFI), `disconnected ${WIFI}`);
  assert.deepEqual(devices.choices().chosen, {});
});

/// The emulator and the phone, chosen for agents, both listed.
async function leasable(t: TestContext, agents = true, clock?: ReturnType<typeof testClock>) {
  const adb = fakeAdb(t);
  const { devices, data } = devicesOn(t, adb, { screens: { phones: { usb: true, chosen: { [PHONE]: { agents } } } } }, clock);
  await devices.androids.refresh();
  await until(() => devices.screens.list().length === 2);
  return { adb, devices, agents: devices.agents, data };
}

test("agents: an emulator is leased at once; status lists no phone its owner kept from agents", SKIP, async (t) => {
  const { devices, agents } = await leasable(t, false);
  const status = await agents.call({ action: "status" }, images);
  assert.deepEqual((status.devices as { target: string }[]).map((d) => d.target), [`android:${EMULATOR}`]);
  assert.equal((await agents.call({ action: "start", target: `android:${PHONE}`, consent: true }, images)).error_code, "android_phone_not_offered");
  const lease = await agents.call({ action: "start", target: `android:${EMULATOR}` }, images);
  assert.equal(lease.ok, true);
  assert.equal(devices.screens.get(`android:${EMULATOR}`)!.agent, "agent");
  // One lease a device.
  assert.equal((await agents.call({ action: "start", target: `android:${EMULATOR}` }, images)).error_code, "android_leased");
  assert.deepEqual(await agents.call({ action: "end", lease_id: lease.lease_id }, images), { ok: true, ended: true });
  assert.equal(devices.screens.get(`android:${EMULATOR}`)!.agent, null);
});

test("those who look at an emulator hear an agent's lease start and end, and where its finger presses, as a share of its screenshot", SKIP, async (t) => {
  const { devices, agents } = await leasable(t, false);
  const source = devices.androids.sourceOf(`android:${EMULATOR}`)!;
  const heard: unknown[] = [];
  const stop = source.watchAgent((said) => heard.push(said));
  const lease = await agents.call({ action: "start", target: `android:${EMULATOR}` }, images);
  // (before a screenshot says what its pixels are, no place is said)
  assert.deepEqual(await agents.call({ action: "tap", lease_id: lease.lease_id, x: 1, y: 1 }, images), { ok: true });
  assert.equal((await agents.call({ action: "observe", lease_id: lease.lease_id }, images)).image_width, 1080);
  assert.deepEqual(await agents.call({ action: "tap", lease_id: lease.lease_id, x: 540, y: 600 }, images), { ok: true });
  assert.deepEqual(await agents.call({ action: "swipe", lease_id: lease.lease_id, from: [108, 1200], to: [972, 1200] }, images), { ok: true });
  assert.deepEqual(await agents.call({ action: "end", lease_id: lease.lease_id }, images), { ok: true, ended: true });
  stop();
  assert.deepEqual(heard, [
    { agent: false },
    { agent: true },
    { agentPointer: { x: 0.5, y: 0.25, down: true } },
    { agentPointer: { x: 0.5, y: 0.25, down: false } },
    { agentPointer: { x: 0.1, y: 0.5, down: true } },
    { agentPointer: { x: 0.9, y: 0.5, down: false } },
    { agent: false },
  ]);
});

test("agents on a phone: only with its owner's consent; it says so while leased and is put back at the end", SKIP, async (t) => {
  const { adb, agents } = await leasable(t);
  const asked = await agents.call({ action: "start", target: `android:${PHONE}` }, images);
  assert.equal(asked.error_code, "android_consent_required");
  assert.equal(asked.title, "Pixel 8 · Android 15");
  assert.ok(!adb.calls().some((c) => /show_touches|notification/.test(c.args)));
  const lease = await agents.call({ action: "start", target: `android:${PHONE}`, consent: true, lease_seconds: 120 }, images);
  assert.equal(lease.ok, true);
  assert.equal(lease.kind, "phone");
  assert.ok(adb.calls().some((c) => c.args.startsWith(`-s ${PHONE} shell settings put system show_touches 1; cmd notification post`)));
  const seen = await agents.call({ action: "observe", lease_id: lease.lease_id, lease_epoch: lease.lease_epoch }, images);
  assert.deepEqual([seen.ok, seen.image_path, seen.image_width, seen.image_height, seen.locked, seen.screen_on], [true, `capture-${stored.length}.png`, 1080, 2400, false, true]);
  assert.ok(adb.calls().some((c) => c.args === `-s ${PHONE} exec-out screencap -p`));
  assert.deepEqual(await agents.call({ action: "tap", lease_id: lease.lease_id, x: 540.4, y: 1200 }, images), { ok: true });
  assert.ok(adb.calls().some((c) => c.args === `-s ${PHONE} shell input tap 540 1200`));
  assert.deepEqual(await agents.call({ action: "end", lease_id: lease.lease_id }, images), { ok: true, ended: true });
  await until(() => adb.calls().some((c) => c.args.startsWith(`-s ${PHONE} shell settings put system show_touches 0`)));
  assert.equal((await agents.call({ action: "observe", lease_id: lease.lease_id }, images)).error_code, "android_lease_unknown");
  // Every call to a device named one exact serial, on the station's own server.
  for (const call of adb.calls()) assert.ok(/^(track-devices -l|kill-server|put back)$/.test(call.args) || call.args.startsWith(`-s ${PHONE} `) || call.args.startsWith(`-s ${EMULATOR} `), call.args);
  assert.ok(!adb.calls().some((c) => c.args.includes(OTHER)));
});

test("a locked phone takes no input but wakeup; a person driving it holds every agent's input off", SKIP, async (t) => {
  const { adb, devices, agents } = await leasable(t);
  const lease = await agents.call({ action: "start", target: `android:${PHONE}`, consent: true }, images);
  adb.lock(true);
  for (const action of [{ action: "tap", x: 1, y: 1 }, { action: "type", text: "1234" }, { action: "swipe", from: [1, 1], to: [1, 900] }, { action: "key", key: "enter" }])
    assert.equal((await agents.call({ ...action, lease_id: lease.lease_id }, images)).error_code, "android_locked", action.action);
  assert.ok(!adb.calls().some((c) => /input (tap|text|swipe)|keyevent 66/.test(c.args)));
  assert.deepEqual(await agents.call({ action: "key", key: "wakeup", lease_id: lease.lease_id }, images), { ok: true });
  assert.ok(adb.calls().some((c) => c.args === `-s ${PHONE} shell input keyevent ${AGENT_KEYS.wakeup}`));
  adb.lock(false);
  const release = devices.androids.sourceOf(`android:${PHONE}`)!.hold();
  assert.equal((await agents.call({ action: "tap", x: 1, y: 1, lease_id: lease.lease_id }, images)).error_code, "android_held_by_person");
  release();
  assert.deepEqual(await agents.call({ action: "type", text: "hi there\n", lease_id: lease.lease_id }, images), { ok: true });
  assert.ok(adb.calls().some((c) => c.args === `-s ${PHONE} shell input text 'hi%sthere'; input keyevent 66`));
});

test("what reaches a device's shell is checked: keys by name, text as ASCII, an app by its package", () => {
  assert.equal(textCommand("it's 100% ok"), "input text 'it'\\''s%s100%%sok'");
  assert.throws(() => textCommand("say %s"), /cannot be typed/);
  assert.throws(() => textCommand("héllo"), /printable ASCII/);
  assert.deepEqual(stateOf("mWakefulness=Asleep\nmDreamingLockscreen=true"), { screen_on: false, locked: true });
  assert.deepEqual(stateOf(""), { screen_on: null, locked: null });
  assert.deepEqual(pngSize(png(10, 20)), { width: 10, height: 20 });
  assert.equal(pngSize(Buffer.from("not a png at all, not at all")), null);
  assert.equal(AGENT_KEYS.power, undefined);
});

test("an agent's look at a station that has not listed its devices yet: adb is followed first, a phone not chosen still asked nothing", SKIP, async (t) => {
  const adb = fakeAdb(t);
  const { devices } = devicesOn(t, adb, { screens: { phones: { usb: true, chosen: { [PHONE]: { agents: true } } } } });
  // (nothing listed the devices: a station just started)
  const status = await devices.agents.call({ action: "status" }, images);
  assert.deepEqual((status.devices as { target: string }[]).map((d) => d.target).sort(), [`android:${EMULATOR}`, `android:${PHONE}`].sort());
  assert.ok(!adb.calls().some((c) => c.args.includes(OTHER)));
});

test("a start on a station that has not listed its devices yet finds the device", SKIP, async (t) => {
  const adb = fakeAdb(t);
  const { devices } = devicesOn(t, adb);
  assert.equal((await devices.agents.call({ action: "start", target: `android:${EMULATOR}` }, images)).ok, true);
});

test("its owner taking a phone back from agents ends the lease at once, put back; no action reaches the phone after", SKIP, async (t) => {
  const { adb, devices, agents } = await leasable(t);
  const lease = await agents.call({ action: "start", target: `android:${PHONE}`, consent: true }, images);
  await devices.choose(PHONE, { agents: false });
  // (put back before the owner's change is answered)
  assert.ok(adb.calls().some((c) => c.args.startsWith(`-s ${PHONE} shell settings put system show_touches 0`)));
  assert.equal(devices.screens.get(`android:${PHONE}`)!.agent, null);
  assert.equal((await agents.call({ action: "tap", x: 1, y: 1, lease_id: lease.lease_id }, images)).error_code, "android_lease_unknown");
  assert.ok(!adb.calls().some((c) => c.args.includes("input tap")));
});

test("each action looks at its owner's word again: a phone taken back by hand in config.json takes no input", SKIP, async (t) => {
  const { adb, devices, agents, data } = await leasable(t);
  const lease = await agents.call({ action: "start", target: `android:${PHONE}`, consent: true }, images);
  // (another writer: the station hears of it at its next read)
  const config = JSON.parse(readFileSync(join(data, "config.json"), "utf8"));
  config.screens.phones.chosen[PHONE].agents = false;
  writeFileSync(join(data, "config.json"), JSON.stringify(config));
  const tapped = await agents.call({ action: "tap", x: 1, y: 1, lease_id: lease.lease_id }, images);
  assert.ok(tapped.error_code === "android_phone_not_offered" || tapped.error_code === "android_lease_unknown", String(tapped.error_code));
  assert.ok(!adb.calls().some((c) => c.args.includes("input tap")));
  await until(() => devices.screens.get(`android:${PHONE}`)?.agent === null);
});

test("two starts at once: one lease, the other refused; touches read once", SKIP, async (t) => {
  const { adb, agents } = await leasable(t);
  const [a, b] = await Promise.all([
    agents.call({ action: "start", target: `android:${PHONE}`, consent: true }, images),
    agents.call({ action: "start", target: `android:${PHONE}`, consent: true }, images),
  ]);
  assert.deepEqual([a.ok, b.ok].sort(), [false, true].sort());
  assert.equal((a.ok ? b : a).error_code, "android_leased");
  assert.equal(adb.calls().filter((c) => c.args.includes("settings get system show_touches")).length, 1);
});

test("an end then a start at once: the phone is put back before the next lease reads what it shows", SKIP, async (t) => {
  const { adb, agents } = await leasable(t);
  const first = await agents.call({ action: "start", target: `android:${PHONE}`, consent: true }, images);
  const [ended, next] = await Promise.all([
    agents.call({ action: "end", lease_id: first.lease_id }, images),
    agents.call({ action: "start", target: `android:${PHONE}`, consent: true }, images),
  ]);
  assert.deepEqual([ended.ok, next.ok], [true, true]);
  const args = adb.calls().map((c) => c.args);
  // (the put-back ended, not only began, before the next lease read the setting)
  const putBack = args.indexOf("put back");
  const reads = args.flatMap((a, i) => (a.includes("settings get system show_touches") ? [i] : []));
  assert.equal(reads.length, 2);
  assert.ok(putBack > reads[0]! && putBack < reads[1]!, JSON.stringify(args.slice(-8)));
});

test("the station stopping while a start waits on adb: the start is refused, nothing stays leased, and phones are put back before adb stops", SKIP, async (t) => {
  const { adb, devices, agents } = await leasable(t);
  const leased = await agents.call({ action: "start", target: `android:${EMULATOR}` }, images);
  assert.equal(leased.ok, true);
  const phone = await agents.call({ action: "start", target: `android:${PHONE}`, consent: true, lease_seconds: 600 }, images);
  await agents.call({ action: "end", lease_id: phone.lease_id }, images);
  const before = adb.boots();
  adb.hold(true);
  const starting = agents.call({ action: "start", target: `android:${PHONE}`, consent: true }, images);
  await until(() => adb.boots() > before);
  const closing = devices.close();
  adb.hold(false);
  const [started] = await Promise.all([starting, closing]);
  assert.equal(started.ok, false);
  assert.equal(devices.screens.list().filter((s) => s.agent).length, 0);
  const args = adb.calls().map((c) => c.args);
  const kill = args.lastIndexOf("kill-server");
  assert.ok(kill > 0);
  assert.ok(!args.slice(kill + 1).some((a) => a.startsWith("-s ")), "nothing reaches a device after its server stopped");
});

test("USB turned on while a listing is under way: a phone not chosen is still asked nothing", SKIP, async (t) => {
  const adb = fakeAdb(t);
  const { devices } = devicesOn(t, adb, { screens: { phones: { usb: false, chosen: { [PHONE]: { agents: false } } } } });
  const listing = devices.androids.refresh();
  const usb = devices.setUsb(true);
  await Promise.all([listing, usb]);
  await devices.androids.refresh();
  await until(() => devices.screens.get(`android:${PHONE}`) !== undefined);
  assert.ok(!adb.calls().some((c) => c.args.includes(OTHER)));
});

/// A phone leased for 60 s, an action of `action` started at 59 s whose lock look answers at 61 s.
async function crossingExpiry(t: TestContext, action: Record<string, unknown>) {
  const clock = testClock();
  const { adb, devices, agents } = await leasable(t, true, clock);
  const start = clock.now();
  const lease = await agents.call({ action: "start", target: `android:${PHONE}`, consent: true, lease_seconds: 60 }, images);
  assert.equal(lease.ok, true);
  clock.set(start + 59_000);
  const before = adb.states();
  adb.holdState(true);
  const acting = agents.call({ ...action, lease_id: lease.lease_id }, images);
  await until(() => adb.states() > before);
  clock.set(start + 61_000);
  adb.holdState(false);
  return { adb, devices, agents, lease, answer: await acting };
}

for (const action of [{ action: "tap", x: 1, y: 1 }, { action: "swipe", from: [1, 1], to: [1, 900] }, { action: "type", text: "hi" }, { action: "key", key: "enter" }, { action: "launch", package: "com.android.settings" }]) {
  test(`a lease whose time runs out while ${action.action} waits on the phone: refused, nothing reaches it, put back at once`, SKIP, async (t) => {
    const { adb, devices, answer } = await crossingExpiry(t, action);
    assert.equal(answer.error_code, "android_lease_expired");
    assert.ok(!adb.calls().some((c) => /input (tap|swipe|text)|keyevent 66|monkey/.test(c.args)));
    // (put back within the action's own turn: before its answer, not by the lease's timer)
    assert.ok(adb.calls().some((c) => c.args.startsWith(`-s ${PHONE} shell settings put system show_touches 0`)));
    assert.equal(devices.screens.get(`android:${PHONE}`)!.agent, null);
  });
}

test("a lease whose time runs out while a look waits on the phone: no screenshot is taken", SKIP, async (t) => {
  const { adb, answer } = await crossingExpiry(t, { action: "observe" });
  assert.equal(answer.error_code, "android_lease_expired");
  assert.ok(!adb.calls().some((c) => c.args.includes("screencap")));
});

test("an action at its lease's deadline is refused and the lease ends, though its timer has not fired", SKIP, async (t) => {
  const clock = testClock();
  const { adb, agents } = await leasable(t, true, clock);
  const lease = await agents.call({ action: "start", target: `android:${PHONE}`, consent: true, lease_seconds: 60 }, images);
  clock.set(clock.now() + 60_000);
  assert.equal((await agents.call({ action: "key", key: "wakeup", lease_id: lease.lease_id }, images)).error_code, "android_lease_expired");
  assert.ok(!adb.calls().some((c) => c.args.includes("keyevent 224")));
  // The device is free again.
  assert.equal((await agents.call({ action: "start", target: `android:${PHONE}`, consent: true }, images)).ok, true);
});

test("its owner taking a phone back while an action waits on it: refused, nothing reaches it, put back", SKIP, async (t) => {
  const { adb, devices, agents, data } = await leasable(t);
  const lease = await agents.call({ action: "start", target: `android:${PHONE}`, consent: true }, images);
  const before = adb.states();
  adb.holdState(true);
  const tapping = agents.call({ action: "tap", x: 1, y: 1, lease_id: lease.lease_id }, images);
  await until(() => adb.states() > before);
  // (by hand, so nothing else ends the lease first)
  const config = JSON.parse(readFileSync(join(data, "config.json"), "utf8"));
  config.screens.phones.chosen[PHONE].agents = false;
  writeFileSync(join(data, "config.json"), JSON.stringify(config));
  adb.holdState(false);
  const tapped = await tapping;
  assert.ok(["android_phone_not_offered", "android_lease_unknown"].includes(String(tapped.error_code)), String(tapped.error_code));
  assert.ok(!adb.calls().some((c) => c.args.includes("input tap")));
  await until(() => devices.screens.get(`android:${PHONE}`)?.agent === null);
});

test("the station stopping while an action waits on the phone: refused, nothing reaches it", SKIP, async (t) => {
  const { adb, devices, agents } = await leasable(t);
  const lease = await agents.call({ action: "start", target: `android:${PHONE}`, consent: true }, images);
  const before = adb.states();
  adb.holdState(true);
  const tapping = agents.call({ action: "tap", x: 1, y: 1, lease_id: lease.lease_id }, images);
  await until(() => adb.states() > before);
  const closing = devices.close();
  adb.holdState(false);
  const [tapped] = await Promise.all([tapping, closing]);
  assert.equal(tapped.ok, false);
  assert.ok(!adb.calls().some((c) => c.args.includes("input tap")));
});

test("its owner taking a phone back while a start reads what the phone shows: no lease, put back", SKIP, async (t) => {
  const { adb, devices, agents, data } = await leasable(t);
  const before = adb.boots();
  adb.hold(true);
  const starting = agents.call({ action: "start", target: `android:${PHONE}`, consent: true }, images);
  await until(() => adb.boots() > before);
  const config = JSON.parse(readFileSync(join(data, "config.json"), "utf8"));
  config.screens.phones.chosen[PHONE].agents = false;
  writeFileSync(join(data, "config.json"), JSON.stringify(config));
  adb.hold(false);
  assert.equal((await starting).error_code, "android_phone_not_offered");
  assert.equal(devices.screens.get(`android:${PHONE}`)?.agent ?? null, null);
  assert.ok(!adb.calls().some((c) => c.args.includes("show_touches 1")));
});

