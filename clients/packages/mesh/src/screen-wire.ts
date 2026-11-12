// A view of a station's screen on `comma/mesh/1`, after still.fail's (docs/remote-screens.md there, "Wire"). One request
// stream: `GET /screens` lists what can be viewed; `POST /screens/<id>/view` with its ask in the `x-comma-screen` header
// is answered `application/x-comma-screen`, and then both directions carry frames until either side finishes: a kind
// byte, the payload's length (4 bytes, big-endian), the payload.
//
//   1 config    station → client  JSON {codec, width, height, description}: the avcC in base64. Before the first video
//                                 frame and whenever these change; the next video frame is a key frame.
//   2 video     station → client  1 byte flags (bit 0: key frame), 8 bytes timestamp (µs, big-endian), length-prefixed
//                                 NAL units (AVCC), parameter sets in the config only.
//   3 state     station → client  JSON {control?, switches?, refused?, latency?, video?, cursor?, ended?, endedCode?, orientation?,
//                                 pose?, timing?, agent?, agentPointer?}: `control` whether the view drives the screen now (first state, and the answer
//                                 to each `control` frame, with `refused` saying why when Control was asked and not let);
//                                 `switches` in the first state: the view takes `control` frames; `latency` {frame,
//                                 before} each second while frames come; `video` {capture, encoder?, hardware?} how the
//                                 pictures are made; `cursor` {x, y, shape} the pointer (0..1 of the picture, a CSS
//                                 cursor's name, `none` hidden) where the pictures leave it out; `orientation` and
//                                 `pose` how a device stands; `timing` in the first state: the station logs each
//                                 frame's times, and asks `received` frames and the `ack`'s times; `agent` whether an
//                                 agent's lease on the device lasts (after the first state, and each time it starts or
//                                 ends), and `agentPointer` {x, y, down} where that agent's finger is as it presses,
//                                 moves and lifts (0..1 of the picture): not to a preview, and a station from before
//                                 says neither.
//                                 `endedCode: "screen_refused"` with `ended` is an explicit capture refusal. The client
//                                 shows its reason without automatic reconnects. A connection loss has no code.
//   4 clipboard station → client  1 byte type (1 text in UTF-8, 2 PNG), the bytes: the screen's clipboard each time it
//                                 changes (a copy made on it), only to a view that drives it now; not what it held as
//                                 the view opened or as it took Control.
//   5 audioConfig station → client JSON {codec: "pcm_s16le" | "opus", sampleRate: 48000, channels: 2}, before the first
//                                 audio packet: only to a view that asked `audio` of a source that captures it. `opus`
//                                 only to a view that asked it; a source that encodes none says `pcm_s16le` to it too.
//   6 audio     station → client  8 bytes timestamp (µs, big-endian), then 20 ms of sound: exactly 3840 bytes, 960
//                                 stereo frames of interleaved signed little-endian PCM16; or one Opus packet (RFC 6716)
//                                 of 960 frames, at most SCREEN_OPUS_MAX bytes.
//  16 input     client → station  JSON: one input event; dropped unless the view drives the screen as it arrives.
//  17 ack       client → station  8 bytes: the timestamp of the last frame shown. What goes next goes by these. To a
//                                 view whose state said `timing`, 20 bytes more (`ScreenAckTiming`): 5 × 4 bytes µs.
//  18 keyframe  client → station  empty: the decoder lost its state, send a key frame.
//  19 control   client → station  JSON {control: boolean}: Watch (false) or Control (true) on this open view. The picture
//                                 goes on as it was: no new capture, key frame or rate. Watch holds from the next frame;
//                                 Control is checked again: the credential, access Full, that the member may drive, not
//                                 a preview, and a device still listed as the same source and instance (its boot is not
//                                 read again). A station from before lets it be, and says no `state` back.
//  21 clipboard client → station  1 byte flags (bit 0: paste it), 1 byte type (1 text, 2 PNG), the bytes: sets the
//                                 screen's clipboard and, with paste, pastes it where its focus is. Only from a view that
//                                 drives it now, of a type its listing's `clipboard` names; text at most 1 MB, a PNG 8
//                                 MB (a larger frame ends the view, as any client frame past its bound does).
//  22 received  client → station  8 bytes: the timestamp of a video frame the client has whole, at once, before its
//                                 decoder: only to a view whose state said `timing`. A station from before lets it be.
//  23 sound     client → station  1 byte, 0 or 1: the view's sound off (muted: no `audio` goes) or on again. A view
//                                 that asked `audio` starts with it on.
//
// Kinds 4, 5, 6 and the client's clipboard are still.fail's (docs/remote-screens.md there, "Wire"), with its layouts and
// bounds. Its client clipboard is kind 19, which Cue's `control` took before it came here: Cue's is 21 (still.fail's 20
// is its `look`, kept free). Kind 22 and the `ack`'s times are Cue's own.

