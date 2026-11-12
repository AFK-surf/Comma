// Ported from still.fail (github.com/AFK-surf/still.fail, afk/main 9967fe35be) station/src/screens/x11-h264.ts as it is
// there, but for `now` (Cue's: the clock the encoder's restart pacing reads, which a test moves; the wall's by default).
//
// X11 video for a client that takes H.264. Capture runs continuously, but only the newest raw picture is retained.
// A second ffmpeg encodes one picture when the transport asks for one: dropping an encoded delta frame would break
// every frame that refers to it. FLV gives each encoded packet a length and carries the avcC the clients already use.
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { wall } from "../ops/fibers.ts";
import type { Frame, ScreenVideo } from "./source.ts";

type Size = { width: number; height: number };
type Picture = { data: Buffer; ts: number };
type Pending = { resolve: (frame: Frame | null) => void; submitted: boolean; ts: number };
const MAX_PACKET = 16 * 1024 * 1024;
const OPEN_TIMEOUT = 10_000;
const RESTART_MS = 1_500;
const MIN_RATE = 300_000;
const MAX_RATE = 60_000_000;

/// ffmpeg may be blocked waiting for another raw picture; closing its input lets it observe termination.
function stopEncoder(child: ChildProcessWithoutNullStreams | null) {
  if (!child) return;
  child.stdin.destroy();
  child.kill();
}

export class X11H264 {
  readonly ready: Promise<void>;
  readonly #ffmpeg: string;
  readonly #env: NodeJS.ProcessEnv;
  readonly #size: Size;
  readonly #fps: number;
  readonly #capture: ChildProcessWithoutNullStreams;
  readonly #gone: () => void;
  readonly #rawSize: number;
  readonly #pool: Buffer[] = [];
  #building: Buffer;
  #built = 0;
  #latest: Picture | null = null;
  #encoder: ChildProcessWithoutNullStreams | null = null;
  #carry: Buffer = Buffer.alloc(0);
  #header = false;
  #description: Uint8Array | null = null;
  #config = true;
  #requested: number;
  #encoding = 0;
  #restarted = -Infinity;
  #force = false;
  #pending: Pending | null = null;
  #first: Frame | null = null;
  #lastTs = 0;
  #ended = false;
  #failure = "X11 H.264 capture ended";
  #stderr = "";
  #timer: () => void;
  readonly #now: () => number;

