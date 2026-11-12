// One view over still.fail's helper messages: a connection to a process that captures and encodes a screen, asked for
// each frame. Ported from still.fail (github.com/AFK-surf/still.fail, afk/main 7470ca2abe; unchanged at b928883a23;
// clipboard and audio from afk/main 3d517e022e) station/src/screens/desktop.ts: `HelperView`, `helperMessage`,
// `helperClip`, `TO_HELPER`, `HelperPipe`, `InputOps`. As there, two helpers speak it: the Mac's Computer Use helper (its
// CUStream/ScreenView.swift, a port of still.fail Helper's: an app's windows, a display and an iOS Simulator, helper.ts
// and simulator.ts) and comma-desktop-screen (native/desktop-screen, its port of stillfail-screen: win-desktop.ts).
//
// The clipboard (4 and 5 to it, 5 from it) and the system output (9 to it, 8 and 9 from it) are still.fail's as they
// are. What differs from still.fail's (docs/desktop-screen.md, "Deviations"): Cue's ScreenView carries no part of the
// display (regions), reveal or simulator turn yet, so this view never asks for them and lets their messages be. The
// messages, their numbers and their layout are still.fail's. Cue's own beside them, from the Mac's helper: message 64
// (an app's view: which apps and how many windows, as they move; the info's `geometry` first), 65 (how a simulator
// stands: `{orientation, pose?}`) and 66 (a view opened `timing`, just before each frame: its timestamp, when the encoder
// took it and gave it out, when it was sent; 4 × 8 bytes µs on the host's clock: mesh/screen-timing.ts).
import { log } from "../ops/log.ts";
import { SCREEN_AUDIO_BYTES, SCREEN_OPUS_MAX, clipFits, type ScreenAudioCodec } from "@comma/mesh";
import { hostNow } from "../mesh/screen-pace.ts";
import { ScreenRefused } from "./hub.ts";
import type { AudioFrame, Clip, ClipType, Codec, DeviceStands, Frame, FrameConfig, HelperTiming, ScreenCursor, ScreenInput, ScreenTargetInfo, ScreenVideo, ScreenView } from "./source.ts";

/// The helper's messages: a kind byte, the payload's length (4 bytes), the payload (comma-desktop-screen's main.rs says
/// each). To it: 1 next, 2 keyframe, 3 input, 4 clipboard (flags: bit 0 paste; type: 1 text, 2 PNG; the bytes), 5 watch
/// the clipboard (1 on, 0 off), 6 reveal, 7 rate (bits a second, 4 bytes), 8 bounds, 9 audio (empty: the next 20 ms
/// packet of system output, a view opened with `audio: true` whose info says `audio: true`). From it: 1 info, 2 config,
/// 3 frame, 4 event, 5 clipboard (type, bytes), 6 cursor (JSON {x, y, shape}: a video's pictures leave the pointer out),
/// 7 region, 8 audio config (JSON {codec: "pcm_s16le" | "opus", sampleRate: 48000, channels: 2}, or {error}: no more
/// audio; `opus` only to a view opened with `audioCodec: "opus"`), 9 audio (8 bytes timestamp µs, then 3840 bytes of
/// interleaved stereo PCM16, or one Opus packet of 20 ms). This view uses all but 6 to it and 7 from
/// it, and Cue's 64 and 65.
export const TO_HELPER = { next: 1, keyframe: 2, input: 3, clipboard: 4, watch: 5, reveal: 6, rate: 7, bounds: 8, audio: 9 } as const;
const CLIP_BYTE: Record<ClipType, number> = { text: 1, png: 2 };

/// A clip as the helper's `clipboard` message has it: from the helper (`flags` none) or to it.
export function helperClip(clip: Clip, flags?: number): Buffer {
  const body = clip.type === "text" ? Buffer.from(clip.text, "utf8") : Buffer.from(clip.data);
  return Buffer.concat([Buffer.from(flags === undefined ? [CLIP_BYTE[clip.type]] : [flags, CLIP_BYTE[clip.type]]), body]);
}

