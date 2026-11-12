// The reserve a computer's sound is played with (screenAudio.ts), as still.fail's win_stream.cpp `sound_play` holds it:
// started once 100 ms are queued, a reserve that grows to cover how late packets come (at most 300 ms; a pause of a
// second is not lateness), emptied after a stall and as it runs dry, kept across a stop.
import { describe, expect, it } from "vitest";
import {
  AUDIO_PACKET_BYTES,
  ScreenAudioReserve,
  packetChannels,
  pcm16Of,
} from "../screenAudio";

/** Packets arriving at `times` (ms), each with what is queued then. */
function feed(
  reserve: ScreenAudioReserve,
  times: number[],
  queued: (i: number) => number
) {
  return times.map((at, i) => reserve.take(at, queued(i)));
}

describe("a computer's sound's reserve", () => {
  it("starts once 100 ms are queued, then plays each as it comes", () => {
    const reserve = new ScreenAudioReserve();
    const steps = feed(reserve, [0, 20, 40, 60, 80, 100], (i) => i);
    expect(steps.map((s) => s.start)).toEqual([
      false,
      false,
      false,
      false,
      true,
      false,
    ]);
    expect(steps.some((s) => s.flush)).toBe(false);
    expect(reserve.playing).toBe(true);
  });

  it("grows to cover a late packet, as long as the gap and a packet more, never past 300 ms", () => {
    const reserve = new ScreenAudioReserve();
    reserve.take(0, 0);
    // 130 ms late: 6 packets and 2 more.
    reserve.take(130, 1);
    expect(reserve.reserve).toBe(8);
    // 900 ms apart: at most 15 (300 ms).
    reserve.take(1030, 2);
    expect(reserve.reserve).toBe(15);
    // A second or more apart is the sound pausing, not lateness: as it was.
    const paused = new ScreenAudioReserve();
    paused.take(0, 0);
    paused.take(1000, 1);
    expect(paused.reserve).toBe(5);
  });

  it("runs dry while playing: emptied, and fills its reserve again before it plays", () => {
    const reserve = new ScreenAudioReserve();
    feed(reserve, [0, 20, 40, 60, 80], (i) => i);
    expect(reserve.playing).toBe(true);
    expect(reserve.take(100, 0)).toEqual({ flush: true, start: false });
    expect(reserve.playing).toBe(false);
    const again = feed(reserve, [120, 140, 160, 180], (i) => i + 1);
    expect(again.map((s) => s.start)).toEqual([false, false, false, true]);
  });

  it("after a stall (its reserve and 200 ms queued) lets what is queued go", () => {
    const reserve = new ScreenAudioReserve();
    feed(reserve, [0, 20, 40, 60, 80], (i) => i);
    expect(reserve.take(100, 15)).toEqual({ flush: true, start: false });
    expect(reserve.take(120, 14).flush).toBe(false);
  });

  it("stopped (muted, opened again): plays only once its reserve is queued again, the reserve kept", () => {
    const reserve = new ScreenAudioReserve();
    reserve.take(0, 0);
    reserve.take(130, 1);
    feed(reserve, [150, 170, 190, 210, 230, 250], (i) => i + 2);
    expect(reserve.playing).toBe(true);
    reserve.stop();
    expect(reserve.playing).toBe(false);
    // Long after: not lateness; the reserve as it grew.
    const steps = feed(
      reserve,
      [10_000, 10_020, 10_040, 10_060, 10_080, 10_100, 10_120, 10_140],
      (i) => i
    );
    expect(steps.findIndex((s) => s.start)).toBe(7);
    expect(reserve.reserve).toBe(8);
  });

  it("reads a packet's interleaved little-endian PCM16 as two channels", () => {
    const data = new Uint8Array(AUDIO_PACKET_BYTES);
    const view = new DataView(data.buffer);
    view.setInt16(0, 16384, true);
    view.setInt16(2, -32768, true);
    view.setInt16(AUDIO_PACKET_BYTES - 2, 32767, true);
    const [left, right] = packetChannels(data);
    expect([left.length, right.length]).toEqual([960, 960]);
    expect([left[0], right[0]]).toEqual([0.5, -1]);
    expect(right[959]).toBeCloseTo(32767 / 32768);
  });
});

describe("a decoded Opus packet made PCM16", () => {
  it("is read as f32-planar, the one format every page converts to, and interleaved", () => {
    const left = [0, 0.5, -1, 2];
    const right = [1, -0.5, 0.25, -2];
    // As a page that converts only to f32-planar would.
    const audio = {
      numberOfFrames: 4,
      numberOfChannels: 2,
      copyTo(into: Float32Array, options: { planeIndex: number; format?: string }) {
        if (options.format !== "f32-planar")
          throw new Error(`no conversion to ${options.format}`);
        into.set(options.planeIndex === 0 ? left : right);
      },
    } as unknown as AudioData;
    const pcm = new Uint8Array(4 * 2 * 2);
    pcm16Of(audio, pcm);
    const view = new DataView(pcm.buffer);
    const samples = Array.from({ length: 8 }, (_, i) => view.getInt16(i * 2, true));
    expect(samples).toEqual([0, 32767, 16384, -16383, -32767, 8192, 32767, -32767]);
  });
});
