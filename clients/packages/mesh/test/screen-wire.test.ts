import { describe, expect, it } from "vitest";
import {
  CLIP_PNG_MAX,
  CLIP_TEXT_MAX,
  MAX_CLIP_IN,
  MAX_SCREEN_IN,
  SCREEN_AUDIO,
  SCREEN_AUDIO_BYTES,
  SCREEN_OPUS_MAX,
  encodeScreenSound,
  parseScreenSound,
  clipFits,
  clipPayload,
  encodeScreenAudio,
  encodeScreenClip,
  parseClip,
  parseScreenAudio,
  parseScreenAudioConfig,
  parseStationClip,
  screenInLimit,
  screenQualityOf,
  ScreenFrameReader,
  ScreenKind,
  encodeScreenAck,
  encodeScreenFrame,
  encodeScreenJson,
  encodeScreenReceived,
  encodeScreenVideo,
  parseScreenAck,
  parseScreenAckTiming,
  parseScreenReceived,
  parseScreenVideo,
} from "../src/index.ts";

const text = (bytes: Uint8Array) => new TextDecoder().decode(bytes);

describe("a screen's frames", () => {
  it("come whole however the stream cuts them", () => {
    const bytes = [
      encodeScreenJson(ScreenKind.state, { control: true }),
      encodeScreenVideo(true, 2 ** 40, new Uint8Array(70_000).fill(7)),
      encodeScreenFrame(ScreenKind.keyframe),
      encodeScreenAck(2 ** 40),
    ].reduce((all, next) => new Uint8Array([...all, ...next]), new Uint8Array(0));
    for (const cut of [1, 3, 5, 6, 4096, 65_536, bytes.length]) {
      const reader = new ScreenFrameReader(1 << 20);
      const frames = [];
      for (let at = 0; at < bytes.length; at += cut)
        frames.push(...reader.push(bytes.subarray(at, at + cut)));
      expect(frames.map((f) => f.kind)).toEqual([
        ScreenKind.state,
        ScreenKind.video,
        ScreenKind.keyframe,
        ScreenKind.ack,
      ]);
      expect(reader.buffered).toBe(0);
      expect(JSON.parse(text(frames[0]!.payload))).toEqual({ control: true });
      const video = parseScreenVideo(frames[1]!.payload)!;
      expect(video.key).toBe(true);
      expect(video.ts).toBe(2 ** 40);
      expect(video.data.length).toBe(70_000);
      expect(video.data.every((byte) => byte === 7)).toBe(true);
      expect(frames[2]!.payload.length).toBe(0);
      expect(parseScreenAck(frames[3]!.payload)).toBe(2 ** 40);
    }
  });

  it("says a delta frame as such, and takes a frame too short for what it says as none", () => {
    const delta = encodeScreenVideo(false, 5, new Uint8Array([1]));
    const reader = new ScreenFrameReader(100);
    expect(parseScreenVideo(reader.push(delta)[0]!.payload)?.key).toBe(false);
    expect(parseScreenVideo(new Uint8Array(8))).toBeNull();
    expect(parseScreenAck(new Uint8Array(7))).toBeNull();
  });

  it("carries an ack's times to a station that reads them, and its timestamp alone to one from before", () => {
    const [ack] = new ScreenFrameReader(100).push(
      encodeScreenAck(2 ** 40, { held: 21.5, decodeIn: 0.25, decodeOut: 18, ack: 18.1 })
    );
    // A station from before reads the first 8 bytes.
    expect(parseScreenAck(ack!.payload)).toBe(2 ** 40);
    // (`shown` not known: a frame let go)
    expect(parseScreenAckTiming(ack!.payload)).toEqual({
      held: 21.5,
      decodeIn: 0.25,
      decodeOut: 18,
      ack: 18.1,
    });
    // A client from before: no times.
    expect(parseScreenAckTiming(encodeScreenAck(5).subarray(5))).toBeNull();
    const [received] = new ScreenFrameReader(100).push(encodeScreenReceived(7));
    expect(received!.kind).toBe(ScreenKind.received);
    expect(parseScreenReceived(received!.payload)).toBe(7);
  });

  it("refuses a frame over its limit by its head, before its bytes", () => {
    const reader = new ScreenFrameReader(MAX_SCREEN_IN);
    const head = encodeScreenFrame(ScreenKind.input, new Uint8Array(MAX_SCREEN_IN + 1));
    expect(() => reader.push(head.subarray(0, 5))).toThrow("too large");
  });
});

