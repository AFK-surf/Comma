import type { ScreenViewEvent } from "@comma/core/contract";
import type { VirtualUiClock } from "@comma/ui/clock/virtual";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { ScreenViewMessage } from "../meshScreenStream";

// A page's decoders, as on a Windows GPU whose hardware decoder fails (its GPU process crashes) after a few configures.
// What the page decodes and in what way, as VideoDecoder.isConfigSupported answers.
let supported: (config: VideoDecoderConfig) => boolean;
let decoders: FakeDecoder[];
// Decoders whose configure() throws, and whether every decode() throws.
let configureThrows: (config: VideoDecoderConfig) => boolean;
let decodeThrows: boolean;

class FakeDecoder {
  state: CodecState = "unconfigured";
  config: VideoDecoderConfig | undefined;
  chunks: { type: string; timestamp: number }[] = [];
  throwOnDecode = false;
  constructor(private readonly init: VideoDecoderInit) {
    decoders.push(this);
  }
  static isConfigSupported(config: VideoDecoderConfig) {
    return Promise.resolve({ supported: supported(config), config });
  }
  configure(config: VideoDecoderConfig) {
    if (configureThrows(config))
      throw new DOMException("no such decoder", "NotSupportedError");
    this.config = config;
    this.state = "configured";
  }
  decode(chunk: { type: string; timestamp: number }) {
    if (this.throwOnDecode || decodeThrows)
      throw new DOMException("not a frame", "DataError");
    this.chunks.push(chunk);
  }
  close() {
    this.state = "closed";
  }
  /** A frame of its out. */
  output(timestamp: number) {
    const frame = { timestamp, clone: () => frame, close: () => undefined };
    this.init.output(frame as unknown as VideoFrame);
  }
  /** The GPU process gone: the decoder closes and says why. */
  fail() {
    this.state = "closed";
    this.init.error(new DOMException("Decoding error.", "EncodingError"));
  }
}

const softwareH265 = (config: VideoDecoderConfig) =>
  !(
    config.codec.startsWith("hvc1") && config.hardwareAcceleration === "prefer-software"
  );

const H264 = "AULACv/hABVnQsAK2hHsBEAAAAMAQAAADyPEiagBAARozg/I";
// An hvcC's first 13 bytes: Main profile, level 4.0.
const H265 = btoa(String.fromCharCode(1, 1, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 120));

let clock: VirtualUiClock;
let restoreClock: () => void;
let mesh: typeof import("../meshScreenStream");

beforeEach(async () => {
  supported = () => true;
  decoders = [];
  configureThrows = () => false;
  decodeThrows = false;
  Object.assign(globalThis, {
    VideoDecoder: FakeDecoder,
    EncodedVideoChunk: class {
      readonly type: string;
      readonly timestamp: number;
      constructor(init: { type: string; timestamp: number }) {
        this.type = init.type;
        this.timestamp = init.timestamp;
      }
    },
    MediaStream: class {
      constructor(readonly tracks: unknown[]) {}
    },
    MediaStreamTrackGenerator: class {
      writable = {
        getWriter: () => ({
          write: (frame: VideoFrame) => (frame.close(), Promise.resolve()),
          close: () => Promise.resolve(),
        }),
      };
    },
  });
  // What a page remembers of its decoders starts anew with each test's page.
  vi.resetModules();
  const { installUiClock } = await import("@comma/ui/clock");
  const { createVirtualUiClock } = await import("@comma/ui/clock/virtual");
  clock = createVirtualUiClock();
  restoreClock = installUiClock(clock);
  mesh = await import("../meshScreenStream");
});

afterEach(() => restoreClock());

// Every promise the stream waits on here settles within these turns: nothing waits on real time.
const settle = async () => {
  for (let turn = 0; turn < 50; turn++) await Promise.resolve();
};

/** A stream of a station's views: each view opened, what the page said to it, and how it ended. */
function streaming() {
  const views: {
    codecs: readonly string[];
    emit: (event: ScreenViewEvent) => void;
    reject: (error: Error) => void;
  }[] = [];
  const said: ScreenViewMessage[] = [];
  const failures: string[] = [];
  const states: string[] = [];
  const peer = mesh.openMeshScreenStream({
    open: (onEvent, signal, codecs) =>
      new Promise((_resolve, reject) => {
        views.push({ codecs, emit: onEvent, reject });
        signal.addEventListener("abort", () =>
          reject(Object.assign(new Error("cancelled"), { code: "cancelled" }))
        );
      }),
    send: (_view, message) => said.push(message),
    onStream: () => undefined,
    onState: (state) => states.push(state),
    onFailure: (message) => failures.push(message),
    onUnavailable: () => expect.unreachable("this page decodes"),
  });
  const view = () => views.at(-1)!;
  return {
    peer,
    views,
    said,
    failures,
    states,
    /** The latest view opens with its config. */
    async opens(codec = "h264", description = H264) {
      await settle();
      view().emit({ type: "open", view: views.length });
      view().emit({ type: "config", codec, width: 64, height: 48, description });
    },
    frame(ts: number, key = false) {
      view().emit({ type: "video", key, ts, data: new Uint8Array([0, 0, 0, 1]) });
    },
  };
}