export const SCREEN_TYPE = "application/x-comma-screen";
export const SCREEN_HEADER = "x-comma-screen";
/** The list with the computer's Android devices and what could start, which wakes its adb: only a person who looks asks. */
export const SCREEN_LIST_WITH_DEVICES = "/screens?devices=1";

/**
 * The frames' kinds (the table above). A `state` may also say `cursor` {x, y, shape}: the pointer of a screen whose
 * pictures leave it out (Windows' desktop), 0..1 of the screen, its shape a CSS cursor's name (`none`: hidden).
 */
export const ScreenKind = {
  config: 1,
  video: 2,
  state: 3,
  input: 16,
  ack: 17,
  keyframe: 18,
  control: 19,
  clipboard: 4,
  audioConfig: 5,
  audio: 6,
  setClipboard: 21,
  received: 22,
  sound: 23,
} as const;

/** The largest frame a station takes from a client: one input event at most. */
export const MAX_SCREEN_IN = 64 * 1024;
/** The largest frame a client takes from a station. */
export const MAX_SCREEN_OUT = 32 * 1024 * 1024;

/** What a screen's clipboard holds, as a view carries it: text, or a PNG picture (still.fail's source.ts `Clip`). */
export type ClipType = "text" | "png";
export type Clip = { type: "text"; text: string } | { type: "png"; data: Uint8Array };
/** The most a clipboard carries each way: text (its UTF-8 bytes), a picture. */
export const CLIP_TEXT_MAX = 1024 * 1024;
export const CLIP_PNG_MAX = 8 * 1024 * 1024;
/** A client's `clipboard` frame is its flags, its type and a picture at most. */
export const MAX_CLIP_IN = 2 + CLIP_PNG_MAX;
/** The largest frame a station takes from a client, by its kind: a clipboard's a picture's, any other one input event. */
export const screenInLimit = (kind: number): number =>
  kind === ScreenKind.setClipboard ? MAX_CLIP_IN : MAX_SCREEN_IN;

const CLIP_BYTE: Record<ClipType, number> = { text: 1, png: 2 };

/** Whether a clip is within its bounds, and not empty. */
export function clipFits(clip: Clip): boolean {
  return clip.type === "text"
    ? clip.text !== "" && new TextEncoder().encode(clip.text).length <= CLIP_TEXT_MAX
    : clip.data.length > 0 && clip.data.length <= CLIP_PNG_MAX;
}

/** A clip as a clipboard frame's payload has it after its flags (station → client: none): its type byte, its bytes. */
export function clipPayload(clip: Clip, flags?: number): Uint8Array {
  const body = clip.type === "text" ? new TextEncoder().encode(clip.text) : clip.data;
  const head =
    flags === undefined ? [CLIP_BYTE[clip.type]] : [flags, CLIP_BYTE[clip.type]];
  const out = new Uint8Array(head.length + body.length);
  out.set(head);
  out.set(body, head.length);
  return out;
}

