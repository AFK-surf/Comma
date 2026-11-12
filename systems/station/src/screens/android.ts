// Android emulators on an adb server of the station's own as screen sources (`android:<id>`, docs/android-screen.md): a
// touchscreen, its pictures and input through scrcpy's program on the device (scrcpy-server, its version pinned: its
// protocol is its own and changes between releases). Ported from still.fail's station/src/screens/android.ts. A phone is
// not touched unless its owner chose its serial (`phones`, screens/devices.ts); before that only what the adb server
// says of it is read (`phonesOn`).
import { type ChildProcess, type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { createHash, randomInt } from "node:crypto";
import { existsSync } from "node:fs";
import net from "node:net";
import { fileURLToPath } from "node:url";
import { wall } from "../ops/fibers.ts";
import { stationLang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { platform } from "../platform/index.ts";
import { AndroidDebug } from "./android-debug.ts";
import { type AppLogs, androidLogs, childLines } from "./app-logs.ts";
import { ScreenRefused } from "./hub.ts";
import { AgentPresence, type AgentSaid, type DeviceDebug, type DeviceInput, type DevicePose, type DeviceStands, type Frame, type FrameConfig, type Panel, type ScreenInput, type ScreenSource, type ScreenVideo, type ScreenView, type Screens, type ViewOptions } from "./source.ts";

/// The version of scrcpy-server (`scripts/native.ts`, the part `scrcpy-server`): it refuses to run under any other name.
const SERVER_VERSION = "5.0.1";
/// How long a view's program has to start listening on the device.
const CONNECT_TIMEOUT = 15_000;
/// How long a look at a device is given (a phone over Wi-Fi may be slow, one that has gone never answers).
const ADB_TIMEOUT = 15_000;
/// How long after `adb track-devices` ended it is started again.
const FOLLOW_AGAIN = 5_000;
/// How long a listing waits for a new adb server to say what it has.
const FIRST_ANSWER_MS = 3_000;
/// How long after a device could not be looked at it is looked at again (adb has an emulator long before it has booted).
const LOOK_AGAIN = 3_000;
/// How long adb's devices are followed after the screens were last asked for, none of them there: followed from the
/// station's start, adb's server and `track-devices` ran even on machines without a device. One there keeps them followed.
const FOLLOWED_FOR = 10 * 60_000;
/// Encoded frames kept for a view that asks slowly: past this they are dropped up to a new key frame (a delta dropped
/// alone would break every frame after it).
const QUEUE_MOST = 30;
/// The largest packet the program is taken to send: past this its stream is not one, and is not read on.
const PACKET_MOST = 32 << 20;
/// What a view is encoded at, by the side it asked: the encoder takes no new rate while it runs, so a view cannot start low
/// and go up as a helper's does: 2 Mbit/s at 480, 3 at 720, 5 at 1080, 7 at 1440, 8 above, while the picture moves
/// (nothing when it is still). Twice what they were, as still.fail#4384 has them: at half these a phone's text moving
/// stayed soft. Salix carries a node's relays in about 2 MiB/s (StationRelay's `@node_budget`, an experiment's value):
/// three views at 1080 moving at once are about that much.
export function bitrateOf(side: number): number {
  return side <= 480 ? 2_000_000 : side <= 720 ? 3_000_000 : side <= 1080 ? 5_000_000 : side <= 1440 ? 7_000_000 : 8_000_000;
}
/// A preview (a link's card): about two pictures a second, small and cheap.
const PEEK_FPS = 2;
const PEEK_BITRATE = 300_000;
const MOST_SIDE = 2560;
/// How far apart two width-to-height ratios are the one shape (a picture's size is rounded to multiples of 8).
const SAME_SHAPE = 0.02;
const SCROLL_MOST = 16;
/// A page's wheel pixels in one notch of Android's AXIS_SCROLL.
const WHEEL_NOTCH = 100;

// Control messages (scrcpy's ControlMessage.java)
const CONTROL_KEY = 0, CONTROL_TEXT = 1, CONTROL_TOUCH = 2, CONTROL_SCROLL = 3, CONTROL_CLIPBOARD = 9, CONTROL_RESET = 17;
/// The most text scrcpy injects as keys (its ControlMessageReader's TEXT_MAX_LENGTH); more is pasted.
const TEXT_MOST = 300;
const TOUCH_DOWN = 0, TOUCH_UP = 1, TOUCH_MOVE = 2;
/// scrcpy's POINTER_ID_GENERIC_FINGER: a finger, not its mouse.
const FINGER = -2n;
/// The display turned a quarter (out of following the sensor, as a person's own lock does).
const ROTATE = `case "$(wm user-rotation)" in "lock 1") n=2;; "lock 2") n=3;; "lock 3") n=0;; *) n=1;; esac; wm user-rotation lock $n`;
/// The same on a foldable, whose system keeps its display's lock per pose: it answers `wm user-rotation lock` with `free` and
/// stays where it stands (Android 16's foldable AVD), so the display is fixed to what is asked, and what was last asked is
/// the setting's.
/// What a foldable's display was before it was first turned or folded from here, read then.
const FOUND = "wm fixed-to-user-rotation; wm user-rotation";

/// What puts a foldable back: its own pose (the override dropped) and its display's lock as `found` said it (FOUND), or
/// the system's own where it said nothing readable. Left as it was asked, a headless AVD keeps a forced pose and a fixed
/// display for good (they outlive a reboot).
export function restoreOf(found: string): string {
  const [fixed, rotation] = found.split("\n").map((line) => line.trim());
  const keep = fixed === "enabled" || fixed === "disabled" ? fixed : "default";
  const lock = /^lock [0-3]$/.test(rotation ?? "") ? `wm user-rotation ${rotation}` : "wm user-rotation free";
  return `cmd device_state state reset; wm fixed-to-user-rotation ${keep}; ${lock}`;
}

const REPLACED = "another device has its place now";

/// This boot's id, the kernel's; null when it says none that is one.
const BOOT = "cat /proc/sys/kernel/random/boot_id";
const bootOf = (said: string): string | null => {
  const boot = said.trim();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(boot) ? boot : null;
};

/// Which run of a device this is: an emulator's process (its console's discovery file names its pid) and its boot, a
/// phone's boot. An emulator started from a snapshot comes back with the snapshot's boot id, so the boot alone does not
/// tell one run from the next. Null where either cannot be read: the device is then not told from another in its place.
/// Fails where adb cannot be asked at all.
export async function runOf(adb: Pick<Adb, "run">, emulator: boolean): Promise<string | null> {
  const boot = bootOf(await adb.run(["shell", BOOT]));
  if (boot === null) return null;
  if (!emulator) return boot;
  const pid = /pid_(\d+)\.ini\s*$/m.exec(await adb.run(["emu", "avd", "discoverypath"]).catch(() => ""))?.[1];
  return pid === undefined ? null : `${pid}/${boot}`;
}

/// This machine's processes, as a close ends an emulator's (tests give their own).
export interface Processes {
  /// When `pid` started (ms); none where it is not running.
  startTimeOf(pid: number): number | null;
  /// Asks `pid` to end (SIGTERM; on Windows it is ended).
  end(pid: number): void;
}
const PROCESSES: Processes = { startTimeOf: (pid) => platform.startTimeOf(pid), end: (pid) => process.kill(pid, "SIGTERM") };
/// ps says a process's start in whole seconds: a few either way is the same start (jobs/group.ts `stillOurs`).
const SAME_START_MS = 5000;
/// How long a foldable stays as it was asked after its last view that drives it ends: a person who looks away a moment
/// (another tab, Watch and Control) comes back to it as they left it.
const RESTORE_AFTER = 60_000;
const ROTATE_FOLDABLE = `wm fixed-to-user-rotation enabled; case "$(settings get system user_rotation)" in 1) n=2;; 2) n=3;; 3) n=0;; *) n=1;; esac; wm user-rotation lock $n`;

const KEY_HOME = 3, KEY_BACK = 4, KEY_VOLUME_UP = 24, KEY_VOLUME_DOWN = 25, KEY_POWER = 26, KEY_APP_SWITCH = 187;

/// A page's KeyboardEvent.code → Android's KeyEvent keycode. Escape is the device's back, as the emulator's has it.
export const KEYCODES: Record<string, number> = {
  ...Object.fromEntries([..."ABCDEFGHIJKLMNOPQRSTUVWXYZ"].map((c, i) => [`Key${c}`, 29 + i])),
  ...Object.fromEntries([..."0123456789"].map((c, i) => [`Digit${c}`, 7 + i])),
  ...Object.fromEntries(Array.from({ length: 12 }, (_, i) => [`F${i + 1}`, 131 + i])),
  Enter: 66, NumpadEnter: 66, Escape: KEY_BACK, Backspace: 67, Tab: 61, Space: 62, Minus: 69, Equal: 70, BracketLeft: 71,
  BracketRight: 72, Backslash: 73, Semicolon: 74, Quote: 75, Backquote: 68, Comma: 55, Period: 56, Slash: 76, CapsLock: 115,
  Insert: 124, Home: 122, PageUp: 92, Delete: 112, End: 123, PageDown: 93, ArrowRight: 22, ArrowLeft: 21, ArrowDown: 20,
  ArrowUp: 19, ShiftLeft: 59, ShiftRight: 60, ControlLeft: 113, ControlRight: 114, AltLeft: 57, AltRight: 58, MetaLeft: 117,
  MetaRight: 118,
};

/// A ScreenInput's `mods` (bit 0 alt, 1 ctrl, 2 meta, 3 shift) as Android's meta state, each with its left key's bit.
export function metaOf(mods: number): number {
  return ((mods & 1) !== 0 ? 0x12 : 0) | ((mods & 2) !== 0 ? 0x3000 : 0) | ((mods & 4) !== 0 ? 0x30000 : 0) | ((mods & 8) !== 0 ? 0x41 : 0);
}

const clamp = (v: number) => (Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 0);

/// A person's input (source.ts `DeviceInput`) as scrcpy's control messages: the left button held is a finger, a wheel
/// the device's scroll, a key its keycode. Simulator.app's shortcuts, which the app's device buttons send, press this
/// device's. Text goes as keys while they are ASCII, else pasted (over what its clipboard held, as an iOS Simulator's;
/// still.fail android.ts).
export class AndroidInput {
  #finger = false;

  messages(e: DeviceInput, size: { width: number; height: number }): Buffer[] {
    switch (e.t) {
      case "pointer": {
        const left = (e.buttons & 1) === 1;
        if (!this.#finger) {
          if (e.kind !== "down" || !left) return [];
          this.#finger = true;
          return [touch(TOUCH_DOWN, e.x, e.y, size)];
        }
        if (left && e.kind !== "up") return [touch(TOUCH_MOVE, e.x, e.y, size)];
        this.#finger = false;
        return [touch(TOUCH_UP, e.x, e.y, size)];
      }
      case "wheel":
        return e.dx === 0 && e.dy === 0 ? [] : [scroll(e.x, e.y, e.dx, e.dy, size)];
      case "key":
        return this.#key(e.kind === "down", e.code, e.mods);
      case "text":
        return textMessages(e.text);
      case "device":
        return e.name === "volume_up" ? press(KEY_VOLUME_UP) : e.name === "volume_down" ? press(KEY_VOLUME_DOWN) : [];
      // (a simulator's case's buttons: an Android device has no such case)
      case "pose":
      case "button":
        return [];
    }
  }

  #key(down: boolean, code: string, mods: number): Buffer[] {
    const meta = (mods & 4) !== 0, shift = (mods & 8) !== 0, ctrl = (mods & 2) !== 0, alt = (mods & 1) !== 0;
    if (meta && !alt) {
      const button = ctrl ? (shift && code === "KeyH" ? KEY_APP_SWITCH : null)
        : shift && code === "KeyH" ? KEY_HOME : !shift && code === "KeyL" ? KEY_POWER : null;
      if (button !== null) return down ? press(button) : [];
      // (its software keyboard shows by itself as a field takes the focus)
      if (!ctrl && !shift && code === "KeyK") return [];
    }
    const keycode = KEYCODES[code];
    return keycode === undefined ? [] : [key(down, keycode, metaOf(mods))];
  }
}

function key(down: boolean, keycode: number, meta: number): Buffer {
  const b = Buffer.alloc(14);
  b[0] = CONTROL_KEY;
  b[1] = down ? 0 : 1;
  b.writeInt32BE(keycode, 2);
  b.writeInt32BE(0, 6);
  b.writeInt32BE(meta, 10);
  return b;
}

const press = (keycode: number): Buffer[] => [key(true, keycode, 0), key(false, keycode, 0)];

function position(b: Buffer, at: number, x: number, y: number, size: { width: number; height: number }) {
  b.writeInt32BE(Math.min(size.width - 1, Math.round(clamp(x) * size.width)), at);
  b.writeInt32BE(Math.min(size.height - 1, Math.round(clamp(y) * size.height)), at + 4);
  b.writeUInt16BE(size.width, at + 8);
  b.writeUInt16BE(size.height, at + 10);
}

function touch(action: number, x: number, y: number, size: { width: number; height: number }): Buffer {
  const b = Buffer.alloc(32);
  b[0] = CONTROL_TOUCH;
  b[1] = action;
  b.writeBigInt64BE(FINGER, 2);
  position(b, 10, x, y, size);
  b.writeUInt16BE(action === TOUCH_UP ? 0 : 0xffff, 22);
  return b;
}

/// A notch's share of [-16, 16] as scrcpy's 16-bit fixed point. A wheel's dy down is the page's content going up: a
/// negative AXIS_VSCROLL.
function scrollAxis(pixels: number): number {
  const notches = Math.max(-SCROLL_MOST, Math.min(SCROLL_MOST, pixels / WHEEL_NOTCH));
  return Math.max(-32768, Math.min(32767, Math.round((notches / SCROLL_MOST) * 32768)));
}

function scroll(x: number, y: number, dx: number, dy: number, size: { width: number; height: number }): Buffer {
  const b = Buffer.alloc(21);
  b[0] = CONTROL_SCROLL;
  position(b, 1, x, y, size);
  b.writeInt16BE(scrollAxis(dx), 13);
  b.writeInt16BE(scrollAxis(-dy), 15);
  return b;
}

/// Text as scrcpy's INJECT_TEXT (printable ASCII, typed as keys), or else SET_CLIPBOARD with paste set: an IME's
/// Chinese, which no key types (still.fail android.ts `textMessages`).
function textMessages(text: string): Buffer[] {
  if (text === "") return [];
  const utf8 = Buffer.from(text, "utf8");
  if (utf8.length <= TEXT_MOST && /^[\x20-\x7e]*$/.test(text)) {
    const head = Buffer.alloc(5);
    head[0] = CONTROL_TEXT;
    head.writeUInt32BE(utf8.length, 1);
    return [Buffer.concat([head, utf8])];
  }
  const head = Buffer.alloc(14);
  head[0] = CONTROL_CLIPBOARD;
  head[9] = 1; // paste, after a sequence of 0 (no answer asked)
  head.writeUInt32BE(utf8.length, 10);
  return [Buffer.concat([head, utf8])];
}

/// The NAL units of an Annex B stream, without their start codes.
export function nalsOf(data: Uint8Array): Uint8Array[] {
  const out: Uint8Array[] = [];
  let start = -1;
  for (let i = 0; i + 2 < data.length; i++) {
    if (data[i] !== 0 || data[i + 1] !== 0 || data[i + 2] !== 1) continue;
    if (start >= 0) out.push(data.subarray(start, data[i - 1] === 0 ? i - 1 : i));
    start = i + 3;
    i += 2;
  }
  if (start >= 0) out.push(data.subarray(start));
  return out;
}

/// The avcC of an H.264 stream's SPS and PPS; null without both.
export function avcCOf(nals: Uint8Array[]): Uint8Array | null {
  const sps = nals.find((n) => (n[0]! & 0x1f) === 7);
  const pps = nals.find((n) => (n[0]! & 0x1f) === 8);
  // (avcC's lengths are 16 bits)
  if (sps === undefined || pps === undefined || sps.length < 4 || sps.length > 0xffff || pps.length > 0xffff) return null;
  const out = Buffer.alloc(11 + sps.length + pps.length);
  out[0] = 1;
  out[1] = sps[1]!;
  out[2] = sps[2]!;
  out[3] = sps[3]!;
  out[4] = 0xff; // lengths in 4 bytes
  out[5] = 0xe1; // one SPS
  out.writeUInt16BE(sps.length, 6);
  out.set(sps, 8);
  out[8 + sps.length] = 1; // one PPS
  out.writeUInt16BE(pps.length, 9 + sps.length);
  out.set(pps, 11 + sps.length);
  return out;
}

/// A frame's NAL units as AVCC, what its config says of itself left out.
export function avccOf(nals: Uint8Array[]): Uint8Array {
  const kept = nals.filter((n) => {
    const type = n[0]! & 0x1f;
    return type !== 7 && type !== 8;
  });
  const out = Buffer.alloc(kept.reduce((sum, n) => sum + 4 + n.length, 0));
  let at = 0;
  for (const n of kept) {
    out.writeUInt32BE(n.length, at);
    out.set(n, at + 4);
    at += 4 + n.length;
  }
  return out;
}

/// What the video socket says, as scrcpy's develop.md has it: a byte (a forward tunnel's), the device's name, the codec,
/// then for each capture a session packet and media packets (the first of each session its config).
export class ScrcpyStream {
  #carry: Buffer = Buffer.alloc(0);
  #stage = 0;
  #broken = false;
  readonly #session: (size: { width: number; height: number }) => void;
  readonly #packet: (p: { config: boolean; key: boolean; pts: bigint; data: Uint8Array }) => void;
  readonly #tooLong: () => void;

  /// `tooLong`: a packet says it is longer than PACKET_MOST: the stream is not read on.
  constructor(session: (size: { width: number; height: number }) => void, packet: (p: { config: boolean; key: boolean; pts: bigint; data: Uint8Array }) => void, tooLong: () => void) {
    this.#session = session;
    this.#packet = packet;
    this.#tooLong = tooLong;
  }

  heard(chunk: Buffer) {
    if (this.#broken) return;
    this.#carry = this.#carry.length === 0 ? chunk : Buffer.concat([this.#carry, chunk]);
    for (;;) {
      const need = [1, 64, 4, 12][this.#stage]!;
      if (this.#carry.length < need) return;
      if (this.#stage < 3) {
        this.#carry = this.#carry.subarray(need);
        this.#stage++;
        continue;
      }
      const flags = this.#carry[0]!;
      if ((flags & 0x80) !== 0) {
        this.#session({ width: this.#carry.readUInt32BE(4), height: this.#carry.readUInt32BE(8) });
        this.#carry = this.#carry.subarray(12);
        continue;
      }
      const length = this.#carry.readUInt32BE(8);
      if (length > PACKET_MOST) {
        this.#broken = true;
        this.#carry = Buffer.alloc(0);
        this.#tooLong();
        return;
      }
      if (this.#carry.length < 12 + length) return;
      this.#packet({
        config: (flags & 0x40) !== 0,
        key: (flags & 0x20) !== 0,
        pts: this.#carry.readBigUInt64BE(0) & 0x1fffffffffffffffn,
        data: new Uint8Array(this.#carry.subarray(12, 12 + length)),
      });
      this.#carry = this.#carry.subarray(12 + length);
    }
  }
}

/// The adb server's port that a person's own tools use. The source never uses it.
const PERSONS_SERVER = 5037;
/// What would have adb use another server or see other devices, not inherited: a socket or an address takes the place of
/// the port (so reaches the person's server), ADBHOST and a wider local range list another machine's adbd as an emulator,
/// ANDROID_SERIAL names a device.
const OTHER_SERVERS = new Set(["ADB_SERVER_SOCKET", "ANDROID_ADB_SERVER_ADDRESS", "ADB_SERVER_PORT", "ADBHOST", "ADB_LOCAL_TRANSPORT_MAX_PORT", "ANDROID_SERIAL", "ADB_USB"]);
const LONG_ADB = 5 * 60_000;

/// The ports a station's own adb server takes, by its data directory: two stations on a machine each have theirs. None
/// is a person's (5037), an emulator's (5554 to 5585), or a phone's lent port (mesh/adb.ts, 37000 to 38000).
export function stationAdbPort(data: string): number {
  return 15100 + createHash("sha256").update(data).digest().readUInt16BE(0) % 1000;
}

/// How adb is run here, whatever the station's environment says: on the station's own server (`port`), which does not
/// connect by itself to every phone paired with this machine's key it finds on the network (a real phone taken as a
/// test's device: 2026-11-03), and has no USB unless the computer's owner turned USB phones on (screens/devices.ts).
export const adbEnv = (port: number, usb: boolean, env: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv => {
  const rest = Object.fromEntries(Object.entries(env).filter(([name]) => !OTHER_SERVERS.has(name)));
  return { ...rest, ANDROID_ADB_SERVER_PORT: String(port), ADB_MDNS: "0", ADB_MDNS_AUTO_CONNECT: "0", ...(usb ? {} : { ADB_USB: "0" }) };
};

/// adb started: a .cmd (a shim) through what runs it, no window on Windows.
function adbSpawn(path: string, args: string[], env: NodeJS.ProcessEnv): ChildProcessWithoutNullStreams {
  const r = platform.runnable(path, args, env);
  return spawn(r.file, r.args, { windowsHide: true, windowsVerbatimArguments: r.windowsVerbatimArguments, env });
}

/// `adb` of one device: the only way a device is asked anything here, each call pinned to its serial.
export type Adb = {
  run(args: string[]): Promise<string>;
  /// As `run`, its output as bytes (a screenshot).
  bytes(args: string[]): Promise<Buffer>;
  /// As `run`, for what takes as long as a file takes (an install, a pull): no limit of its own but `LONG_ADB`.
  long(args: string[]): Promise<string>;
  shell(command: string): ChildProcess;
};

function adbOf(path: string, serial: string, env: NodeJS.ProcessEnv): Adb {
  return {
    run: (args) => adbRun(path, ["-s", serial, ...args], env),
    bytes: (args) => adbBytes(path, ["-s", serial, ...args], env),
    long: (args) => adbRun(path, ["-s", serial, ...args], env, LONG_ADB),
    shell: (command) => adbSpawn(path, ["-s", serial, "shell", command], env),
  };
}

function adbRun(path: string, args: string[], env: NodeJS.ProcessEnv, within = ADB_TIMEOUT): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = adbSpawn(path, args, env);
    let out = "", err = "";
    // (a process of its that keeps its pipes open would hold back `close`)
    const stop = wall.after(within, () => {
      child.kill("SIGKILL");
      reject(new Error("adb did not answer in time"));
    });
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("error", (e) => (stop(), reject(new Error(`adb could not be run: ${e.message}`))));
    child.on("close", (code) => {
      stop();
      if (code === 0) resolve(out);
      else reject(new Error(err.trim() || `adb ended with ${code}`));
    });
  });
}

/// What a PNG starts with.
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
/// A screenshot's PNG at most: past this it is not taken as one.
const BYTES_MOST = 32 << 20;

function adbBytes(path: string, args: string[], env: NodeJS.ProcessEnv): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const child = adbSpawn(path, args, env);
    const parts: Buffer[] = [];
    let size = 0, err = "";
    const stop = wall.after(ADB_TIMEOUT, () => {
      child.kill("SIGKILL");
      reject(new Error("adb did not answer in time"));
    });
    child.stdout.on("data", (d: Buffer) => {
      size += d.length;
      if (size > BYTES_MOST) {
        child.kill("SIGKILL");
        return;
      }
      parts.push(d);
    });
    child.stderr.on("data", (d) => (err += d));
    child.on("error", (e) => (stop(), reject(new Error(`adb could not be run: ${e.message}`))));
    child.on("close", (code) => {
      stop();
      if (size > BYTES_MOST) reject(new Error("adb said more than a screenshot"));
      else if (code === 0) resolve(Buffer.concat(parts));
      else reject(new Error(err.trim() || `adb ended with ${code}`));
    });
  });
}