const decoder = () => decoders.at(-1)!;
const keyframes = (said: ScreenViewMessage[]) =>
  said.filter((message) => "keyframe" in message).length;

it("goes on in software, on the same view, when the hardware decoder fails mid-stream", async () => {
  const stream = streaming();
  await stream.opens();
  stream.frame(1000, true);
  decoder().output(1000);
  stream.frame(2000);
  expect(decoder().config?.hardwareAcceleration).toBeUndefined();

  decoder().fail();
  await settle();
  expect(decoders).toHaveLength(2);
  expect(decoder().config).toMatchObject({
    codec: "avc1.42c00a",
    hardwareAcceleration: "prefer-software",
  });
  expect(keyframes(stream.said)).toBe(1);
  // Until the key frame it asked for, a frame is let go, and acknowledged so that the station does not wait for it.
  stream.frame(3000);
  expect(decoder().chunks).toEqual([]);
  expect(stream.said.at(-1)).toEqual({ ack: 3000 });
  stream.frame(4000, true);
  decoder().output(4000);
  expect(decoder().chunks).toMatchObject([{ type: "key", timestamp: 4000 }]);

  expect(stream.views).toHaveLength(1);
  expect(stream.failures).toEqual([]);
  expect(stream.states).toEqual(["live"]);
  stream.peer.close();
});

it("decodes in software from the start, on this page, once a hardware decoder failed", async () => {
  const first = streaming();
  await first.opens();
  decoder().fail();
  await settle();
  first.peer.close();

  const later = streaming();
  await later.opens();
  expect(decoder().config?.hardwareAcceleration).toBe("prefer-software");
  later.peer.close();
});

it("opens the view again for H.264 when H.265's hardware decoder fails and there is no software one", async () => {
  supported = softwareH265;
  const stream = streaming();
  await stream.opens("h265", H265);
  expect(stream.views[0]!.codecs).toEqual(["h265", "h264"]);
  stream.frame(1000, true);
  decoder().output(1000);

  decoder().fail();
  await settle();
  await settle();
  expect(stream.views).toHaveLength(2);
  expect(stream.views[1]!.codecs).toEqual(["h264"]);
  await stream.opens();
  expect(decoder().config?.codec).toBe("avc1.42c00a");
  expect(stream.failures).toEqual([]);
  stream.peer.close();

  // Nor does a later view of this page ask for H.265.
  const later = streaming();
  await settle();
  expect(later.views[0]!.codecs).toEqual(["h264"]);
  later.peer.close();
});

it("starts the decoder anew, and asks for a key frame, when it does not take a frame", async () => {
  const stream = streaming();
  await stream.opens();
  stream.frame(1000, true);
  decoder().throwOnDecode = true;
  stream.frame(2000);
  await settle();
  expect(decoders).toHaveLength(2);
  expect(decoders[0]!.state).toBe("closed");
  expect(decoder().config?.hardwareAcceleration).toBe("prefer-software");
  // Both frames let go (the one not taken, the one inside the old decoder), then the key frame asked for.
  expect(stream.said).toEqual([{ ack: 2000 }, { ack: 1000 }, { keyframe: true }]);
  stream.peer.close();
});

it("lets the older of two frames in the decoder go, so that the station does not wait for it", async () => {
  const stream = streaming();
  await stream.opens();
  stream.frame(1000, true);
  expect(stream.said).toEqual([]);
  stream.frame(2000);
  expect(stream.said).toEqual([{ ack: 1000 }]);
  // An output of an older decoder is not shown.
  const old = decoder();
  await stream.opens();
  old.output(2000);
  expect(stream.states).toEqual([]);
  stream.peer.close();
});