function clipOf(type: number | undefined, body: Uint8Array): Clip | null {
  const clip: Clip | null =
    type === CLIP_BYTE.text
      ? { type: "text", text: new TextDecoder().decode(body) }
      : type === CLIP_BYTE.png
        ? { type: "png", data: body.slice() }
        : null;
  return clip !== null && clipFits(clip) ? clip : null;
}

/** A client's `clipboard` frame (kind 21): the clip, within its bounds, and whether to paste it; null when it is none. */
export function parseClip(payload: Uint8Array): { clip: Clip; paste: boolean } | null {
  if (payload.length < 3) return null;
  const clip = clipOf(payload[1], payload.subarray(2));
  return clip && { clip, paste: (payload[0]! & 1) === 1 };
}

/** A station's `clipboard` frame (kind 4): the clip, within its bounds; null when it is none. */
export function parseStationClip(payload: Uint8Array): Clip | null {
  return payload.length < 2 ? null : clipOf(payload[0], payload.subarray(1));
}

/** A client's `clipboard` frame's bytes: set the screen's clipboard, and paste it there with `paste`. */
export const encodeScreenClip = (clip: Clip, paste: boolean): Uint8Array =>
  encodeScreenFrame(ScreenKind.setClipboard, clipPayload(clip, paste ? 1 : 0));

/** The system output a view carries: its format, and one packet's PCM (20 ms of 48 kHz stereo PCM16). */
export const SCREEN_AUDIO = {
  codec: "pcm_s16le",
  sampleRate: 48000,
  channels: 2,
} as const;
export const SCREEN_AUDIO_BYTES = 3840;
/** The codecs a view's sound comes in: PCM16, or Opus (20 ms packets, about 64 kbit/s: a twentieth of PCM's). */
export type ScreenAudioCodec = "pcm_s16le" | "opus";
/** The largest Opus packet a view carries: RFC 6716's for one frame of 20 ms (1275 bytes), a little over. */
export const SCREEN_OPUS_MAX = 1500;

/** A `sound` frame's bytes: the view's sound on, or off (muted). */
export const encodeScreenSound = (on: boolean): Uint8Array =>
  encodeScreenFrame(ScreenKind.sound, new Uint8Array([on ? 1 : 0]));

/** A `sound` frame: on or off; null when it is not one byte of 0 or 1. */
export function parseScreenSound(payload: Uint8Array): boolean | null {
  return payload.length === 1 && payload[0]! <= 1 ? payload[0] === 1 : null;
}

/** An `audio` frame's bytes: the packet's capture time (µs), then its PCM. */
export function encodeScreenAudio(ts: number, data: Uint8Array): Uint8Array {
  const payload = new Uint8Array(8 + data.length);
  new DataView(payload.buffer).setBigUint64(0, BigInt(Math.max(0, Math.round(ts))));
  payload.set(data, 8);
  return encodeScreenFrame(ScreenKind.audio, payload);
}

/**
 * An `audio` frame's packet, its `data` a part of the payload's bytes; null when it is not one packet of `codec` (PCM's
 * exact size, an Opus packet of 1 to SCREEN_OPUS_MAX bytes).
 */
export function parseScreenAudio(
  payload: Uint8Array,
  codec: ScreenAudioCodec = "pcm_s16le"
): { ts: number; data: Uint8Array } | null {
  const size = payload.length - 8;
  if (
    codec === "pcm_s16le"
      ? size !== SCREEN_AUDIO_BYTES
      : size < 1 || size > SCREEN_OPUS_MAX
  )
    return null;
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  return { ts: Number(view.getBigUint64(0)), data: payload.subarray(8) };
}

