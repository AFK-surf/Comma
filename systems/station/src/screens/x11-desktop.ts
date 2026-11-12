// The station user's X11 desktop as the screen source `display` (docs/desktop-screen.md, "Linux"). ffmpeg captures it and
// xdotool posts input; LinuxScreenTools can prepare them when the machine has no pair of its own.
// A view keeps only the newest frame, so a slow client cannot build a queue of old pictures. Wayland needs its own
// portal implementation: an Xwayland DISPLAY alone does not capture the Wayland desktop.
//
// Ported from still.fail (github.com/AFK-surf/still.fail, afk/main 9967fe35be) station/src/screens/x11-desktop.ts:
// `X11Desktop`, `fitted`, `EVDEV`, `keyOf`, `X11Input`, `X11View` and `X11H264View` as they are there. What differs
// (docs/desktop-screen.md, "Deviations"): the id is `display` and the source says its codecs; Cue's ViewOptions has no
// `fps`, so a view runs at still.fail's most, 15; Cue's ScreenRefused carries no access; and `DesktopX11Input` (Cue's
// own, at the end) takes the wire's desktop input (mesh/screens.ts `helperInput`) and gives `X11Input` still.fail's form
// of it, as win-input.ts `DesktopWinInput` does for Windows.
import { execFile, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { hostname } from "node:os";
import { promisify } from "node:util";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { ScreenRefused } from "./hub.ts";
import { executable, type LinuxScreenTools, type LinuxToolPair } from "./linux-tools.ts";
import type { Codec, DeviceInput, Frame, ScreenInput, ScreenSource, ScreenVideo, ScreenView, ViewOptions } from "./source.ts";
import { X11H264 } from "./x11-h264.ts";

const run = promisify(execFile);
const MAX_FRAME = 16 * 1024 * 1024;
const OPEN_TIMEOUT = 10_000;
const FRESH_MS = 2_000;
// xdotool temporarily changes the X keymap for characters outside the layout. Give applications time to read it.
const TYPE_DELAY_MS = 20;
// still.fail's source.ts caps a client's `fps` at this; Cue's clients ask none.
const FPS = 15;
type Size = { width: number; height: number };

/// Whether the desktop can be seen and driven now, and why not (still.fail source.ts `ScreenAccess`, its Linux X11
/// reasons; each is the i18n key `station.screen.<reason>`).
export type ScreenAccess = { capture: boolean; control: boolean; reason?: Reason };
type Reason = "linuxNoDisplay" | "linuxWayland" | "linuxTools" | "linuxToolsPreparing" | "linuxToolsFailed" | "linuxUnavailable";

export type X11DesktopOptions = {
  changed: () => void;
  title?: () => string;
  tools?: LinuxScreenTools;
  /// A test may supply its own desktop environment and binaries.
  env?: NodeJS.ProcessEnv;
  ffmpeg?: string;
  xdotool?: string;
  prepareWaitMs?: number;
  /// (Cue) The clock an H.264 view's encoder restarts are paced by (x11-h264.ts); the wall's by default.
  now?: () => number;
};

export class X11Desktop implements ScreenSource {
  /// The Mac's and Windows' whole display is `display` too: a client opens the same id on each.
  readonly id = "display";
  readonly kind = "desktop" as const;
  /// H.264 (libx264) where the client takes it, else JPEG.
  readonly codecs: readonly Codec[] = ["h264", "jpeg"];
  readonly #o: X11DesktopOptions;
  readonly #views = new Set<ScreenView>();
  #h264: Promise<boolean> | null = null;
  #h264Path: string | null = null;
  #size: Size = { width: 0, height: 0 };
  #reason: Reason | undefined = "linuxNoDisplay";
  #looked = 0;
  #looking: Promise<void> | null = null;
  #preparing: Promise<void> | null = null;
  #prepareFailed = false;
  #closed = false;

  constructor(options: X11DesktopOptions) { this.#o = options; }
  title(): string { return this.#o.title?.() ?? hostname(); }
  size(): Size { return { ...this.#size }; }
  access(): ScreenAccess {
    return this.#reason ? { capture: false, control: false, reason: this.#reason } : { capture: true, control: true };
  }

  #binaries(env: NodeJS.ProcessEnv): LinuxToolPair | null {
    const ffmpeg = executable(this.#o.ffmpeg ?? "ffmpeg", env);
    const xdotool = executable(this.#o.xdotool ?? "xdotool", env);
    if (ffmpeg && xdotool) return { ffmpeg, xdotool, env };
    return this.#o.ffmpeg || this.#o.xdotool ? null : this.#o.tools?.prepared(env) ?? null;
  }

  #prepare(env: NodeJS.ProcessEnv): void {
    const tools = this.#o.tools;
    if (this.#preparing || !tools?.canPrepare(env)) return;
    this.#prepareFailed = false;
    this.#preparing = tools.prepare(env).catch(() => {
      this.#prepareFailed = true;
      if (!this.#closed) log.warn("screen", "could not prepare the Linux screen tools");
    }).finally(() => {
      this.#preparing = null;
      if (!this.#closed) void this.refresh(true);
    });
  }

  /// Ask the X server in the station's own session; neither a display name nor a running process implies access.
  refresh(force = false): Promise<void> {
    if (!force && wall.now() - this.#looked < FRESH_MS) return Promise.resolve();
    this.#looking ??= this.#inspect().then(({ size, reason }) => {
      if (size.width !== this.#size.width || size.height !== this.#size.height || reason !== this.#reason) {
        this.#size = size;
        this.#reason = reason;
        this.#o.changed();
      }
    }).finally(() => { this.#looked = wall.now(); this.#looking = null; });
    return this.#looking;
  }

  async #inspect(): Promise<{ size: Size; reason?: Reason }> {
    const env = this.#o.env ?? process.env;
    const empty = { width: 0, height: 0 };
    if (env.XDG_SESSION_TYPE?.toLowerCase() === "wayland" || env.WAYLAND_DISPLAY) return { size: empty, reason: "linuxWayland" };
    if (!env.DISPLAY) return { size: empty, reason: "linuxNoDisplay" };
    const pair = this.#binaries(env);
    if (!pair) return { size: empty, reason: this.#preparing ? "linuxToolsPreparing" : this.#prepareFailed ? "linuxToolsFailed" : "linuxTools" };
    try {
      const { stdout } = await run(pair.xdotool, ["getdisplaygeometry"], { env: pair.env, timeout: 3_000 });
      const match = /^(\d+)\s+(\d+)\s*$/.exec(stdout);
      const width = Number(match?.[1]), height = Number(match?.[2]);
      if (!Number.isInteger(width) || !Number.isInteger(height) || width < 2 || height < 2 || width > 16384 || height > 16384) throw new Error("invalid display size");
      return { size: { width, height } };
    } catch {
      return { size: empty, reason: "linuxUnavailable" };
    }
  }

  async open(options: ViewOptions): Promise<ScreenView> {
    if (!options.codecs.includes("jpeg") && !options.codecs.includes("h264")) throw new ScreenRefused(415, "station.screen.codec", { codec: "H.264 or JPEG" });
    await this.refresh(true);
    const env = this.#o.env ?? process.env;
    if (this.#reason === "linuxTools" || this.#reason === "linuxToolsFailed") this.#prepare(env);
    if (this.#preparing) {
      // A first opening can take the pair as soon as it is ready. If a download takes longer, say so and let the
      // person reopen it; preparation continues even if the view was closed in the meantime.
      const preparing = this.#preparing;
      await new Promise<void>((resolve) => {
        const stop = wall.after(this.#o.prepareWaitMs ?? 8_000, resolve);
        preparing.then(() => { stop(); resolve(); });
      });
      await this.refresh(true);
    }
    if (this.#reason) throw new ScreenRefused(503, `station.screen.${this.#reason}`);
    // Both were found by refresh, but may have been removed since.
    const pair = this.#binaries(env);
    if (!pair) throw new ScreenRefused(503, "station.screen.linuxTools");
    const { ffmpeg, xdotool } = pair;
    const childEnv = pair.env;
    if (options.codecs.includes("h264")) {
      if (this.#h264Path !== ffmpeg) { this.#h264Path = ffmpeg; this.#h264 = null; }
      this.#h264 ??= run(ffmpeg, ["-hide_banner", "-encoders"], { env: childEnv, timeout: 3_000 }).then(({ stdout }) => /\blibx264\b/.test(stdout), () => false);
      if (await this.#h264) {
        const view = new X11H264View(ffmpeg, xdotool, childEnv, this.#size, options, () => this.#views.delete(view), this.#o.now);
        this.#views.add(view);
        try { await view.ready; return view; }
        catch (error) {
          view.close();
          if (!options.codecs.includes("jpeg")) throw new ScreenRefused(503, "station.screen.failed", { said: (error as Error).message });
        }
      } else if (!options.codecs.includes("jpeg")) {
        throw new ScreenRefused(415, "station.screen.codec", { codec: "H.264" });
      }
    }
    const view = new X11View(ffmpeg, xdotool, childEnv, this.#size, options, () => this.#views.delete(view));
    this.#views.add(view);
    try { await view.ready; return view; }
    catch (error) { view.close(); throw new ScreenRefused(503, "station.screen.failed", { said: (error as Error).message }); }
  }

  async close(): Promise<void> {
    this.#closed = true;
    this.#o.tools?.close();
    for (const view of [...this.#views]) view.close();
  }
}

/// The JPEG encoder needs even dimensions and does not enlarge a screen beyond its native size.
function fitted(size: Size, maxWidth: number, maxHeight: number): Size {
  const scale = Math.min(1, Math.max(2, maxWidth) / size.width, Math.max(2, maxHeight) / size.height);
  return { width: Math.max(2, Math.floor(size.width * scale / 2) * 2), height: Math.max(2, Math.floor(size.height * scale / 2) * 2) };
}

// DOM KeyboardEvent.code is a physical position. Xorg's evdev keycodes are Linux input codes plus 8: sending
// keysyms instead would move the key on a different layout (KeyQ, for example, is 'a' on French AZERTY).
export const EVDEV: Record<string, number> = {
  Escape: 1, Digit1: 2, Digit2: 3, Digit3: 4, Digit4: 5, Digit5: 6, Digit6: 7, Digit7: 8, Digit8: 9, Digit9: 10, Digit0: 11,
  Minus: 12, Equal: 13, Backspace: 14, Tab: 15,
  KeyQ: 16, KeyW: 17, KeyE: 18, KeyR: 19, KeyT: 20, KeyY: 21, KeyU: 22, KeyI: 23, KeyO: 24, KeyP: 25,
  BracketLeft: 26, BracketRight: 27, Enter: 28, ControlLeft: 29,
  KeyA: 30, KeyS: 31, KeyD: 32, KeyF: 33, KeyG: 34, KeyH: 35, KeyJ: 36, KeyK: 37, KeyL: 38,
  Semicolon: 39, Quote: 40, Backquote: 41, ShiftLeft: 42, Backslash: 43,
  KeyZ: 44, KeyX: 45, KeyC: 46, KeyV: 47, KeyB: 48, KeyN: 49, KeyM: 50, Comma: 51, Period: 52, Slash: 53,
  ShiftRight: 54, NumpadMultiply: 55, AltLeft: 56, Space: 57, CapsLock: 58,
  F1: 59, F2: 60, F3: 61, F4: 62, F5: 63, F6: 64, F7: 65, F8: 66, F9: 67, F10: 68,
  NumLock: 69, ScrollLock: 70, Numpad7: 71, Numpad8: 72, Numpad9: 73, NumpadSubtract: 74,
  Numpad4: 75, Numpad5: 76, Numpad6: 77, NumpadAdd: 78, Numpad1: 79, Numpad2: 80, Numpad3: 81, Numpad0: 82,
  NumpadDecimal: 83, IntlBackslash: 86, F11: 87, F12: 88, IntlRo: 89, Convert: 92, KanaMode: 93, NonConvert: 94,
  NumpadComma: 95, NumpadEnter: 96, ControlRight: 97, NumpadDivide: 98, PrintScreen: 99, AltRight: 100,
  Home: 102, ArrowUp: 103, PageUp: 104, ArrowLeft: 105, ArrowRight: 106, End: 107, ArrowDown: 108, PageDown: 109,
  Insert: 110, Delete: 111, AudioVolumeMute: 113, AudioVolumeDown: 114, AudioVolumeUp: 115, NumpadEqual: 117,
  Pause: 119, Lang1: 122, Lang2: 123, IntlYen: 124, MetaLeft: 125, MetaRight: 126, OSLeft: 125, OSRight: 126,
  ContextMenu: 127, MediaTrackNext: 163, MediaPlayPause: 164, MediaTrackPrevious: 165, MediaStop: 166,
  F13: 183, F14: 184, F15: 185, F16: 186, F17: 187, F18: 188, F19: 189, F20: 190, F21: 191, F22: 192, F23: 193, F24: 194,
};

/// xdotool accepts a decimal string as a literal X keycode.
function keyOf(code: string): string | null {
  const evdev = EVDEV[code];
  return evdev === undefined ? null : String(evdev + 8);
}

const MODS = [
  { bit: 1, keys: [keyOf("AltLeft")!, keyOf("AltRight")!] }, { bit: 2, keys: [keyOf("ControlLeft")!, keyOf("ControlRight")!] },
  { bit: 4, keys: [keyOf("MetaLeft")!, keyOf("MetaRight")!] }, { bit: 8, keys: [keyOf("ShiftLeft")!, keyOf("ShiftRight")!] },
];
const BUTTONS = [{ bit: 1, button: 1 }, { bit: 2, button: 3 }, { bit: 4, button: 2 }];

/// still.fail's source.ts `ScreenInput`, as `X11Input` takes it.
type StillInput = DeviceInput;

class X11Input {
  readonly #xdotool: string;
  readonly #env: NodeJS.ProcessEnv;
  readonly #screen: Size;
  readonly #keys = new Set<string>();
  readonly #buttons = new Set<number>();
  #input: Promise<void> = Promise.resolve();
  #wheel = { x: 0, y: 0 };
  #ended = false;

  constructor(xdotool: string, env: NodeJS.ProcessEnv, screen: Size) {
    this.#xdotool = xdotool;
    this.#env = env;
    this.#screen = { ...screen };
  }

  async #command(args: string[], timeout = 3_000): Promise<void> {
    await run(this.#xdotool, args, { env: this.#env, timeout });
  }
  async #type(text: string): Promise<void> {
    await this.#command(["type", "--delay", String(TYPE_DELAY_MS), "--", text], 5_000 + Array.from(text).length * TYPE_DELAY_MS * 3);
  }
  input(event: StillInput): Promise<void> {
    const next = this.#input.then(async () => {
      if (this.#ended) return;
      const point = (x: number, y: number) => [String(Math.max(0, Math.min(this.#screen.width - 1, Math.round(x * (this.#screen.width - 1))))), String(Math.max(0, Math.min(this.#screen.height - 1, Math.round(y * (this.#screen.height - 1)))))];
      if (event.t === "pointer") {
        await this.#command(["mousemove", ...point(event.x, event.y)]);
        for (const { bit, button } of BUTTONS) {
          const down = (event.buttons & bit) !== 0, was = this.#buttons.has(button);
          if (down === was) continue;
          await this.#command([down ? "mousedown" : "mouseup", String(button)]);
          if (down) this.#buttons.add(button); else this.#buttons.delete(button);
        }
      } else if (event.t === "wheel") {
        await this.#command(["mousemove", ...point(event.x, event.y)]);
        this.#wheel.x += event.dx / 100;
        this.#wheel.y += event.dy / 100;
        for (const axis of ["x", "y"] as const) {
          const whole = Math.trunc(this.#wheel[axis]);
          if (!whole) continue;
          const count = Math.min(20, Math.abs(whole));
          this.#wheel[axis] -= Math.sign(whole) * count;
          const button = axis === "y" ? (whole > 0 ? 5 : 4) : (whole > 0 ? 7 : 6);
          await this.#command(["click", "--repeat", String(count), "--delay", "0", String(button)]);
        }
      } else if (event.t === "key") {
        const key = keyOf(event.code);
        if (!key) {
          if (event.kind === "down" && Array.from(event.key).length === 1 && (event.mods & 6) === 0) await this.#type(event.key);
          return;
        }
        if (event.kind === "up") {
          await this.#command(["keyup", key]);
          this.#keys.delete(key);
          return;
        }
        const temporary = MODS.filter((m) => (event.mods & m.bit) !== 0 && !m.keys.includes(key) && !m.keys.some((k) => this.#keys.has(k))).map((m) => m.keys[0]!);
        for (const mod of temporary) { await this.#command(["keydown", mod]); this.#keys.add(mod); }
        await this.#command(["keydown", key]);
        this.#keys.add(key);
        for (const mod of temporary.reverse()) { await this.#command(["keyup", mod]); this.#keys.delete(mod); }
      } else if (event.t === "text" && event.text) {
        await this.#type(event.text);
      }
    });
    this.#input = next.catch(() => {});
    return next;
  }

  close(): void {
    if (this.#ended) return;
    this.#ended = true;
    // Release anything this view pressed even if its client disappeared while dragging or typing.
    void this.#input.then(async () => {
      for (const key of this.#keys) await this.#command(["keyup", key]).catch(() => {});
      for (const button of this.#buttons) await this.#command(["mouseup", String(button)]).catch(() => {});
      this.#keys.clear();
      this.#buttons.clear();
    });
  }
}

class X11View implements ScreenView {
  readonly ready: Promise<void>;
  readonly #child: ChildProcessWithoutNullStreams;
  readonly #inputs: DesktopX11Input;
  readonly #picture: Size;
  readonly #gone: () => void;
  #carry: Buffer = Buffer.alloc(0);
  #latest: { data: Buffer; ts: number } | null = null;
  #waiting: ((frame: Frame | null) => void)[] = [];
  #config = true;
  #lastTs = 0;
  #ended = false;
  #opened = false;
  #resolve!: () => void;
  #reject!: (error: Error) => void;
  #timer: () => void;
  #stderr = "";

  constructor(ffmpeg: string, xdotool: string, env: NodeJS.ProcessEnv, screen: Size, options: ViewOptions, gone: () => void) {
    this.#inputs = new DesktopX11Input(xdotool, env, screen);
    this.#picture = fitted(screen, options.maxWidth, options.maxHeight);
    this.#gone = gone;
    this.ready = new Promise((resolve, reject) => { this.#resolve = resolve; this.#reject = reject; });
    // Bound this experimental software encoder's CPU use even when a client asks for a higher frame rate.
    const fps = FPS;
    const args = ["-nostdin", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "1", "-framerate", String(fps),
      "-video_size", `${screen.width}x${screen.height}`, "-i", env.DISPLAY!, "-vf", `scale=${this.#picture.width}:${this.#picture.height}:flags=fast_bilinear`,
      "-c:v", "mjpeg", "-q:v", "5", "-threads", "1", "-f", "image2pipe", "pipe:1"];
    this.#child = spawn(ffmpeg, args, { env, stdio: ["pipe", "pipe", "pipe"] });
    this.#child.stdin.end();
    this.#child.stderr.on("data", (data: Buffer) => { this.#stderr = (this.#stderr + data.toString()).slice(-2000); });
    this.#child.stdout.on("data", (data: Buffer) => this.#read(data));
    this.#child.on("error", (error) => this.#end(error));
    this.#child.on("close", () => this.#end(new Error(this.#stderr.trim() || "X11 capture ended")));
    this.#timer = wall.after(OPEN_TIMEOUT, () => this.#end(new Error("X11 capture did not produce a frame")));
  }

  #read(chunk: Buffer) {
    if (this.#ended) return;
    this.#carry = this.#carry.length ? Buffer.concat([this.#carry, chunk]) : chunk;
    while (this.#carry.length) {
      const start = this.#carry.indexOf(Buffer.from([0xff, 0xd8]));
      if (start < 0) { this.#carry = this.#carry.subarray(Math.max(0, this.#carry.length - 1)); return; }
      if (start > 0) this.#carry = this.#carry.subarray(start);
      const end = this.#carry.indexOf(Buffer.from([0xff, 0xd9]), 2);
      if (end < 0) {
        if (this.#carry.length > MAX_FRAME) this.#end(new Error("X11 frame is too large"));
        return;
      }
      if (end + 2 > MAX_FRAME) { this.#end(new Error("X11 frame is too large")); return; }
      const data = this.#carry.subarray(0, end + 2);
      this.#carry = this.#carry.subarray(end + 2);
      const ts = Math.max(this.#lastTs + 1, Number(process.hrtime.bigint() / 1000n));
      this.#lastTs = ts;
      const waiting = this.#waiting.shift();
      if (waiting) waiting(this.#frame(data, ts));
      else this.#latest = { data, ts };
      if (!this.#opened) { this.#opened = true; this.#timer(); this.#resolve(); }
    }
  }

  #frame(data: Buffer, ts: number): Frame {
    const config = this.#config ? { config: { codec: "jpeg" as const, ...this.#picture } } : {};
    this.#config = false;
    return { ...config, key: true, ts, data };
  }
  next(): Promise<Frame | null> {
    if (this.#ended) return Promise.resolve(null);
    if (this.#latest) {
      const { data, ts } = this.#latest;
      this.#latest = null;
      return Promise.resolve(this.#frame(data, ts));
    }
    return new Promise((resolve) => this.#waiting.push(resolve));
  }
  keyframe(): void {} // Each JPEG is a key frame.
  video(): ScreenVideo { return { capture: "X11", encoder: "ffmpeg MJPEG (software)" }; }

  input(event: ScreenInput): Promise<void> { return this.#inputs.input(event); }

  #end(error: Error) {
    if (this.#ended) return;
    this.#ended = true;
    this.#timer();
    if (!this.#opened) this.#reject(error);
    this.#child.kill();
    this.#latest = null;
    for (const waiting of this.#waiting.splice(0)) waiting(null);
    this.#inputs.close();
    this.#gone();
  }
  close(): void { this.#end(new Error("X11 view closed")); }
}

/// The same X11 input as the JPEG view, with an on-demand H.264 encoder for clients that can decode it.
class X11H264View implements ScreenView {
  readonly ready: Promise<void>;
  readonly #inputs: DesktopX11Input;
  readonly #video: X11H264;
  readonly #gone: () => void;
  #ended = false;

  constructor(ffmpeg: string, xdotool: string, env: NodeJS.ProcessEnv, screen: Size, options: ViewOptions, gone: () => void, now?: () => number) {
    this.#inputs = new DesktopX11Input(xdotool, env, screen);
    this.#gone = gone;
    // Raw frames live in memory while the encoder takes them; cap each view to a 4K picture.
    const picture = fitted(screen, Math.min(options.maxWidth, 3840), Math.min(options.maxHeight, 2160));
    const fps = FPS;
    this.#video = new X11H264(ffmpeg, env, screen, picture, fps, options.bitrate, () => this.close(), now);
    this.ready = this.#video.ready;
  }

  next(): Promise<Frame | null> { return this.#video.next(); }
  input(event: ScreenInput): Promise<void> { return this.#inputs.input(event); }
  rate(bits: number): void { this.#video.rate(bits); }
  keyframe(): void { this.#video.keyframe(); }
  video(): ScreenVideo { return this.#video.video(); }
  close(): void {
    if (this.#ended) return;
    this.#ended = true;
    this.#video.close();
    this.#inputs.close();
    this.#gone();
  }
}

/// The wire's button (0 primary, 1 secondary, 2 middle: Cue's client's `wireButton`) as DOM `buttons` bits.
const BIT_OF_WIRE_BUTTON: Record<number, number> = { 0: 1, 1: 2, 2: 4 };
/// The wire's modifier names as still.fail's `mods` bits (0 alt, 1 ctrl, 2 meta, 3 shift).
const MOD_BITS: Record<string, number> = { alt: 1, ctrl: 2, meta: 4, shift: 8 };
const finite = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const unit = (v: number) => Math.min(1, Math.max(0, v));
/// How far one wheel event may say it went, in a page's pixels (mesh/screens.ts's bound for a device's).
const WHEEL_MOST = 10_000;
const wheel = (v: number) => Math.min(WHEEL_MOST, Math.max(-WHEEL_MOST, v));

/// (Cue) One view's input as Cue's client sends a computer's screen (`{type: "move" | "down" | "up" | "scroll" |
/// "keydown" | "keyup" | "text"}`), made still.fail's form for `X11Input`: the buttons held followed (a move with one
/// held is a drag), a key's `key` kept for a key of no known place, text typed as it is. An event already in still.fail's
/// form (`{t: …}`) goes as it is.
export class DesktopX11Input {
  readonly #x11: X11Input;
  #buttons = 0;

  constructor(xdotool: string, env: NodeJS.ProcessEnv, screen: Size) {
    this.#x11 = new X11Input(xdotool, env, screen);
  }

  input(event: ScreenInput): Promise<void> {
    const still = "t" in event ? (event as StillInput) : this.#still(event as Record<string, unknown>);
    return still === null ? Promise.resolve() : this.#x11.input(still);
  }

  #still(v: Record<string, unknown>): StillInput | null {
    const at = finite(v.x) && finite(v.y) ? { x: unit(v.x), y: unit(v.y) } : null;
    const mods = Array.isArray(v.mods) ? v.mods.reduce((bits: number, m) => bits | (MOD_BITS[m as string] ?? 0), 0) : 0;
    switch (v.type) {
      case "move":
        return at && { t: "pointer", kind: "move", ...at, buttons: this.#buttons };
      case "down":
      case "up": {
        const bit = BIT_OF_WIRE_BUTTON[v.button as number] ?? 1;
        this.#buttons = v.type === "down" ? this.#buttons | bit : this.#buttons & ~bit;
        return at && { t: "pointer", kind: v.type, ...at, buttons: this.#buttons };
      }
      case "scroll":
        return at && finite(v.dx) && finite(v.dy) ? { t: "wheel", ...at, dx: wheel(v.dx), dy: wheel(v.dy) } : null;
      case "keydown":
      case "keyup":
        return typeof v.code === "string" && v.code.length <= 64
          ? { t: "key", kind: v.type === "keydown" ? "down" : "up", key: typeof v.key === "string" && v.key.length <= 16 ? v.key : "", code: v.code, mods }
          : null;
      case "text":
        return typeof v.text === "string" && v.text !== "" ? { t: "text", text: v.text } : null;
      default:
        return null;
    }
  }

  close(): void {
    this.#x11.close();
  }
}
