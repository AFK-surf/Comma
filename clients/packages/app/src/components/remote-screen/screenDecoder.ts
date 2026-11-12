import { uiClock } from "@comma/ui/clock";

// How long a decoder has to say: one that does not say holds no screen up.
const DECODER_CHECK_MS = 2000;
// Decoders that fail one after another, no frame shown between: at the last of these the view is opened again.
const DECODER_FAILURES = 3;

// The codecs whose hardware decoder failed on this page. A GPU process that crashed on one (D3D11 device removed, on
// some Windows GPUs) crashes again, so their later decoders on this page decode in software.
const softwareFor = new Set<string>();
// Its hardware decoder failed and this page has no software one, or it failed or held frames back before it showed
// one: no later view of this page asks for H.265.
let h265Failed = false;

// After still.fail's web/src/screen/frames.ts (HELD_MS, HELD_TO_FALL_BACK): a frame not out of the decoder this long,
// with no frame given to it after (the screen still), is held back until the next comes (some H.265 decoders keep
// one), so every change on the screen shows a step late. H.265 held back this many times in a view's first frames is
// not asked for again, and the view is opened again for H.264.
const HELD_MS = 500;
const HELD_TO_FALL_BACK = 2;
const FIRST_FRAMES = 120;

/** The codecs of `codecs` this page still asks a view for. */
export function askedCodecs(codecs: readonly string[]): string[] {
  return codecs.filter((codec) => codec !== "h265" || !h265Failed);
}

/** Whether this page has a decoder for `config` (a decoder that does not say within its time does not). */
export async function supports(config: VideoDecoderConfig): Promise<boolean> {
  const asked = await new Promise<{ supported?: boolean } | null>((resolve) => {
    const cancel = uiClock.after(DECODER_CHECK_MS, () => resolve(null));
    void VideoDecoder.isConfigSupported(config)
      .then(
        (answer) => answer,
        () => null
      )
      .then((answer) => {
        cancel();
        resolve(answer);
      });
  });
  return asked?.supported === true;
}

/** A view's decoder, made anew when it fails, as long as that can help. */
export type ScreenDecoder = {
  /** A config of the view's: the next frame after it is a key frame. */
  configure(config: {
    codec: string;
    description: string;
    width: number;
    height: number;
  }): void;
  decode(frame: { key: boolean; ts: number; data: Uint8Array }): void;
  /** The view ended: its decoder goes, and nothing it had inside is heard from. */
  reset(): void;
};

/**
 * A view's H.264 or H.265 decoder, after still.fail's apps/mbui/mbui/web/host.js (startDecoder, stopDecoder,
 * streamFrame) and web/src/screen/frames.ts (ScreenFrames, which its main view and its cards share). A decoder that fails, whether it says so, throws from `decode()` or cannot be configured, is closed and
 * made anew from the view's last config, from the next key frame, and the view is asked for one; frames before that
 * key frame are let go; what an older decoder outputs or says is not heard.
 *
 * A frame let go (`letGo`) is acknowledged to the station as host.js's "d" is (its app acknowledges it as one shown):
 * the acknowledgement means processed or dropped, not displayed. The station paces its next frames by them, so a frame
 * the page will not show must not hold it up.
 *
 * As frames.ts: H.265 that fails, cannot be configured or holds frames back before it showed a frame is not asked for
 * again on this page, and the view is opened again (`reopen` at once) for H.264.
 *
 * On top of still.fail: a hardware decoder that failed is not used again on this page (its codec decodes in software from
 * then); H.265 where this page has no software decoder is not asked for again (`reopen` at once, for H.264); and at the
 * DECODER_FAILURES-th failure in a row, no frame shown between, `reopen` after a wait.
 */