/** The codec an `audioConfig` frame says, in the one rate and layout a view carries; null when it says another. */
export function parseScreenAudioConfig(payload: Uint8Array): ScreenAudioCodec | null {
  try {
    const c = JSON.parse(new TextDecoder().decode(payload)) as Record<
      string,
      unknown
    > | null;
    return (c?.codec === "pcm_s16le" || c?.codec === "opus") &&
      c.sampleRate === SCREEN_AUDIO.sampleRate &&
      c.channels === SCREEN_AUDIO.channels
      ? c.codec
      : null;
  } catch {
    return null;
  }
}

const HEAD = 5;
const VIDEO_HEAD = 9;

/** One frame's bytes. */
export function encodeScreenFrame(
  kind: number,
  payload: Uint8Array = new Uint8Array(0)
): Uint8Array {
  const out = new Uint8Array(HEAD + payload.length);
  out[0] = kind;
  new DataView(out.buffer).setUint32(1, payload.length);
  out.set(payload, HEAD);
  return out;
}

export const encodeScreenJson = (kind: number, value: unknown): Uint8Array =>
  encodeScreenFrame(kind, new TextEncoder().encode(JSON.stringify(value)));

/** A video frame's bytes (`data`: AVCC). */
export function encodeScreenVideo(
  key: boolean,
  ts: number,
  data: Uint8Array
): Uint8Array {
  const out = new Uint8Array(HEAD + VIDEO_HEAD + data.length);
  const view = new DataView(out.buffer);
  out[0] = ScreenKind.video;
  view.setUint32(1, VIDEO_HEAD + data.length);
  out[HEAD] = key ? 1 : 0;
  view.setBigUint64(HEAD + 1, BigInt(Math.max(0, Math.floor(ts))));
  out.set(data, HEAD + VIDEO_HEAD);
  return out;
}

/**
 * What a client says of an acknowledged frame's times, in ms, each on its own clock: `held` from the client's core having
 * it whole to its `ack` going (the page's hops and decoder with it); the rest from the page having it: given to the
 * decoder, out of it, handed to what shows it, acknowledged. None: not known (a frame let go never comes out).
 */
export type ScreenAckTiming = {
  held?: number;
  decodeIn?: number;
  decodeOut?: number;
  shown?: number;
  ack?: number;
};
const ACK_TIMES = ["held", "decodeIn", "decodeOut", "shown", "ack"] as const;
/** An `ack` time not known; the most one says, a little over an hour. */
const UNKNOWN = 0xffffffff;

/** An `ack` frame's bytes; with `timing`, its times after the timestamp (µs). */
export function encodeScreenAck(ts: number, timing?: ScreenAckTiming): Uint8Array {
  const payload = new Uint8Array(timing ? 8 + 4 * ACK_TIMES.length : 8);
  const view = new DataView(payload.buffer);
  view.setBigUint64(0, BigInt(Math.max(0, Math.floor(ts))));
  if (timing)
    ACK_TIMES.forEach((name, i) => {
      const ms = timing[name];
      const us =
        typeof ms === "number" && Number.isFinite(ms)
          ? Math.min(UNKNOWN - 1, Math.max(0, Math.round(ms * 1000)))
          : UNKNOWN;
      view.setUint32(8 + 4 * i, us);
    });
  return encodeScreenFrame(ScreenKind.ack, payload);
}

/** A `received` frame's bytes: the client has the frame of `ts` whole. */
export function encodeScreenReceived(ts: number): Uint8Array {
  const payload = new Uint8Array(8);
  new DataView(payload.buffer).setBigUint64(0, BigInt(Math.max(0, Math.floor(ts))));
  return encodeScreenFrame(ScreenKind.received, payload);
}

/** A `video` frame's payload, its `data` a part of the payload's bytes; null when it is too short to be one. */
export function parseScreenVideo(
  payload: Uint8Array
): { key: boolean; ts: number; data: Uint8Array } | null {
  if (payload.length < VIDEO_HEAD) return null;
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  return {
    key: (payload[0]! & 1) === 1,
    ts: Number(view.getBigUint64(1)),
    data: payload.subarray(VIDEO_HEAD),
  };
}