export function helperMessage(kind: number, payload: Buffer = Buffer.alloc(0)): Buffer {
  const head = Buffer.alloc(5);
  head[0] = kind;
  head.writeUInt32BE(payload.length, 1);
  return Buffer.concat([head, payload]);
}

/// What carries a view's messages to and from the process: its pipes (win-desktop.ts `childPipe`).
export type HelperPipe = { write(data: Buffer): unknown; destroy(): unknown; on(event: "data", listener: (chunk: Buffer) => void): unknown; on(event: "error" | "close", listener: () => void): unknown };

/// How a view's input is posted on the machine: the ops the process takes for one person's event (win-input.ts,
/// sim-input.ts; the Mac's desktop takes the event as it is: `AS_IS`), at `now` (ms).
export type InputOps = { ops(event: ScreenInput, now: number): object[] };

/// The Mac helper's desktop input: the wire's computer form as it is (mesh/screens.ts `helperInput` checked it), which
/// its RemoteInputInjector.swift posts. still.fail's station makes ops of it (mac-input.ts); Cue's helper does that
/// itself (#4971).
export const AS_IS: InputOps = { ops: (event) => [event] };

/// What the Mac's helper says of an app's view (its info's `geometry`, message 64).
export function targetOf(said: unknown): ScreenTargetInfo | null {
  const { target, apps, windows } = (said ?? {}) as { target?: unknown; apps?: unknown; windows?: unknown };
  if (target !== "app" || !Array.isArray(apps)) return null;
  return { apps: apps.filter((app): app is string => typeof app === "string" && app !== ""), windows: typeof windows === "number" ? windows : 1 };
}

/// One view: a connection to the process, asked for each frame.
export class HelperView implements ScreenView {
  readonly ready: Promise<{ width: number; height: number }>;
  readonly #socket: HelperPipe;
  readonly #input: InputOps;
  #carry: Buffer = Buffer.alloc(0);
  #waiting: ((frame: Frame | null) => void)[] = [];
  #config: FrameConfig | undefined;
  /// The system output asked, and still had (its info said it, and no error since); the packet asked and not had yet.
  #audio = false;
  /// The codec the helper said its packets are in (message 8).
  #audioCodec: ScreenAudioCodec = "pcm_s16le";
  #audioWait: ((frame: AudioFrame | null) => void) | null = null;
  /// Who hears the clipboard as it changes, while it is watched.
  #clipboard: ((clip: Clip) => void) | null = null;
  #ended = false;
  #refusal: ScreenRefused | undefined;
  #settle!: { resolve: (v: { width: number; height: number }) => void; reject: (e: Error) => void };
  readonly #gone: () => void;
  /// Who hears the pointer, and the last it said (told at once to one who starts to hear it).
  #cursor: ((cursor: ScreenCursor) => void) | null = null;
  #lastCursor: ScreenCursor | null = null;
  /// What it was asked for, then what it encodes (its `info`).
  #codec: Codec;
  /// What captures its pictures (ScreenCaptureKit, CoreSimulator, Windows.Graphics.Capture), and the encoder as its info
  /// named it.
  readonly #capture: string;
  #encoder = "";
  /// Its first info came.
  #opened = false;
  /// What an app's view shows as the helper said it last, and who hears.
  #target: ScreenTargetInfo | null = null;
  readonly #targetListeners = new Set<() => void>();
  /// How a device stands as the helper said it last, and who hears it.
  #stands: DeviceStands | null = null;
  #hears: ((stands: DeviceStands) => void) | null = null;
  readonly #now: () => number;
  /// Each frame's times kept (a view opened `timing`), and the helper's for the next frame (message 66).
  readonly #timing: boolean;
  #stamps: { ts: number; encodeStart: number; encodeDone: number; sent: number } | null = null;