export function createScreenDecoder(on: {
  /** A frame decoded: the caller shows and acknowledges it, and closes it. */
  frame(frame: VideoFrame): void;
  letGo(ts: number): void;
  /** A frame given to the decoder (the frames' times a station logs). */
  decoding?(ts: number): void;
  keyframe(): void;
  /** The view should be opened again: at once (with the codecs `askedCodecs` gives), or after a wait. */
  reopen(message: string, now: boolean): void;
}): ScreenDecoder {
  let decoder: VideoDecoder | undefined;
  // Each decoder's: what an older one outputs or says is not heard.
  let gen = 0;
  let config:
    | { codec: string; description: string; width: number; height: number }
    | undefined;
  let needKey = true;
  // The timestamps of the frames in the decoder.
  let inside: number[] = [];
  let failures = 0;
  let inSoftware = false;
  // A frame came out of a decoder of this view's; frames given to its decoders; how often one was held back.
  let played = false;
  let decoded = 0;
  let held = 0;

  // H.265 that cannot play here: H.264 instead, in a view opened again.
  const h265Instead = (message: string) => {
    h265Failed = true;
    stop();
    on.reopen(message, true);
  };

  const stop = () => {
    if (decoder && decoder.state !== "closed") decoder.close();
    decoder = undefined;
    gen++;
    if (inside.length > 0) on.letGo(Math.max(...inside));
    inside = [];
    needKey = true;
  };

  // The decoder for the config there is (none without one).
  const start = () => {
    stop();
    if (!config) return;
    const mine = ++gen;
    const { codec, description, width, height } = config;
    inSoftware = softwareFor.has(codec);
    const software = inSoftware;
    try {
      decoder = new VideoDecoder({
        output: (frame) => {
          if (mine !== gen) {
            frame.close();
            return;
          }
          while (inside.length > 0 && inside[0]! <= frame.timestamp) inside.shift();
          failures = 0;
          played = true;
          on.frame(frame);
        },
        error: (error) => {
          if (mine === gen) void failed(error.message, software);
        },
      });
      decoder.configure({
        ...decoderConfig(description, codec),
        // (host.js's streamH264)
        codedWidth: width,
        codedHeight: height,
        ...(software ? { hardwareAcceleration: "prefer-software" as const } : {}),
      });
    } catch (error) {
      void failed(error instanceof Error ? error.message : String(error), software);
    }
  };

  const failed = async (message: string, software: boolean) => {
    if (config?.codec === "h265" && !played) {
      h265Instead(message);
      return;
    }
    stop();
    if (++failures >= DECODER_FAILURES) {
      on.reopen(message, false);
      return;
    }
    if (!software && config) {
      const { codec, description } = config;
      softwareFor.add(codec);
      const mine = gen;
      const hasSoftware = await supports({
        ...decoderConfig(description, codec),
        hardwareAcceleration: "prefer-software",
      });
      // (a config, or the view's end, came meanwhile: a decoder made since is already in software)
      if (mine !== gen) return;
      if (!hasSoftware) {
        softwareFor.delete(codec);
        if (codec === "h265") h265Failed = true;
        on.reopen(message, codec === "h265");
        return;
      }
    }
    start();
    if (decoder) on.keyframe();
  };

  return {
    configure(next) {
      config = {
        codec: next.codec,
        description: next.description,
        width: next.width,
        height: next.height,
      };
      start();
    },
    decode({ key, ts, data }) {
      if (!decoder || (needKey && !key)) {
        on.letGo(ts);
        return;
      }
      needKey = false;
      inside.push(ts);
      try {
        decoder.decode(
          new EncodedVideoChunk({ type: key ? "key" : "delta", timestamp: ts, data })
        );
      } catch (error) {
        inside = inside.filter((at) => at !== ts);
        on.letGo(ts);
        void failed(error instanceof Error ? error.message : String(error), inSoftware);
        return;
      }
      decoded++;
      on.decoding?.(ts);
      const mine = gen;
      uiClock.after(HELD_MS, () => {
        if (mine !== gen || !inside.includes(ts) || inside.some((at) => at > ts))
          return;
        held++;
        if (
          config?.codec === "h265" &&
          held >= HELD_TO_FALL_BACK &&
          decoded <= FIRST_FRAMES
        )
          h265Instead("The H.265 decoder holds frames back.");
      });
      // A decoder that holds frames back would wait for more while the station waits: with two inside, the older is
      // let go.
      if (inside.length >= 2) on.letGo(inside.shift()!);
    },
    reset() {
      stop();
      played = false;
      decoded = 0;
      held = 0;
    },
  };
}

const bytesOf = (base64: string) =>
  Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));

const hex = (byte: number | undefined) => (byte ?? 0).toString(16).padStart(2, "0");

/** What a decoder of a view's frames is told, from its config: H.264's avcC, or H.265's hvcC. */
export function decoderConfig(description: string, codec = "h264"): VideoDecoderConfig {
  const bytes = bytesOf(description);
  return { codec: codecOf(codec, bytes), description: bytes, optimizeForLatency: true };
}

/** What WebCodecs calls the stream a station's config describes, from its avcC or hvcC. */
export function codecOf(codec: string, description: Uint8Array): string {
  return codec === "h265" ? hevcCodec(description) : avcCodec(description);
}

/** `avc1.` and an avcC's profile, compatibility and level bytes. */
function avcCodec(avcC: Uint8Array): string {
  return `avc1.${hex(avcC[1])}${hex(avcC[2])}${hex(avcC[3])}`;
}

/**
 * ISO 14496-15's name of an hvcC: `hvc1.`, the profile's space and number, its compatibility flags with their bits
 * reversed, its tier and level, and its constraint bytes less the trailing zeros.
 */
function hevcCodec(hvcC: Uint8Array): string {
  const first = hvcC[1] ?? 0;
  const space = ["", "A", "B", "C"][first >> 6];
  const flags = new DataView(hvcC.buffer, hvcC.byteOffset + 2, 4).getUint32(0);
  let reversed = 0;
  for (let bit = 0; bit < 32; bit++) reversed = reversed * 2 + ((flags >>> bit) & 1);
  const constraints = [...hvcC.subarray(6, 12)];
  while (constraints.at(-1) === 0) constraints.pop();
  return [
    `hvc1.${space}${first & 0x1f}`,
    reversed.toString(16),
    `${first & 0x20 ? "H" : "L"}${hvcC[12] ?? 0}`,
    ...constraints.map((byte) => byte.toString(16).toUpperCase()),
  ].join(".");
}