/** An `ack` frame's timestamp, or null when it is too short to be one. */
export function parseScreenAck(payload: Uint8Array): number | null {
  if (payload.length < 8) return null;
  return Number(
    new DataView(payload.buffer, payload.byteOffset, payload.byteLength).getBigUint64(0)
  );
}

/** An `ack` frame's times (ms), or null when it carries none (a client from before, or one not asked). */
export function parseScreenAckTiming(payload: Uint8Array): ScreenAckTiming | null {
  if (payload.length < 8 + 4 * ACK_TIMES.length) return null;
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  const timing: ScreenAckTiming = {};
  ACK_TIMES.forEach((name, i) => {
    const us = view.getUint32(8 + 4 * i);
    if (us !== UNKNOWN) timing[name] = us / 1000;
  });
  return timing;
}

/** A `received` frame's timestamp, or null when it is too short to be one. */
export const parseScreenReceived = parseScreenAck;

/** A `control` frame's bytes: Watch (false) or Control (true) on an open view. */
export const encodeScreenControl = (control: boolean): Uint8Array =>
  encodeScreenJson(ScreenKind.control, { control });

/** A `control` frame's choice, or null when it is not one. */
export function parseScreenControl(payload: Uint8Array): boolean | null {
  try {
    const value = JSON.parse(new TextDecoder().decode(payload)) as {
      control?: unknown;
    } | null;
    return typeof value?.control === "boolean" ? value.control : null;
  } catch {
    return null;
  }
}

/** The whole frames in a stream's bytes as they arrive. A frame's payload may share its bytes with the next frame's. */
export class ScreenFrameReader {
  readonly #limit: (kind: number) => number;
  #chunks: Uint8Array[] = [];
  #size = 0;

  /** `limit`: the largest frame taken, or by its kind (a station takes a client's clipboard as large as a picture). */
  constructor(limit: number | ((kind: number) => number)) {
    this.#limit = typeof limit === "number" ? () => limit : limit;
  }