  constructor(codec: Codec, socket: HelperPipe, gone: () => void, input: InputOps, capture: string, now: () => number, audio = false, timing = false) {
    this.#audio = audio;
    this.#timing = timing;
    this.#codec = codec;
    this.#capture = capture;
    this.#socket = socket;
    this.#input = input;
    this.#gone = gone;
    this.#now = now;
    this.ready = new Promise((resolve, reject) => (this.#settle = { resolve, reject }));
    socket.on("data", (chunk: Buffer) => this.#heard(chunk));
    socket.on("error", () => this.close());
    socket.on("close", () => {
      this.#settle.reject(new Error("the screen's helper ended the view"));
      this.close();
    });
  }

  #heard(chunk: Buffer) {
    this.#carry = this.#carry.length === 0 ? chunk : Buffer.concat([this.#carry, chunk]);
    while (this.#carry.length >= 5) {
      const length = this.#carry.readUInt32BE(1);
      if (this.#carry.length < 5 + length) return;
      const kind = this.#carry[0]!;
      const payload = this.#carry.subarray(5, 5 + length);
      this.#carry = this.#carry.subarray(5 + length);
      this.#message(kind, payload);
    }
  }

  #message(kind: number, payload: Buffer) {
    switch (kind) {
      case 1: {
        let info: any = null;
        try {
          info = JSON.parse(payload.toString());
        } catch {}
        if (info === null || typeof info !== "object") this.#settle.reject(new Error("the screen's helper said no info"));
        else if (typeof info.error === "string") this.#settle.reject(Object.assign(new Error(info.error), { code: info.code }));
        else {
          // What it encodes: as it says (H.264 where H.265 was asked and the hardware has no encoder of it).
          this.#codec = info.codec === "h265" || info.codec === "h264" || info.codec === "jpeg" ? info.codec : this.#codec === "jpeg" ? "jpeg" : "h264";
          // (Cue) An info after the first: the Mac helper's encoder made anew with another codec or encoder (a fallback),
          // said before that encoder's config; the statistics (`video`) and the next config go by it.
          log.info("screens", this.#opened ? "a view's encoder changed" : "a view opened", { capture: this.video().capture, width: info.width, height: info.height, encoder: info.encoder, codec: this.#codec });
          if (typeof info.encoder === "string") this.#encoder = info.encoder.slice(0, 200);
          if (info.geometry !== null && typeof info.geometry === "object") this.#place(info.geometry);
          // A helper from before the system output says none: none is pulled. (An info after the first says nothing of it.)
          if (!this.#opened) this.#audio = this.#audio && info.audio === true;
          this.#opened = true;
          this.#settle.resolve({ width: info.width, height: info.height });
        }
        return;
      }
      case 2:
        this.#config = { codec: this.#codec, width: payload.readUInt32BE(0), height: payload.readUInt32BE(4), ...(this.#codec !== "jpeg" ? { description: new Uint8Array(payload.subarray(8)) } : {}) };
        return;
      case 3: {
        const frame: Frame = { key: (payload[0]! & 1) === 1, ts: Number(payload.readBigUInt64BE(1)), data: new Uint8Array(payload.subarray(9)) };
        if (this.#timing) frame.timing = this.#timed(frame.ts);
        if (this.#config !== undefined) {
          frame.config = this.#config;
          this.#config = undefined;
        }
        this.#waiting.shift()?.(frame);
        return;
      }
      case 66:
        if (this.#timing && payload.length >= 32) {
          const [ts, encodeStart, encodeDone, sent] = [0, 8, 16, 24].map((at) => Number(payload.readBigUInt64BE(at)));
          this.#stamps = { ts: ts!, encodeStart: encodeStart!, encodeDone: encodeDone!, sent: sent! };
        }
        return;
      case 4: {
        log.info("screens", "a screen's helper", { capture: this.#capture, said: payload.toString().slice(0, 500) });
        let event: unknown;
        try { event = JSON.parse(payload.toString()); } catch { return; }
        const stopped = (event as { stopped?: unknown } | null)?.stopped;
        if (typeof stopped === "string" && stopped.trim()) {
          this.#refusal = new ScreenRefused(503, "station.screen.failed", { said: stopped.slice(0, 2000) });
          this.#settle.reject(new Error(stopped));
          this.close();
        }
        return;
      }
      case 5: {
        const body = payload.subarray(1);
        const clip: Clip | null = payload[0] === 1 ? { type: "text", text: body.toString("utf8") } : payload[0] === 2 ? { type: "png", data: new Uint8Array(body) } : null;
        if (clip !== null && clipFits(clip)) this.#clipboard?.(clip);
        return;
      }
      case 8: {
        let config: any;
        try {
          config = JSON.parse(payload.toString());
        } catch {
          config = null;
        }
        if ((config?.codec === "pcm_s16le" || config?.codec === "opus") && config.sampleRate === 48000 && config.channels === 2) this.#audioCodec = config.codec;
        else {
          if (typeof config?.error === "string") log.info("screens", "a screen's system audio ended", { capture: this.#capture, error: config.error.slice(0, 500) });
          this.#audio = false;
          const resolve = this.#audioWait;
          this.#audioWait = null;
          resolve?.(null);
        }
        return;
      }
      case 9: {
        const resolve = this.#audioWait;
        this.#audioWait = null;
        if (!resolve) return;
        const size = payload.length - 8;
        if (this.#audioCodec === "pcm_s16le" ? size !== SCREEN_AUDIO_BYTES : size < 1 || size > SCREEN_OPUS_MAX) {
          this.#audio = false;
          resolve(null);
          return;
        }
        resolve({ ts: Number(payload.readBigUInt64BE(0)), data: new Uint8Array(payload.subarray(8)), codec: this.#audioCodec });
        return;
      }
      case 64: {
        let said: any = null;
        try {
          said = JSON.parse(payload.toString());
        } catch {}
        if (said !== null && typeof said === "object") this.#place(said);
        return;
      }
      case 65: {
        let said: any = null;
        try {
          said = JSON.parse(payload.toString());
        } catch {}
        const { orientation, pose } = said ?? {};
        this.#stands = {
          ...(orientation === 0 || orientation === 90 || orientation === 180 || orientation === 270 ? { orientation } : {}),
          ...(pose === "closed" || pose === "book" || pose === "open" ? { pose } : {}),
        };
        this.#hears?.(this.#stands);
        return;
      }
      case 6: {
        let said: any = null;
        try {
          said = JSON.parse(payload.toString());
        } catch {}
        const unit = (v: unknown) => typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 1;
        if (said === null || !unit(said.x) || !unit(said.y)) return;
        this.#lastCursor = { x: said.x, y: said.y, shape: typeof said.shape === "string" && /^[a-z-]{1,24}$/.test(said.shape) ? said.shape : "default" };
        this.#cursor?.(this.#lastCursor);
        return;
      }
    }
  }

  /// Frame `ts`'s times: the helper's (message 66, when it said them of this frame), and the station's having it now.
  #timed(ts: number): HelperTiming {
    const stamps = this.#stamps?.ts === ts ? this.#stamps : null;
    this.#stamps = null;
    return { ...(stamps ? { encodeStart: stamps.encodeStart / 1000, encodeDone: stamps.encodeDone / 1000, sent: stamps.sent / 1000 } : {}), got: hostNow() };
  }

  /// What an app's view shows now (Cue's message 64): its listeners told when the apps or their windows changed.
  #place(geometry: Record<string, unknown>) {
    const target = targetOf(geometry);
    if (target === null || (target.windows === this.#target?.windows && target.apps.join() === this.#target?.apps.join())) return;
    const had = this.#target !== null;
    this.#target = target;
    if (had) for (const listener of [...this.#targetListeners]) listener();
  }

  target(): ScreenTargetInfo | null {
    return this.#target;
  }

  onTarget(listener: () => void): () => void {
    this.#targetListeners.add(listener);
    return () => void this.#targetListeners.delete(listener);
  }

  /// Says how the device stands, at once where the helper has said, and whenever that changes.
  watchDevice(heard: (stands: DeviceStands) => void): () => void {
    this.#hears = heard;
    if (this.#stands) heard(this.#stands);
    return () => {
      if (this.#hears === heard) this.#hears = null;
    };
  }

  video(): ScreenVideo {
    const capture = this.#capture;
    // The helpers name a software encoder so ("software", "Microsoft H.264 (software)"); a JPEG is no encoder's.
    if (this.#codec === "jpeg" || this.#encoder === "") return { capture, ...(this.#encoder ? { encoder: this.#encoder } : {}) };
    return { capture, encoder: this.#encoder, hardware: !/software/i.test(this.#encoder) };
  }

  /// The pictures from now on fitted into these bounds (message 8; a config first when that changes their size).
  bounds(maxWidth: number, maxHeight: number) {
    this.#send(TO_HELPER.bounds, Buffer.from(JSON.stringify({ maxWidth: Math.round(maxWidth), maxHeight: Math.round(maxHeight) })));
  }

  #send(kind: number, payload?: Buffer) {
    if (this.#ended) return;
    this.#socket.write(helperMessage(kind, payload));
  }

  next(): Promise<Frame | null> {
    if (this.#ended) return this.#refusal ? Promise.reject(this.#refusal) : Promise.resolve(null);
    return new Promise<Frame | null>((resolve) => {
      this.#waiting.push(resolve);
      this.#send(TO_HELPER.next);
    }).then((frame) => {
      if (frame === null && this.#refusal) throw this.#refusal;
      return frame;
    });
  }

  keyframe() {
    this.#send(TO_HELPER.keyframe);
  }

  rate(bitsPerSecond: number) {
    if (this.#codec === "jpeg") return;
    const payload = Buffer.alloc(4);
    payload.writeUInt32BE(Math.min(0xffff_ffff, Math.max(0, Math.round(bitsPerSecond))));
    this.#send(TO_HELPER.rate, payload);
  }

  async input(event: ScreenInput): Promise<void> {
    for (const op of this.#input.ops(event, this.#now())) this.#send(TO_HELPER.input, Buffer.from(JSON.stringify(op)));
  }

  /// Whether it still has the system output it was asked (its info said it, and nothing went wrong since).
  hasAudio(): boolean {
    return this.#audio;
  }

  nextAudio(): Promise<AudioFrame | null> {
    if (this.#ended || !this.#audio) return Promise.resolve(null);
    if (this.#audioWait) return Promise.reject(new Error("audio already pending"));
    return new Promise((resolve) => {
      this.#audioWait = resolve;
      this.#send(TO_HELPER.audio);
    });
  }

  async setClipboard(clip: Clip, paste: boolean): Promise<void> {
    this.#send(TO_HELPER.clipboard, helperClip(clip, paste ? 1 : 0));
  }

  watchClipboard(heard: (clip: Clip) => void): () => void {
    this.#clipboard = heard;
    this.#send(TO_HELPER.watch, Buffer.from([1]));
    return () => {
      if (this.#clipboard !== heard) return;
      this.#clipboard = null;
      this.#send(TO_HELPER.watch, Buffer.from([0]));
    };
  }

  watchCursor(heard: (cursor: ScreenCursor) => void): () => void {
    this.#cursor = heard;
    if (this.#lastCursor) heard(this.#lastCursor);
    return () => {
      if (this.#cursor === heard) this.#cursor = null;
    };
  }

  close() {
    if (this.#ended) return;
    this.#ended = true;
    this.#socket.destroy();
    for (const resolve of this.#waiting.splice(0)) resolve(null);
    this.#audioWait?.(null);
    this.#audioWait = null;
    this.#gone();
  }
}