function connect(port: number): Promise<net.Socket> {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, "127.0.0.1");
    socket.once("connect", () => (socket.off("error", reject), resolve(socket)));
    socket.once("error", reject);
  });
}

/// What a socket says first, the socket paused after it; null when it ends without a word, or says none `within` ms (a
/// program that accepts and then says nothing would otherwise hold the view's opening for good).
function firstOf(socket: net.Socket, within: number): Promise<Buffer | null> {
  return new Promise((resolve) => {
    const settled = (first: Buffer | null) => {
      stop();
      socket.pause();
      socket.off("data", settled);
      socket.off("close", none);
      socket.off("error", none);
      resolve(first);
    };
    const none = () => settled(null);
    const stop = wall.after(Math.max(0, within), none);
    socket.on("data", settled);
    socket.on("close", none);
    socket.on("error", none);
  });
}

type StartOptions = { maxSide: number; bitrate: number; fps?: number; wake: boolean; connectTimeout: number };

/// One view: a run of scrcpy's program on the device, with its tunnel. A still screen sends nothing.
export class AndroidView implements ScreenView {
  #stands: DeviceStands = {};
  #hears: ((stands: DeviceStands) => void) | null = null;
  readonly #poses: DevicePoses;
  readonly #adb: Adb;
  readonly #gone: () => void;
  /// Told when what it is asked turns or folds the device, before it does.
  readonly #moved: () => Promise<void>;
  readonly #sized: (size: { width: number; height: number }) => void;
  readonly #input = new AndroidInput();
  #server: ChildProcess | null = null;
  #video: net.Socket | null = null;
  #control: net.Socket | null = null;
  #port = 0;
  #ended = false;
  #size = { width: 0, height: 0 };
  /// The config to go with the next frame, and whether the queue is dropped up to the next key frame.
  #config: FrameConfig | undefined;
  #dropping = false;
  #lastTs = 0;
  readonly #queue: Frame[] = [];
  readonly #waiting: ((frame: Frame | null) => void)[] = [];