  constructor(ffmpeg: string, env: NodeJS.ProcessEnv, screen: Size, picture: Size, fps: number, bitrate: number | undefined, gone: () => void, now: () => number = wall.now) {
    this.#now = now;
    this.#ffmpeg = ffmpeg;
    this.#env = env;
    this.#size = picture;
    this.#fps = fps;
    this.#gone = gone;
    this.#requested = Math.min(MAX_RATE, Math.max(MIN_RATE, bitrate ?? 1_500_000));
    this.#rawSize = picture.width * picture.height * 3 / 2;
    this.#building = Buffer.allocUnsafe(this.#rawSize);
    const args = ["-nostdin", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "1", "-framerate", String(fps),
      "-video_size", `${screen.width}x${screen.height}`, "-i", env.DISPLAY!, "-vf", `scale=${picture.width}:${picture.height}:flags=fast_bilinear`,
      "-pix_fmt", "yuv420p", "-threads", "1", "-f", "rawvideo", "pipe:1"];
    this.#capture = spawn(ffmpeg, args, { env, stdio: ["pipe", "pipe", "pipe"] });
    this.#capture.stdin.end();
    this.#capture.stderr.on("data", (data: Buffer) => this.#errorText(data));
    this.#capture.stdout.on("data", (data: Buffer) => this.#raw(data));
    this.#capture.on("error", (error) => this.#end(error.message));
    this.#capture.on("close", () => this.#end(this.#stderr || "X11 capture ended"));
    this.#timer = wall.after(OPEN_TIMEOUT, () => this.#end("X11 H.264 capture did not produce a frame"));
    // Open waits for an actual encoded frame, so a missing encoder or inaccessible display is reported to the viewer.
    this.ready = this.#acquire().then((frame) => {
      if (!frame || this.#ended) throw new Error(this.#failure);
      this.#first = frame;
      this.#timer();
    });
  }

  #errorText(data: Buffer) { this.#stderr = (this.#stderr + data.toString()).slice(-2000).trim(); }
  #recycle(data: Buffer) { if (!this.#ended && this.#pool.length < 2) this.#pool.push(data); }

  #raw(chunk: Buffer) {
    if (this.#ended) return;
    let at = 0;
    while (at < chunk.length) {
      const take = Math.min(chunk.length - at, this.#rawSize - this.#built);
      chunk.copy(this.#building, this.#built, at, at + take);
      this.#built += take;
      at += take;
      if (this.#built !== this.#rawSize) continue;
      if (this.#latest) this.#recycle(this.#latest.data);
      this.#latest = { data: this.#building, ts: Number(process.hrtime.bigint() / 1000n) };
      this.#building = this.#pool.pop() ?? Buffer.allocUnsafe(this.#rawSize);
      this.#built = 0;
      this.#submit();
    }
  }

  #startEncoder() {
    const old = this.#encoder;
    this.#encoder = null;
    stopEncoder(old);
    this.#carry = Buffer.alloc(0);
    this.#header = false;
    this.#description = null;
    this.#config = true;
    this.#force = false;
    this.#encoding = Math.round(this.#requested);
    this.#restarted = this.#now();
    const args = ["-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-video_size", `${this.#size.width}x${this.#size.height}`,
      "-framerate", String(this.#fps), "-i", "pipe:0", "-an", "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency", "-profile:v", "baseline",
      // Limit key-frame bursts to keep a narrow link from queueing seconds of old pictures. A still screen sharpens
      // over following frames; veryfast retains small text better than ultrafast at the same constrained rate.
      "-pix_fmt", "yuv420p", "-g", String(this.#fps * 2), "-b:v", String(this.#encoding), "-maxrate", String(this.#encoding),
      "-bufsize", String(Math.max(100_000, Math.round(this.#encoding * 0.25))), "-x264-params", "vbv-init=0.5",
      "-threads", "1", "-flvflags", "no_duration_filesize", "-flush_packets", "1", "-f", "flv", "pipe:1"];
    const encoder = spawn(this.#ffmpeg, args, { env: this.#env, stdio: ["pipe", "pipe", "pipe"] });
    this.#encoder = encoder;
    encoder.stderr.on("data", (data: Buffer) => { if (this.#encoder === encoder) this.#errorText(data); });
    encoder.stdout.on("data", (data: Buffer) => { if (this.#encoder === encoder) this.#flv(data); });
    encoder.stdin.on("error", (error) => { if (this.#encoder === encoder) this.#end(error.message); });
    encoder.on("error", (error) => { if (this.#encoder === encoder) this.#end(error.message); });
    encoder.on("close", () => { if (this.#encoder === encoder) this.#end(this.#stderr || "H.264 encoder ended"); });
  }

  #submit() {
    const pending = this.#pending;
    if (this.#ended || !pending || pending.submitted || !this.#latest) return;
    // Lower the rate promptly when the link worsens. Increase it more cautiously: an optimistic estimate on a
    // narrow link otherwise repeatedly restarts the encoder, disrupting the picture just as it begins to sharpen.
    const elapsed = this.#now() - this.#restarted;
    const down = this.#requested < this.#encoding * 0.7 && elapsed >= RESTART_MS;
    const up = this.#requested > this.#encoding * 1.8 && elapsed >= RESTART_MS * 3;
    if (!this.#encoder || this.#force || down || up) this.#startEncoder();
    const picture = this.#latest;
    this.#latest = null;
    pending.ts = picture.ts;
    pending.submitted = true;
    this.#encoder!.stdin.write(picture.data, () => this.#recycle(picture.data));
  }

  #flv(chunk: Buffer) {
    if (this.#ended) return;
    this.#carry = this.#carry.length ? Buffer.concat([this.#carry, chunk]) : chunk;
    if (!this.#header) {
      if (this.#carry.length < 9) return;
      const offset = this.#carry.readUInt32BE(5);
      if (this.#carry.toString("ascii", 0, 3) !== "FLV" || offset < 9 || offset > 1024) return this.#end("invalid H.264 stream header");
      if (this.#carry.length < offset + 4) return;
      this.#carry = this.#carry.subarray(offset + 4);
      this.#header = true;
    }
    while (this.#carry.length >= 11) {
      const type = this.#carry[0]!;
      const length = this.#carry.readUIntBE(1, 3);
      if (length > MAX_PACKET) return this.#end("H.264 packet is too large");
      const total = 11 + length + 4;
      if (this.#carry.length < total) return;
      const payload = this.#carry.subarray(11, 11 + length);
      this.#carry = this.#carry.subarray(total);
      if (type !== 9 || payload.length < 5 || (payload[0]! & 15) !== 7) continue;
      if (payload[1] === 0) { this.#description = Uint8Array.from(payload.subarray(5)); continue; }
      if (payload[1] !== 1) continue;
      const pending = this.#pending;
      if (!pending?.submitted) return this.#end("unexpected H.264 frame");
      const key = (payload[0]! >> 4) === 1;
      if (this.#config && (!this.#description || !key)) return this.#end("H.264 stream did not start with a key frame and configuration");
      const ts = Math.max(this.#lastTs + 1, pending.ts);
      this.#lastTs = ts;
      const config = this.#config ? { config: { codec: "h264" as const, ...this.#size, description: this.#description! } } : {};
      this.#config = false;
      this.#pending = null;
      pending.resolve({ ...config, key, ts, data: Buffer.from(payload.subarray(5)) });
    }
  }

  #acquire(): Promise<Frame | null> {
    if (this.#ended) return Promise.resolve(null);
    if (this.#pending) return Promise.reject(new Error("a frame is already being captured"));
    return new Promise((resolve) => { this.#pending = { resolve, submitted: false, ts: 0 }; this.#submit(); });
  }

  async next(): Promise<Frame | null> {
    await this.ready;
    if (this.#ended) return null;
    if (this.#first) { const frame = this.#first; this.#first = null; return frame; }
    return this.#acquire();
  }

  rate(bits: number) {
    if (Number.isFinite(bits)) this.#requested = Math.min(MAX_RATE, Math.max(MIN_RATE, bits));
  }
  keyframe() { this.#force = true; }
  video(): ScreenVideo { return { capture: "X11", encoder: "ffmpeg libx264 (software)", hardware: false }; }

  #end(reason: string) {
    if (this.#ended) return;
    this.#ended = true;
    this.#failure = reason.trim();
    this.#timer();
    this.#capture.kill();
    const encoder = this.#encoder;
    this.#encoder = null;
    stopEncoder(encoder);
    this.#latest = null;
    this.#pool.length = 0;
    this.#carry = Buffer.alloc(0);
    const pending = this.#pending;
    this.#pending = null;
    pending?.resolve(null);
    this.#gone();
  }
  close() { this.#end("X11 H.264 view closed"); }
}