  /** Bytes in: the frames they complete. Throws where a frame is larger than the limit. */
  push(chunk: Uint8Array): { kind: number; payload: Uint8Array }[] {
    this.#chunks.push(chunk);
    this.#size += chunk.length;
    const frames: { kind: number; payload: Uint8Array }[] = [];
    while (this.#size >= HEAD) {
      const head = this.#gather(HEAD);
      const length = new DataView(head.buffer, head.byteOffset, HEAD).getUint32(1);
      if (length > this.#limit(head[0]!)) throw new Error("screen frame too large");
      if (this.#size < HEAD + length) break;
      const whole = this.#gather(HEAD + length);
      frames.push({ kind: whole[0]!, payload: whole.subarray(HEAD, HEAD + length) });
      this.#chunks[0] = this.#chunks[0]!.subarray(HEAD + length);
      this.#size -= HEAD + length;
      if (this.#chunks[0]!.length === 0) this.#chunks.shift();
    }
    return frames;
  }

  /** At least `n` bytes held together in the first chunk. Large frames are joined once, when all of them came. */
  #gather(n: number): Uint8Array {
    const first = this.#chunks[0]!;
    if (first.length >= n) return first;
    const joined = new Uint8Array(this.#size);
    let at = 0;
    for (const chunk of this.#chunks) {
      joined.set(chunk, at);
      at += chunk.length;
    }
    this.#chunks = [joined];
    return joined;
  }

  /** How many bytes are held that make no whole frame yet. */
  get buffered(): number {
    return this.#size;
  }
}

/** What waits to go to a station, at most; past it frames are dropped (a later acknowledgement says what they said). */
const MAX_OUTGOING = 256;

/** A view's request body: frames as they are given, until `end`. */
export class ScreenOutgoing implements AsyncIterable<Uint8Array> {
  #queue: Uint8Array[] = [];
  #ended = false;
  #wake: () => void = () => undefined;

  push(bytes: Uint8Array): void {
    if (this.#ended || this.#queue.length >= MAX_OUTGOING) return;
    this.#queue.push(bytes);
    this.#wake();
  }

  end(): void {
    this.#ended = true;
    this.#wake();
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<Uint8Array> {
    for (;;) {
      const next = this.#queue.shift();
      if (next) yield next;
      else if (this.#ended) return;
      else await new Promise<void>((resolve) => (this.#wake = resolve));
    }
  }
}

/** What a client asks of a view (the `x-comma-screen` header). */
/**
 * One screen as `GET /screens` lists it. `id` says its kind where there are several of it (`simulator:<udid>`,
 * `android:<serial>`). A later station may add fields here and to a `state` frame; a client lets be what it does not know.
 */
export type ScreenListed = {
  id: string;
  kind: string;
  /** It can be previewed (a view's `peek`). */
  peek?: boolean;
  /** A device's: what a person calls it, what its machine calls it (an AVD's name), and its size in its pixels. */
  title?: string;
  name?: string;
  /** Hardware model, independent of the user-assigned instance name. */
  model?: string;
  /** A device's running instance: what views and closes it name (`ScreenAsk.instance`), its id being only its place. */
  instance?: string;
  width?: number;
  height?: number;
  /** What it can do beyond a picture and a pointer: none for a computer's. */
  capabilities?: Record<string, unknown>;
  /** A real phone, a person's (an emulator is not). */
  phone?: boolean;
  /** An agent's lease on it lasts now. */
  agent?: boolean;
  /** The clipboard types a view that drives it carries both ways; none: no clipboard (and none from a station before). */
  clipboard?: ClipType[];
};

/**
 * `POST /screens/start`'s body: the Android Virtual Device to start, named as `GET /screens?devices=1` said it. It answers
 * the id it will be listed as; the client takes the device listed there under that AVD's `name`, and its instance.
 * `POST /screens/<id>/close`'s body: `{instance}`, the one it means.
 */
export type ScreenStart = { avd: string };

/** The 画质 a view may ask besides 自动 (none): 流畅, 高清, 原画. */
export const SCREEN_QUALITIES = ["smooth", "hd", "original"] as const;
export type ScreenQuality = (typeof SCREEN_QUALITIES)[number];

/** A 画质 said, or undefined (自动, or not one). */
export const screenQualityOf = (value: unknown): ScreenQuality | undefined =>
  SCREEN_QUALITIES.find((quality) => quality === value);

export type ScreenAsk = {
  /** A preview (a link's card): it only looks; only of a screen the list says `peek`, else 501. */
  peek?: boolean;
  codecs: string[];
  /** Whether it drives from its start; a `control` frame changes that while it runs. */
  control: boolean;
  /**
   * The screen's system output too (never a microphone's), in this codec: `opus` takes PCM too, from a source that
   * encodes none. A source that captures it says `audioConfig` and sends `audio` frames; another lets it be. Never of
   * a preview.
   */
  audio?: ScreenAudioCodec;
  /** The apps an app view shows; none: the frontmost app. */
  apps?: string[];
  /** The picture's greatest width and height, at least 64 each: it is fitted within both. */
  maxWidth?: number;
  maxHeight?: number;
  /**
   * The 画质 chosen (still.fail's `quality`): how high the station lets the bit rate go (流畅 lower), and 原画's picture
   * is never made smaller for a slow link. None: 自动. A station from before lets it be, as 自动. Never of a preview.
   */
  quality?: ScreenQuality;
  /** `#rrggbb`: shown where the picture has no window. */
  background?: string; /**
   * The running device the client picked, as the list said it (`ScreenListed.instance`): a device's id names a place
   * another may take. Required to view a screen the list gives an instance; another is refused 409.
   */
  instance?: string;
};