// still.fail's client/core-ts/test/screens.test.ts ("screen_audio_packets_survive_fragmentation_and_validate_the_format")
// and station/test/screens.test.ts ("the clipboard's bounds and types"), on Cue's frames.
describe("a screen's clipboard and sound", () => {
  it("audio packets come whole however the stream cuts them, and only exact ones are packets", () => {
    const config = encodeScreenJson(ScreenKind.audioConfig, SCREEN_AUDIO);
    const pcm = new Uint8Array(SCREEN_AUDIO_BYTES).map((_, i) => i % 251);
    const bytes = new Uint8Array([...config, ...encodeScreenAudio(123_456_789, pcm)]);
    for (const cut of [1, 7, 512, bytes.length]) {
      const reader = new ScreenFrameReader(1 << 20);
      const frames = [];
      for (let at = 0; at < bytes.length; at += cut)
        frames.push(...reader.push(bytes.subarray(at, at + cut)));
      expect(frames.map((f) => f.kind)).toEqual([
        ScreenKind.audioConfig,
        ScreenKind.audio,
      ]);
      expect(parseScreenAudioConfig(frames[0]!.payload)).toBe("pcm_s16le");
      const packet = parseScreenAudio(frames[1]!.payload)!;
      expect(packet.ts).toBe(123_456_789);
      expect([...packet.data]).toEqual([...pcm]);
    }
    expect(parseScreenAudio(new Uint8Array(12))).toBeNull();
    expect(parseScreenAudio(new Uint8Array(8 + SCREEN_AUDIO_BYTES + 1))).toBeNull();
    const other = new TextEncoder().encode(
      JSON.stringify({ ...SCREEN_AUDIO, sampleRate: 44100 })
    );
    expect(parseScreenAudioConfig(other)).toBeNull();
  });

  it("Opus: its config says it, a packet is 1 to SCREEN_OPUS_MAX bytes, and a view's sound goes off and on", () => {
    const config = new TextEncoder().encode(
      JSON.stringify({ ...SCREEN_AUDIO, codec: "opus" })
    );
    expect(parseScreenAudioConfig(config)).toBe("opus");
    const packet = parseScreenAudio(
      encodeScreenAudio(42, new Uint8Array(190).fill(7)).subarray(5),
      "opus"
    )!;
    expect([packet.ts, packet.data.length]).toEqual([42, 190]);
    expect(parseScreenAudio(new Uint8Array(8), "opus")).toBeNull();
    expect(
      parseScreenAudio(new Uint8Array(8 + SCREEN_OPUS_MAX + 1), "opus")
    ).toBeNull();
    // PCM's exact size is the only PCM packet.
    expect(parseScreenAudio(new Uint8Array(8 + 190))).toBeNull();
    const off = new ScreenFrameReader(16).push(encodeScreenSound(false))[0]!;
    expect([off.kind, parseScreenSound(off.payload)]).toEqual([
      ScreenKind.sound,
      false,
    ]);
    expect(parseScreenSound(new Uint8Array([1]))).toBe(true);
    expect(parseScreenSound(new Uint8Array([2]))).toBeNull();
  });

  it("a clip within its bounds is one; past them, empty or of no type, none", () => {
    const sent = encodeScreenClip({ type: "text", text: "粘贴的" }, true);
    const [frame] = new ScreenFrameReader(screenInLimit).push(sent);
    expect(frame!.kind).toBe(ScreenKind.setClipboard);
    expect(parseClip(frame!.payload)).toEqual({
      clip: { type: "text", text: "粘贴的" },
      paste: true,
    });
    const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
    expect(parseClip(clipPayload({ type: "png", data: png }, 0))).toEqual({
      clip: { type: "png", data: png },
      paste: false,
    });
    expect(parseStationClip(clipPayload({ type: "text", text: "复制的" }))).toEqual({
      type: "text",
      text: "复制的",
    });
    expect(
      parseClip(new Uint8Array([0, 2, ...new Uint8Array(CLIP_PNG_MAX)]))
    ).not.toBeNull();
    expect(
      parseClip(new Uint8Array([0, 2, ...new Uint8Array(CLIP_PNG_MAX + 1)]))
    ).toBeNull();
    expect(
      parseClip(new Uint8Array([1, 1, ...new Uint8Array(CLIP_TEXT_MAX + 1).fill(0x61)]))
    ).toBeNull();
    expect(parseClip(new Uint8Array([1, 9, 0x78]))).toBeNull();
    expect(parseClip(new Uint8Array([1, 1]))).toBeNull();
    expect(clipFits({ type: "text", text: "" })).toBe(false);
  });

  it("a client's clipboard frame may be a picture's size, any other frame one input event's", () => {
    expect(MAX_CLIP_IN).toBe(2 + CLIP_PNG_MAX);
    expect(screenInLimit(ScreenKind.input)).toBe(MAX_SCREEN_IN);
    const reader = new ScreenFrameReader(screenInLimit);
    const big = encodeScreenFrame(ScreenKind.setClipboard, new Uint8Array(0)).slice(
      0,
      5
    );
    new DataView(big.buffer).setUint32(1, MAX_SCREEN_IN + 1);
    expect(() => reader.push(big)).not.toThrow();
    const past = new Uint8Array(5);
    past[0] = ScreenKind.setClipboard;
    new DataView(past.buffer).setUint32(1, MAX_CLIP_IN + 1);
    expect(() => new ScreenFrameReader(screenInLimit).push(past)).toThrow("too large");
  });
});

describe("a view's 画质", () => {
  it("is one of 流畅, 高清 and 原画; anything else is 自动 (none)", () => {
    expect(["smooth", "hd", "original"].map(screenQualityOf)).toEqual([
      "smooth",
      "hd",
      "original",
    ]);
    for (const other of [undefined, null, "auto", "best", "HD", 3, {}])
      expect(screenQualityOf(other)).toBeUndefined();
  });
});