  constructor(adb: Adb, gone: () => void, sized: (size: { width: number; height: number }) => void, poses: DevicePoses = new Map(), moved: () => Promise<void> = async () => {}) {
    this.#moved = moved;
    this.#poses = poses;
    this.#adb = adb;
    this.#gone = gone;
    this.#sized = sized;
  }

  /// Puts the program on the device, runs it and connects (its file taken off again once it runs).
  async start(file: string, options: StartOptions) {
    const scid = randomInt(1, 0x7fffffff).toString(16).padStart(8, "0");
    const jar = `/data/local/tmp/stillfail-scrcpy-${scid}.jar`;
    const name = `localabstract:scrcpy_${scid}`;
    try {
      await this.#adb.run(["push", file, jar]);
      if (this.#ended) throw new Error("the view was closed");
      await this.#run(jar, scid, name, options);
    } finally {
      // (whether it opened or not, a push cut off too)
      void this.#adb.run(["shell", `rm -f ${jar}`]).catch(() => {});
    }
  }

  async #run(jar: string, scid: string, name: string, options: StartOptions) {
    const port = Number((await this.#adb.run(["forward", "tcp:0", name])).trim());
    if (!Number.isInteger(port) || port <= 0) throw new Error("adb gave no port for the view");
    this.#port = port;
    if (this.#ended) {
      this.#removeForward();
      throw new Error("the view was closed");
    }
    const args = [
      `scid=${scid}`, "log_level=warn", "audio=false", "control=true", "tunnel_forward=true", "cleanup=false", "video_codec=h264",
      `max_size=${options.maxSide}`, `video_bit_rate=${options.bitrate}`, `max_fps=${options.fps ?? 60}`, `power_on=${options.wake}`,
    ];
    const server = this.#adb.shell(`CLASSPATH=${jar} app_process / com.genymobile.scrcpy.Server ${SERVER_VERSION} ${args.join(" ")}`);
    this.#server = server;
    let said = "";
    server.stdout?.on("data", (d) => (said += d));
    server.stderr?.on("data", (d) => (said += d));
    server.on("error", (error) => {
      said += error.message;
      this.close();
    });
    server.on("close", () => {
      if (!this.#ended) log.warn("screens", "an Android view's program ended", { said: said.slice(0, 500) });
      this.close();
    });
    // (a forward tunnel takes a connection before anything listens: the byte the program sends first says it does)
    const until = wall.now() + options.connectTimeout;
    while (this.#video === null) {
      if (this.#ended) throw new Error(said.trim() || "the view's program ended");
      if (wall.now() > until) throw new Error(said.trim() || "the view's program did not start");
      const socket = await connect(this.#port).catch(() => null);
      const first = socket === null ? null : await firstOf(socket, until - wall.now());
      if (socket === null || first === null) {
        socket?.destroy();
        await wall.sleep(100);
        continue;
      }
      this.#video = socket;
      const stream = new ScrcpyStream((size) => this.#session(size), (p) => this.#packet(p), () => {
        log.warn("screens", "an Android view's program sent no stream");
        this.close();
      });
      socket.on("data", (d: Buffer) => stream.heard(d));
      socket.on("error", () => this.close());
      socket.on("close", () => this.close());
      stream.heard(first);
      socket.resume();
    }
    const control = await connect(this.#port);
    if (this.#ended) {
      control.destroy();
      throw new Error(said.trim() || "the view's program ended");
    }
    // (what it answers, a clipboard's change, nobody here asks)
    control.on("data", () => {});
    control.on("error", () => this.close());
    this.#control = control;
  }

  #session(size: { width: number; height: number }) {
    this.#size = size;
    this.#sized(size);
    void this.#look();
  }

  #packet(p: { config: boolean; key: boolean; pts: bigint; data: Uint8Array }) {
    const nals = nalsOf(p.data);
    if (p.config) {
      const description = avcCOf(nals);
      if (description !== null) this.#config = { codec: "h264", ...this.#size, description };
      return;
    }
    if (this.#dropping && !p.key) return;
    this.#dropping = false;
    // Rising, whatever a new capture's clock starts from.
    const ts = Math.max(this.#lastTs + 1, Number(p.pts));
    this.#lastTs = ts;
    const frame: Frame = { key: p.key, ts, data: avccOf(nals), ...(p.key && this.#config ? { config: this.#config } : {}) };
    if (p.key) this.#config = undefined;
    const waiting = this.#waiting.shift();
    if (waiting) {
      waiting(frame);
      return;
    }
    this.#queue.push(frame);
    if (this.#queue.length > QUEUE_MOST) {
      // (the new capture says its config again)
      this.#queue.length = 0;
      this.#dropping = true;
      this.keyframe();
    }
  }

  next(): Promise<Frame | null> {
    if (this.#ended) return Promise.resolve(null);
    const frame = this.#queue.shift();
    if (frame) return Promise.resolve(frame);
    return new Promise((resolve) => this.#waiting.push(resolve));
  }

  keyframe() {
    this.#control?.write(Buffer.from([CONTROL_RESET]));
  }

  /// scrcpy names no encoder to its client (still.fail's AndroidView says the same).
  video(): ScreenVideo {
    return { capture: "scrcpy" };
  }

  /// Says how the device stands whenever that changes, until the returned function.
  watchDevice(heard: (stands: DeviceStands) => void): () => void {
    this.#hears = heard;
    void this.#look();
    return () => {
      this.#hears = null;
    };
  }

  /// Asked as a capture starts (turned, folded) and after what turns or folds it. A failed look says nothing.
  async #look() {
    if (this.#hears === null || this.#ended) return;
    const said = await this.#adb.run(["shell", DEVICE_STANDS]).catch(() => "");
    const stands = standsOf(said, this.#poses);
    if (this.#hears !== null && !this.#ended && (stands.orientation !== this.#stands.orientation || stands.pose !== this.#stands.pose)) {
      this.#stands = stands;
      this.#hears(stands);
    }
  }

  async input(raw: ScreenInput) {
    // (mesh/screens.ts `deviceInput` made it)
    const event = raw as DeviceInput;
    // A foldable's hinge: only a state the device itself listed, by its own number.
    if (event.t === "pose") {
      const state = this.#poses.get(event.name);
      if (state !== undefined) {
        await this.#moved();
        await this.#adb.run(["shell", `cmd device_state state ${state}`]).catch(() => {});
        await this.#look();
      }
      return;
    }
    // Turned by the window manager, the picture's new shape following from scrcpy (its own ROTATE_DEVICE does nothing on an
    // Android 16 emulator).
    if (event.t === "device" && event.name === "rotate") {
      if (this.#poses.size > 0) await this.#moved();
      await this.#adb.run(["shell", this.#poses.size > 0 ? ROTATE_FOLDABLE : ROTATE]).catch(() => {});
      await this.#look();
      return;
    }
    if (this.#size.width === 0) return;
    for (const message of this.#input.messages(event, this.#size)) this.#control?.write(message);
  }

  close() {
    if (this.#ended) return;
    this.#ended = true;
    this.#video?.destroy();
    this.#control?.destroy();
    this.#server?.kill();
    if (this.#port > 0) this.#removeForward();
    for (const waiting of this.#waiting.splice(0)) waiting(null);
    this.#gone();
  }

  #removeForward() {
    void this.#adb.run(["forward", "--remove", `tcp:${this.#port}`]).catch(() => {});
  }
}

/// The side a view asks scrcpy for: the longer of its bounds, which a client gives as its picture shows (a client from
/// before them gets the route's own). Larger, the client's page scales it down and its small text goes soft.
export function sideOf(options: ViewOptions): number {
  // (a multiple of 8, as encoders take)
  return Math.min(MOST_SIDE, Math.max(options.maxWidth, options.maxHeight)) & ~7;
}

/// A foldable's poses, each with the number of the device's own state; empty: it does not fold.
export type DevicePoses = ReadonlyMap<DevicePose, number>;

/// Which way it stands and which state it is in.
const DEVICE_STANDS = "dumpsys window displays | grep -m1 mCurrentRotation; cmd device_state state";

/// The poses among what `cmd device_state print-states` lists. A device with no closed and open state does not fold:
/// its one state is `DEFAULT`.
export function posesOf(printed: string): DevicePoses {
  const out = new Map<DevicePose, number>();
  for (const [, id, name] of printed.matchAll(/DeviceState\{identifier=(\d+), name='([^']*)'/g)) {
    const pose = /^(CLOSE|FOLD)/i.test(name!) ? "closed" : /HALF|TENT|BOOK/i.test(name!) ? "book" : /^(OPEN|UNFOLD)/i.test(name!) ? "open" : null;
    if (pose !== null && !out.has(pose)) out.set(pose, Number(id));
  }
  return out.has("closed") && out.has("open") ? out : new Map();
}

/// What `DEVICE_STANDS` says, as far as it says.
export function standsOf(said: string, poses: DevicePoses): DeviceStands {
  const rotation = /mCurrentRotation=ROTATION_(0|90|180|270)/.exec(said)?.[1];
  const state = /Committed state: DeviceState\{identifier=(\d+)/.exec(said)?.[1];
  const pose = state === undefined ? undefined : [...poses].find(([, id]) => id === Number(state))?.[0];
  return { ...(rotation === undefined ? {} : { orientation: Number(rotation) as 0 | 90 | 180 | 270 }), ...(pose === undefined ? {} : { pose }) };
}

/// One device on adb.
export class AndroidScreen implements ScreenSource {
  readonly id: string;
  readonly kind = "android" as const;
  /// A preview opens as any view does, without turning its screen on.
  readonly peek = true;
  readonly panels: Panel[];
  /// What it is on this machine: an AVD's name, or a phone's.
  readonly name: string;
  /// A real phone (any device not named as an emulator): a person's, with their data on it.
  readonly phone: boolean;
  /// What adb calls it (its USB serial, `host:port`, `emulator-<port>`): what its owner chose it by.
  readonly serial: string;
  /// An agent's lease on it (screens/android-agent.ts): shown with it in the list, and told to those who look at it
  /// (`watchAgent`).
  readonly #agent = new AgentPresence();
  /// The views that drive it: an agent's input waits while a person has one.
  #held = 0;
  /// This boot of it (source.ts `instance`); none where its boot could not be told, which is then only looked at.
  readonly instance?: string;
  /// Which run it is (runOf).
  readonly #boot: string | null;
  readonly #emulator: boolean;
  /// Told when it is found to be another device in its place: its listing is looked at anew.
  readonly #replaced: () => void;
  readonly #poseStates: DevicePoses;
  /// An emulator is closed for good: its process is ended (below). A phone has none of this, and nothing here turns one off.
  readonly discard?: () => Promise<void>;
  /// Its running app's logs, `adb -s <serial> logcat` while someone reads them (app-logs.ts).
  readonly logs: AppLogs;
  /// What debugs an app on an emulator (android-debug.ts); a phone has none: what is on it is a person's own.
  readonly debug?: DeviceDebug;
  readonly #title: string;
  readonly #adb: Adb;
  readonly #file: () => string | null;
  readonly #connectTimeout: number;
  readonly #changed: () => void;
  readonly #views = new Set<AndroidView>();
  /// Those that drive it: what a foldable is asked lasts while one is open (RESTORE_AFTER).
  readonly #driving = new Set<AndroidView>();
  /// A foldable was turned or folded from here, and is not yet put back: what puts it back (restoreOf).
  #moved: string | null = null;
  /// It left adb, or the station stops: nothing more is put back on its own.
  #ended = false;
  #restoreSoon: (() => void) | null = null;
  readonly #restoreAfter: number;
  #size: { width: number; height: number };

  constructor(o: { id: string; serial?: string; name: string; boot: string | null; replaced?: () => void; title: string; size: { width: number; height: number }; panels: Panel[]; poses?: DevicePoses; adb: Adb; file: () => string | null; sdk?: number; connectTimeout?: number; restoreAfter?: number; changed: () => void; processes?: Processes }) {
    this.id = o.id;
    this.panels = o.panels;
    this.name = o.name;
    this.#boot = o.boot;
    this.#emulator = o.id.startsWith("android:emulator-");
    this.phone = !this.#emulator;
    this.serial = o.serial ?? o.id.slice("android:".length);
    if (o.boot !== null) this.instance = createHash("sha256").update(`${o.name}\n${o.boot}`).digest("hex").slice(0, 16);
    this.#replaced = o.replaced ?? (() => {});
    this.#poseStates = o.poses ?? new Map();
    this.#title = o.title;
    this.#size = o.size;
    this.#adb = o.adb;
    this.logs = androidLogs({ logcat: (args, line, ended) => childLines(o.adb.shell(args.join(" ")), line, ended), run: (args) => o.adb.run(args) });
    if (this.#emulator) this.debug = new AndroidDebug(o.adb, o.sdk ?? 0);
    this.#file = o.file;
    this.#connectTimeout = o.connectTimeout ?? CONNECT_TIMEOUT;
    this.#changed = o.changed;
    this.#restoreAfter = o.restoreAfter ?? RESTORE_AFTER;
    // An emulator is closed by its process, not by its serial: between the check that it is still the one listed and
    // `adb -s <serial> emu kill`, it can end and another start at its port, and that one would be closed. Its pid
    // (runOf) and that process's start, read as it is listed, are checked again just before it is ended (pids are
    // reused). One whose pid or start could not be read is not closed from here.
    const processes = o.processes ?? PROCESSES;
    const pid = this.#emulator && o.boot !== null ? Number(/^(\d+)\//.exec(o.boot)?.[1] ?? NaN) : NaN;
    const started = Number.isInteger(pid) ? processes.startTimeOf(pid) : null;
    if (started !== null)
      this.discard = async () => {
        if (!(await this.current())) throw new ScreenRefused(409, "station.screen.failed", { said: REPLACED });
        // (put back whoever still has it open: it closes for good)
        await this.restore(true);
        const now = processes.startTimeOf(pid);
        if (now === null || Math.abs(now - started) >= SAME_START_MS) {
          this.#replaced();
          throw new ScreenRefused(409, "station.screen.failed", { said: REPLACED });
        }
        processes.end(pid);
      };
  }

  title(): string {
    return this.#title;
  }

  size(): { width: number; height: number } {
    return this.#size;
  }

  /// The poses its input takes.
  poseNames(): DevicePose[] {
    return [...this.#poseStates.keys()];
  }

  async open(options: ViewOptions): Promise<ScreenView> {
    if (!options.codecs.includes("h264")) throw new ScreenRefused(415, "station.screen.codec", { codec: "H.264" });
    const file = this.#file();
    if (file === null) throw new ScreenRefused(503, "station.screen.noScrcpy");
    // Still the device listed: its port may be another's by now, with no offline between for adb to say.
    const same = await this.current().catch((error: Error) => {
      throw new ScreenRefused(503, "station.screen.failed", { said: error.message });
    });
    if (!same) throw new ScreenRefused(409, "station.screen.failed", { said: REPLACED });
    const view: AndroidView = new AndroidView(this.#adb, () => this.#left(view), (size) => {
      // Turned or unfolded: its shape as the listing has it.
      if (Math.abs(size.width / size.height - this.#size.width / this.#size.height) < SAME_SHAPE) return;
      this.#size = size;
      this.#changed();
    }, this.#poseStates, () => this.#move());
    this.#views.add(view);
    if (!options.peek) {
      this.#driving.add(view);
      this.#restoreSoon?.();
      this.#restoreSoon = null;
    }
    try {
      await view.start(file, {
        maxSide: sideOf(options),
        bitrate: options.peek ? PEEK_BITRATE : bitrateOf(sideOf(options)),
        ...(options.peek ? { fps: PEEK_FPS } : {}),
        wake: options.peek !== true,
        connectTimeout: this.#connectTimeout,
      });
      return view;
    } catch (error) {
      view.close();
      log.warn("screens", "an Android view did not open", { id: this.id, error: (error as Error).message });
      throw new ScreenRefused(503, "station.screen.failed", { said: (error as Error).message });
    }
  }

  /// A person's view that drives it opened: an agent's input waits until every such view is gone (the function given).
  hold(): () => void {
    this.#held++;
    let held = true;
    return () => {
      if (held) this.#held--;
      held = false;
    };
  }

  /// Whether a person drives it now.
  held(): boolean {
    return this.#held > 0;
  }

  /// What an agent's lease on it says while it lasts; set as one starts or ends, and those who look at it are told.
  get agent(): string | null {
    return this.#agent.lease;
  }

  set agent(next: string | null) {
    this.#agent.lease = next;
  }

  /// A person's view hears an agent's lease on it start and end, and where the agent's finger is (`ScreenSource.watchAgent`).
  watchAgent(heard: (said: AgentSaid) => void): () => void {
    return this.#agent.watch(heard);
  }

  /// Where the agent's finger is now (0..1 of the picture): shown to those who look.
  agentPoints(at: { x: number; y: number }, down: boolean) {
    this.#agent.points(at, down);
  }

  /// One fixed shell command of an agent's lease (screens/android-agent.ts builds them, its arguments checked there),
  /// pinned to its serial. Refused once it left adb.
  agentShell(command: string): Promise<string> {
    if (this.#ended) return Promise.reject(new Error(REPLACED));
    return this.#adb.run(["shell", command]);
  }

  /// Its screen as a PNG (`screencap -p`), at its own size. It does not turn the screen on.
  agentScreenshot(): Promise<Buffer> {
    if (this.#ended) return Promise.reject(new Error(REPLACED));
    // (a device with several displays says which it took before the picture: what comes before its PNG is left out)
    return this.#adb.bytes(["exec-out", "screencap", "-p"]).then((said) => {
      const at = said.indexOf(PNG_SIGNATURE);
      return at > 0 ? said.subarray(at) : said;
    });
  }

  /// Whether it is the device it was listed as: its boot read again. Found another, its listing is looked at anew.
  /// Fails as adb does where it cannot be asked.
  async current(): Promise<boolean> {
    if (this.#boot === null || this.#ended) return false;
    const now = await runOf(this.#adb, this.#emulator);
    if (now === this.#boot) return true;
    this.#replaced();
    return false;
  }

  /// Before the first turn or fold from here: what its display was, for putting it back.
  async #move() {
    if (this.#moved !== null) return;
    this.#moved = restoreOf(await this.#adb.run(["shell", FOUND]).catch(() => ""));
  }

  #left(view: AndroidView) {
    this.#views.delete(view);
    if (this.#ended || !this.#driving.delete(view) || this.#driving.size > 0 || this.#moved === null) return;
    this.#restoreSoon?.();
    this.#restoreSoon = wall.after(this.#restoreAfter, () => {
      this.#restoreSoon = null;
      void this.restore();
    });
  }

  /// A foldable turned or folded from here put back as it was found (RESTORE_FOLDABLE), once nobody drives it.
  /// Only on the boot it was turned on: another device in its place is not touched.
  /// Accepted race: the put-back, like a view's rotate, pose and keys, goes by serial (`adb -s <serial> shell`), so an
  /// emulator that ends and another started at its port between the check and the call gets it. Only an emulator on
  /// the owner's own machine restarted within that gap is hit, and the worst is a wrong rotation or pose. A close does
  /// not go by serial (discard).
  async restore(closing = false): Promise<void> {
    this.#restoreSoon?.();
    this.#restoreSoon = null;
    const put = this.#moved;
    if (put === null || (this.#driving.size > 0 && !closing)) return;
    this.#moved = null;
    const run = await runOf(this.#adb, this.#emulator).catch(() => null);
    if (run === null || run !== this.#boot) return;
    await this.#adb.run(["shell", put]).catch((error) => log.info("screens", "a foldable was not put back", { id: this.id, error: (error as Error).message }));
  }

  /// It left adb: its views end, and nothing is done to it any more (what is at its place may be another).
  gone() {
    this.#ended = true;
    this.#restoreSoon?.();
    this.#restoreSoon = null;
    this.#moved = null;
    for (const view of [...this.#views]) view.close();
    this.logs.close();
    this.debug?.close();
  }

  /// The station stops while it is still there: its views end, and it is put back now.
  stop(): Promise<void> {
    this.#ended = true;
    this.#restoreSoon?.();
    this.#restoreSoon = null;
    for (const view of [...this.#views]) view.close();
    this.logs.close();
    this.debug?.close();
    this.#driving.clear();
    const put = this.#moved;
    this.#moved = null;
    if (put === null) return Promise.resolve();
    return (async () => {
      const run = await runOf(this.#adb, this.#emulator).catch(() => null);
      if (run !== null && run === this.#boot) await this.#adb.run(["shell", put]).catch(() => {});
    })();
  }
}

/// Whether a device on adb is a screen: an emulator, or a phone whose exact serial was asked for. Anything else is not
/// asked a thing, not even its properties: a person's phone can be on adb unannounced. Never one adb found on the
/// network by itself (`adb-<serial>._adb-tls-connect._tcp`: any phone paired with this key that is on the same network),
/// nor one lent through a member link (mesh/adb.ts, at 127.0.0.1:<port>).
export function shownDevice(serial: string, phones: readonly string[] = []): boolean {
  if (serial.includes("._adb") || serial.startsWith("127.0.0.1:")) return false;
  return /^emulator-\d+$/.test(serial) || phones.includes(serial);
}

/// Whether a device on adb is a phone its owner may choose (`phonesOn`): any that is not an emulator's name, nor what
/// `shownDevice` never shows.
export function phoneCandidate(serial: string): boolean {
  return serial !== "" && !serial.includes("._adb") && !serial.startsWith("127.0.0.1:") && !/^emulator-/.test(serial) && !/^(localhost|\[?::1\]?)[:]/.test(serial);
}

/// A phone on the station's adb as its server says it (`track-devices -l`), before anything asks the phone itself.
export type PhoneOnAdb = { serial: string; state: string; model: string | null; transport: "usb" | "wifi" };

/// What `adb track-devices -l` says each time, every line: `serial state usb:… product:… model:… device:…`.
export function transportsOf(lines: string): PhoneOnAdb[] {
  return lines.split("\n").flatMap((line) => {
    const [serial, state, ...rest] = line.trim().split(/\s+/);
    if (!serial || !state) return [];
    const model = rest.find((word) => word.startsWith("model:"))?.slice(6).replaceAll("_", " ") || null;
    return [{ serial, state, model, transport: /^[^:]+:\d+$|^\[[0-9a-fA-F:]+\]:\d+$/.test(serial) ? "wifi" : "usb" }];
  });
}

/// An address a person gives to connect a phone over Wi-Fi (`adb connect`): `host:port`, never this machine (a lent
/// phone's port, an emulator's adbd) nor a name adb found by itself. Null when it is not one.
export function wirelessAddress(said: string): string | null {
  const m = /^([A-Za-z0-9.-]{1,253}|\[[0-9a-fA-F:]{2,39}\]):(\d{1,5})$/.exec(said.trim());
  if (!m) return null;
  const host = m[1]!.toLowerCase();
  const port = Number(m[2]);
  if (port < 1 || port > 65535) return null;
  if (host === "localhost" || host.startsWith("127.") || host === "0.0.0.0" || host === "[::1]" || host === "[::]" || host.includes("._adb")) return null;
  return `${host}:${port}`;
}

/// What `adb track-devices -l` says each time: `<four hex digits of length><lines>`, each line `serial state …`. The
/// devices ready to use.
export function devicesOf(lines: string): string[] {
  return lines.split("\n").flatMap((line) => {
    const [serial, state] = line.trim().split(/\s+/);
    return serial && state === "device" ? [serial] : [];
  });
}

/// The panels of `dumpsys display`: each display's size and its corners' radii as shares of its width, top left and
/// then round it; 0 where it has none (a foldable's panels are told apart by their sizes, whatever their corners).
export function panelsOf(dumpsys: string): Panel[] {
  const out = new Map<string, Panel>();
  for (const line of dumpsys.split("\n")) {
    // Android 16 says a panel's corners of its `DisplayDeviceInfo`, and its `mBaseDisplayInfo` says none.
    const real = line.includes("mBaseDisplayInfo=") ? /\breal (\d+) x (\d+)/.exec(line) : line.includes("DisplayDeviceInfo{") ? /", ?uniqueId=[^,]*, (\d+) x (\d+)|: uniqueId=[^,]*, (\d+) x (\d+)/.exec(line) : null;
    const rounded = /roundedCorners RoundedCorners\{\[(.*?)\]\}/.exec(line);
    if (!real) continue;
    const [width, height] = [Number(real[1] ?? real[3]), Number(real[2] ?? real[4])];
    const radius = (position: string) => Number(new RegExp(`position=${position}, radius=(\\d+)`).exec(rounded?.[1] ?? "")?.[1] ?? 0) / width;
    const corners: Panel["corners"] = [radius("TopLeft"), radius("TopRight"), radius("BottomRight"), radius("BottomLeft")];
    const key = `${width}x${height}`;
    // (one line of a panel says its corners, another may not)
    if (width > 0 && (corners.some((c) => c > 0) || !out.has(key))) out.set(key, { width, height, corners });
  }
  return [...out.values()];
}

/// `wm size`'s answer: the size overriding the physical one where there is one.
export function sizeOf(wm: string): { width: number; height: number } {
  const of = (word: string) => new RegExp(`${word} size: (\\d+)x(\\d+)`).exec(wm);
  const m = of("Override") ?? of("Physical");
  return m ? { width: Number(m[1]), height: Number(m[2]) } : { width: 0, height: 0 };
}

/// The emulators on the station's adb server (and the phones its owner chose), each a screen while it is on it. A
/// machine without adb lists none and says so (`unavailable`).
export class AndroidScreens {
  readonly #screens: Screens & { changed(): void };
  readonly #adb: () => string | null;
  readonly #file: () => string | null;
  #phones: readonly string[];
  #usb: boolean;
  #env: NodeJS.ProcessEnv;
  readonly #serverPort: number;
  /// Every device the server said it has, as it said it last.
  #transports: PhoneOnAdb[] = [];
  readonly #connectTimeout: number | undefined;
  readonly #restoreAfter: number | undefined;
  readonly #processes: Processes | undefined;
  #unavailable: string | null = null;
  readonly #listed = new Map<string, { id: string; source: AndroidScreen; remove: () => void }>();
  #follow: ChildProcess | null = null;
  #again: (() => void) | null = null;
  #closed = false;
  #serials: string[] = [];
  #looking = Promise.resolve();
  #lookAgain: (() => void) | null = null;
  readonly #again_ms: number;
  /// When following stops, nothing listed (`FOLLOWED_FOR` after the screens were last asked for).
  #rest: (() => void) | null = null;
  #started = false;
  #heardOnce = false;
  /// What a stopping station still puts back on its devices.
  readonly #leaving: Promise<void>[] = [];
  readonly #firstHeard: (() => void)[] = [];

  /// `serverPort`: the adb server of the station's own (not a person's 5037), which has no default so that none is taken
  /// by accident. `phones`: the exact serials of phones a person asked to see; none: emulators alone. `usb`: whether the
  /// server takes USB devices (default: with a phone asked for).
  constructor(o: { screens: Screens & { changed(): void }; adb: () => string | null; serverPort: number; phones?: readonly string[]; usb?: boolean; file?: string; lookAgain?: number; connectTimeout?: number; restoreAfter?: number; processes?: Processes }) {
    if (!Number.isInteger(o.serverPort) || o.serverPort <= 0 || o.serverPort > 65535 || o.serverPort === PERSONS_SERVER) throw new Error(`not an adb server of the station's own: ${o.serverPort}`);
    this.#screens = o.screens;
    this.#adb = o.adb;
    this.#again_ms = o.lookAgain ?? LOOK_AGAIN;
    this.#phones = o.phones ?? [];
    this.#usb = o.usb ?? this.#phones.length > 0;
    this.#serverPort = o.serverPort;
    this.#env = adbEnv(o.serverPort, this.#usb);
    this.#connectTimeout = o.connectTimeout;
    this.#restoreAfter = o.restoreAfter;
    this.#processes = o.processes;
    this.#file = () => [o.file, process.env.STILLFAIL_SCRCPY_SERVER, fileURLToPath(new URL("./scrcpy-server", import.meta.url))].find((p) => p && existsSync(p)) ?? null;
  }

  /// Why no device can be listed now (no adb to run), in the station's language; null when adb runs.
  unavailable(): string | null {
    return this.#unavailable;
  }

  start() {
    if (this.#closed || this.#follow !== null) return;
    const path = this.#adb();
    this.#unavailable = path === null ? tr(stationLang(), "station.adb.noAdb") : null;
    if (path === null) return;
    this.#started = true;
    // (a call of adb that names no device: it asks the server, not a device)
    const child = adbSpawn(path, ["track-devices", "-l"], this.#env);
    this.#follow = child;
    let carry = "";
    child.stdout.on("data", (d) => {
      carry += d;
      for (;;) {
        const length = parseInt(carry.slice(0, 4), 16);
        if (!Number.isInteger(length) || carry.length < 4 + length) return;
        const said = carry.slice(4, 4 + length);
        this.#transports = transportsOf(said);
        this.#heard(path, devicesOf(said));
        carry = carry.slice(4 + length);
      }
    });
    child.on("error", () => {
      this.#unavailable = tr(stationLang(), "station.adb.noAdb");
      this.#screens.changed();
    });
    child.on("close", () => {
      // (one let go of: `refresh` may have followed anew since)
      if (this.#follow !== child) return;
      this.#follow = null;
      if (this.#closed) return;
      this.#again?.();
      this.#again = wall.after(FOLLOW_AGAIN, () => this.start());
    });
  }

  /// As the screens are asked for: adb may have come since (one put on the machine, its follow ended).
  async refresh(): Promise<void> {
    this.start();
    this.#rest?.();
    this.#rest = wall.after(FOLLOWED_FOR, () => this.#stopFollowing());
    // adb says what it has only after it has started: until then a running emulator would read as one to start. Not for
    // long: a listing is a person waiting.
    if (!this.#heardOnce && this.#follow !== null)
      await new Promise<void>((resolve) => {
        const stop = wall.after(FIRST_ANSWER_MS, resolve);
        this.#firstHeard.push(() => (stop(), resolve()));
      });
    await this.#looking;
  }

  /// Not asked for in a while: adb's devices let go of while none is listed (asked for again: followed again).
  #stopFollowing() {
    this.#rest = null;
    if (this.#closed) return;
    if (this.#listed.size > 0) {
      this.#rest = wall.after(FOLLOWED_FOR, () => this.#stopFollowing());
      return;
    }
    this.#again?.();
    this.#again = null;
    this.#lookAgain?.();
    this.#lookAgain = null;
    this.#follow?.kill();
    this.#follow = null;
  }

  #heard(path: string, serials: string[]) {
    this.#serials = serials;
    this.#looking = this.#looking.then(() => this.#look(path)).catch((error) => log.warn("screens", "looking at adb's devices failed", { error: (error as Error).message }));
    this.#heardOnce = true;
    for (const resolve of this.#firstHeard.splice(0)) resolve();
  }

  async #look(path: string) {
    const serials = this.#serials.filter((serial) => shownDevice(serial, this.#phones));
    for (const [serial, listed] of [...this.#listed]) {
      if (serials.includes(serial)) continue;
      this.#listed.delete(serial);
      listed.remove();
      listed.source.gone();
    }
    let unseen = false;
    // Still there by name: still the same boot? (an emulator closed and another started at its port within adb's look)
    for (const [serial, listed] of [...this.#listed]) if (serials.includes(serial)) await listed.source.current().catch(() => {});
    for (const serial of serials) {
      if (this.#closed || this.#listed.has(serial)) continue;
      // (a phone both on USB and over Wi-Fi: the one screen)
      const source = await this.#screen(path, serial).catch((error) => {
        unseen = true;
        log.info("screens", "an Android device could not be looked at yet", { serial, error: (error as Error).message });
        return null;
      });
      if (source === null || [...this.#listed.values()].some((l) => l.id === source.id)) continue;
      if (this.#closed || !this.#serials.includes(serial)) continue;
      this.#listed.set(serial, { id: source.id, source, remove: this.#screens.add(source) });
    }
    this.#lookAgain?.();
    this.#lookAgain = unseen && !this.#closed && this.#follow !== null ? wall.after(this.#again_ms, () => this.#heard(path, this.#serials)) : null;
  }

  /// Another device at `serial`'s place: what was listed goes, and it is looked at anew.
  #replace(serial: string) {
    const listed = this.#listed.get(serial);
    const path = this.#adb();
    if (!listed || path === null) return;
    this.#listed.delete(serial);
    listed.remove();
    listed.source.gone();
    this.#heard(path, this.#serials);
  }

  /// The device's source; null when it says it is an emulator and is not one.
  async #screen(path: string, serial: string): Promise<AndroidScreen | null> {
    const adb = adbOf(path, serial, this.#env);
    // (what is asked below is not there until it has booted)
    if ((await adb.run(["shell", "getprop sys.boot_completed"])).trim() !== "1") throw new Error("still booting");
    const emulator = serial.startsWith("emulator-");
    // adb gives this name to any adbd on a local port or at ADBHOST, a phone's too: the name is not enough.
    if (emulator && !(await adb.run(["shell", "getprop ro.kernel.qemu; getprop ro.boot.qemu"])).split("\n").some((l) => l.trim() === "1")) {
      log.warn("screens", "a device named as an emulator is not one, and is not shown", { serial });
      return null;
    }
    const props = await adb.run(["shell", "getprop ro.serialno; getprop ro.product.model; getprop ro.build.version.release; settings get global device_name"]);
    const [serialno, model, release, named] = props.split("\n").map((l) => l.trim());
    const avd = emulator ? (await adb.run(["emu", "avd", "name"]).catch(() => "")).split("\n")[0]!.trim() : "";
    const name = avd || (named && named !== "null" ? named : model) || serial;
    // (emulators all have one ro.serialno, a phone keeps its own however it is connected)
    const id = `android:${emulator || !serialno ? serial : serialno}`;
    // A boot of its own: the kernel's, new each time it starts. Without one it is not told from another in its place.
    const boot = await runOf(adb, emulator).catch(() => null);
    return new AndroidScreen({
      id,
      serial,
      name,
      boot,
      replaced: () => this.#replace(serial),
      title: `${name} · Android ${release}`,
      size: sizeOf(await adb.run(["shell", "wm size"])),
      panels: panelsOf(await adb.run(["shell", "dumpsys display"]).catch(() => "")),
      poses: posesOf(await adb.run(["shell", "cmd device_state print-states"]).catch(() => "")),
      adb,
      file: this.#file,
      ...(emulator ? { sdk: Number((await adb.run(["shell", "getprop ro.build.version.sdk"]).catch(() => "")).trim()) || 0 } : {}),
      ...(this.#connectTimeout === undefined ? {} : { connectTimeout: this.#connectTimeout }),
      ...(this.#restoreAfter === undefined ? {} : { restoreAfter: this.#restoreAfter }),
      ...(this.#processes === undefined ? {} : { processes: this.#processes }),
      changed: () => this.#screens.changed(),
    });
  }

  /// The phones on the station's adb server now, each as the server says it (none asked anything), chosen or not.
  phonesOn(): PhoneOnAdb[] {
    return this.#transports.filter((t) => phoneCandidate(t.serial));
  }

  /// Whether the server takes USB devices now.
  usb(): boolean {
    return this.#usb;
  }

  /// The phones its owner chose, and whether the server takes USB: a change of USB starts the server again (it reads
  /// ADB_USB as it starts), and its emulators come back to it by themselves.
  async choose(o: { usb: boolean; phones: readonly string[] }): Promise<void> {
    const restart = o.usb !== this.#usb;
    this.#phones = [...o.phones];
    this.#usb = o.usb;
    if (restart) {
      const before = this.#env;
      this.#env = adbEnv(this.#serverPort, this.#usb);
      const path = this.#adb();
      if (this.#started && path !== null) {
        const follow = this.#follow;
        this.#follow = null;
        follow?.kill();
        this.#transports = [];
        await adbRun(path, ["kill-server"], before).catch(() => {});
        if (!this.#closed) this.start();
      }
    }
    const path = this.#adb();
    if (path !== null && this.#heardOnce) this.#heard(path, this.#serials);
    await this.#looking;
  }

  /// `adb connect <address>` on the station's own server, at its owner's word (the address checked: wirelessAddress).
  /// What adb said. The one other call besides the server's own that names no device of the list: it names the address.
  async connect(address: string): Promise<string> {
    const checked = wirelessAddress(address);
    if (checked === null) throw new Error("not an address of a phone on the network (host:port)");
    const path = this.#adb();
    if (path === null) throw new Error(tr(stationLang(), "station.adb.noAdb"));
    // (the server up first: `connect` would otherwise start one of its own beside the one `track-devices` starts, and
    // the second fails on the port, seen on a Mac)
    await this.refresh();
    return (await adbRun(path, ["connect", checked], this.#env)).trim();
  }

  /// `adb disconnect <address>`, as `connect`.
  async disconnect(address: string): Promise<string> {
    const checked = wirelessAddress(address);
    if (checked === null) throw new Error("not an address of a phone on the network (host:port)");
    const path = this.#adb();
    if (path === null) throw new Error(tr(stationLang(), "station.adb.noAdb"));
    return (await adbRun(path, ["disconnect", checked], this.#env)).trim();
  }

  /// The device listed as `id` now.
  sourceOf(id: string): AndroidScreen | undefined {
    return [...this.#listed.values()].find((l) => l.id === id)?.source;
  }

  /// What `emulator` is started with, so that it comes to the station's adb server.
  env(): NodeJS.ProcessEnv {
    return this.#env;
  }

  /// The station's adb server stopped, if it was started: it would outlive the station, holding its emulators. The one
  /// other call that names no device: it asks the server.
  async stopServer(): Promise<void> {
    // (a foldable left as asked is put back first, on this server)
    await Promise.allSettled(this.#leaving.splice(0));
    const path = this.#started ? this.#adb() : null;
    if (path !== null) await adbRun(path, ["kill-server"], this.#env).catch(() => {});
  }

  /// The station stopping: nothing followed, every source gone.
  close() {
    this.#closed = true;
    this.#rest?.();
    this.#again?.();
    this.#lookAgain?.();
    this.#follow?.kill();
    for (const listed of this.#listed.values()) {
      listed.remove();
      this.#leaving.push(listed.source.stop());
    }
    this.#listed.clear();
  }
}