it("says with each acknowledgement the times its frame went by, where the station asked them", async () => {
  const stream = streaming();
  await stream.opens();
  // Before the state asks: an acknowledgement alone.
  stream.frame(1000, true);
  decoder().output(1000);
  expect(stream.said).toEqual([{ ack: 1000 }]);

  stream.views[0]!.emit({ type: "state", state: { control: false, timing: true } });
  stream.frame(2000);
  clock.advance(16);
  decoder().output(2000);
  expect(stream.said.at(-1)).toEqual({
    ack: 2000,
    timing: { decodeIn: 0, decodeOut: 16, shown: 16, ack: 16 },
  });
  // One let go (two inside): given to the decoder, never out of it.
  stream.frame(3000);
  clock.advance(5);
  stream.frame(4000);
  expect(stream.said.at(-1)).toEqual({ ack: 3000, timing: { decodeIn: 0, ack: 5 } });
  stream.peer.close();
});

it("fails, after a bounded number of new decoders and views, when software decoding fails too", async () => {
  const stream = streaming();
  for (let round = 0; round < 20 && stream.failures.length === 0; round++) {
    await stream.opens();
    stream.frame(1000 * round, true);
    decoder().fail();
    await settle();
    if (decoder().state === "configured") continue;
    // The view was opened again after a wait.
    clock.advance(10_000);
    await settle();
  }
  expect(stream.failures).toEqual(["Decoding error."]);
  expect(stream.views.length).toBeLessThanOrEqual(1 + 5);
  expect(decoders.length).toBeLessThan(20);
  stream.peer.close();
});

/** Plays key frames to `stream`'s views until it fails or `rounds` went, each view opened again after its wait. */
async function failingUntilFailed(
  stream: ReturnType<typeof streaming>,
  rounds: number
) {
  await stream.opens();
  for (let round = 0; round < rounds && stream.failures.length === 0; round++) {
    stream.frame(1000 * (round + 1), true);
    await settle();
    if (decoder().state === "configured") continue;
    const opened = stream.views.length;
    clock.advance(10_000);
    await settle();
    if (stream.views.length > opened) await stream.opens();
  }
}

it("stays bounded when every frame throws from decode(): new decoders, then views, then a failure", async () => {
  decodeThrows = true;
  const stream = streaming();
  await failingUntilFailed(stream, 30);
  expect(stream.failures).toEqual(["not a frame"]);
  expect(decoders.length).toBeLessThan(15);
  expect(keyframes(stream.said)).toBeLessThan(5);
  expect(stream.views.length).toBeLessThanOrEqual(1 + 5);
  stream.peer.close();
});

it("goes on in software when a hardware decoder cannot be configured", async () => {
  configureThrows = (config) => config.hardwareAcceleration !== "prefer-software";
  const stream = streaming();
  await stream.opens();
  await settle();
  expect(decoder().config).toMatchObject({
    hardwareAcceleration: "prefer-software",
    codedWidth: 64,
    codedHeight: 48,
  });
  expect(keyframes(stream.said)).toBe(1);
  stream.frame(1000, true);
  expect(decoder().chunks).toMatchObject([{ type: "key", timestamp: 1000 }]);
  expect(stream.failures).toEqual([]);
  stream.peer.close();
});

it("stays bounded when no decoder can be configured", async () => {
  configureThrows = () => true;
  const stream = streaming();
  await failingUntilFailed(stream, 30);
  expect(stream.failures).toEqual(["no such decoder"]);
  expect(decoders.length).toBeLessThan(15);
  stream.peer.close();
});

it("opens the view again for H.264 when H.265 cannot be configured", async () => {
  configureThrows = (config) => config.codec.startsWith("hvc1");
  const stream = streaming();
  await stream.opens("h265", H265);
  await settle();
  expect(stream.views.map((view) => view.codecs)).toEqual([["h265", "h264"], ["h264"]]);
  expect(stream.failures).toEqual([]);
  stream.peer.close();
});

it("opens the view again for H.264 when H.265 holds frames back on a still screen", async () => {
  const stream = streaming();
  await stream.opens("h265", H265);
  stream.frame(1000, true);
  // The first frame stays in the decoder: the screen is still, nothing comes after it.
  clock.advance(500);
  decoder().output(1000);
  stream.frame(2000);
  clock.advance(500);
  await settle();
  expect(stream.views.map((view) => view.codecs)).toEqual([["h265", "h264"], ["h264"]]);
  stream.peer.close();
});

it("closes a view's decoder when the view ends, and hears nothing more from it", async () => {
  const stream = streaming();
  await stream.opens();
  stream.frame(1000, true);
  decoder().output(1000);
  const old = decoder();
  stream.views[0]!.reject(
    Object.assign(new Error("connection lost"), { code: "unreachable" })
  );
  await settle();
  expect(old.state).toBe("closed");
  old.output(2000);
  expect(
    stream.said.filter((message) => "ack" in message && message.ack === 2000)
  ).toEqual([]);
  stream.peer.close();
});
