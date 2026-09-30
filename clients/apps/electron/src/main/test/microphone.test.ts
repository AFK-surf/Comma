import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { afterEach, describe, expect, it, vi } from "vitest";

import {
  HelperMicrophoneCapture,
  Int16FrameDecoder,
  MicrophoneDeniedError,
  type MicrophoneHostProcess,
} from "../modules/audio-capture/microphone";
import { mixMono } from "../modules/audio-capture/mix";

class FakeHost extends EventEmitter implements MicrophoneHostProcess {
  exitCode: number | null = null;
  killed = false;
  stderr = new PassThrough();
  stdin = new PassThrough();
  stdout = new PassThrough();
  signals: string[] = [];
  stdinEnded = false;

  constructor() {
    super();
    this.stdin.on("finish", () => {
      this.stdinEnded = true;
    });
  }

  kill(signal?: NodeJS.Signals) {
    this.signals.push(signal ?? "SIGTERM");
    this.killed = true;
    return true;
  }

  ready(sampleRate = 48_000) {
    this.stderr.write(`${JSON.stringify({ event: "ready", sampleRate })}\n`);
  }

  exit(code: number) {
    this.exitCode = code;
    this.emit("exit", code);
  }
}

function int16Bytes(values: number[]) {
  const buffer = Buffer.alloc(values.length * 2);
  values.forEach((value, index) => buffer.writeInt16LE(value, index * 2));
  return buffer;
}

describe("Int16FrameDecoder", () => {
  it("scales whole samples and carries a trailing odd byte to the next chunk", () => {
    const frames: Float32Array[] = [];
    const decoder = new Int16FrameDecoder((chunk) => frames.push(chunk));
    const bytes = int16Bytes([0x7fff, -0x8000, 0]);
    decoder.push(bytes.subarray(0, 3));
    decoder.push(bytes.subarray(3));
    expect(frames.map((chunk) => Array.from(chunk))).toEqual([
      [0x7fff / 0x8000],
      [-1, 0],
    ]);
  });
});

describe("HelperMicrophoneCapture", () => {
  afterEach(() => vi.useRealTimers());
  const executablePath = "/tmp/MicCaptureHost";

  it("reports unavailable when the helper binary is missing", () => {
    expect(
      new HelperMicrophoneCapture({ executablePath: "/nonexistent" }).available()
    ).toBe(false);
  });

  it("enumerates actual helper devices without starting a recording", async () => {
    const host = new FakeHost();
    const spawn = vi.fn(() => host);
    const capture = new HelperMicrophoneCapture({ executablePath, spawn });
    const pending = capture.devices();
    const result = {
      devices: [{ id: "built-in", label: "MacBook Pro Microphone", isDefault: true }],
    };
    host.stdout.write(JSON.stringify(result));
    host.exit(0);
    await expect(pending).resolves.toEqual(result);
    expect(spawn).toHaveBeenCalledWith(executablePath, ["--list-devices"]);
  });

  it("opens the explicitly selected device instead of silently using the default", async () => {
    const host = new FakeHost();
    const spawn = vi.fn(() => host);
    const capture = new HelperMicrophoneCapture({ executablePath, spawn });
    const pending = capture.start({
      deviceId: "external-mic",
      onError: vi.fn(),
      onFrames: vi.fn(),
      sampleRate: 48_000,
    });
    expect(spawn).toHaveBeenCalledWith(executablePath, [
      "--sample-rate",
      "48000",
      "--device",
      "external-mic",
    ]);
    host.ready();
    const session = await pending;
    host.exit(0);
    await session.stop();
  });

  it("resolves once the helper is ready and streams decoded frames", async () => {
    const host = new FakeHost();
    const spawn = vi.fn(() => host);
    const capture = new HelperMicrophoneCapture({ executablePath, spawn });
    const frames: Float32Array[] = [];
    const onError = vi.fn();

    const pending = capture.start({
      onError,
      onFrames: (f) => frames.push(f),
      sampleRate: 24_000,
    });
    expect(spawn).toHaveBeenCalledWith(executablePath, ["--sample-rate", "24000"]);
    host.ready(24_000);
    const session = await pending;

    host.stdout.write(int16Bytes([0x4000, -0x4000]));
    await new Promise((resolve) => setImmediate(resolve));
    expect(frames.map((chunk) => Array.from(chunk))).toEqual([[0.5, -0.5]]);

    const stopped = session.stop();
    await new Promise((resolve) => setImmediate(resolve));
    expect(host.stdinEnded).toBe(true);
    host.exit(0);
    await stopped;
    expect(onError).not.toHaveBeenCalled();
  });

  it("rejects with MicrophoneDeniedError when the helper exits with code 3", async () => {
    const host = new FakeHost();
    const capture = new HelperMicrophoneCapture({ executablePath, spawn: () => host });
    const pending = capture.start({
      onError: vi.fn(),
      onFrames: vi.fn(),
      sampleRate: 48_000,
    });
    host.stderr.write(
      `${JSON.stringify({ event: "error", message: "microphone_denied" })}\n`
    );
    host.exit(3);
    await expect(pending).rejects.toBeInstanceOf(MicrophoneDeniedError);
  });

  it("surfaces an unexpected exit after ready through onError", async () => {
    const host = new FakeHost();
    const capture = new HelperMicrophoneCapture({ executablePath, spawn: () => host });
    const onError = vi.fn();
    const pending = capture.start({ onError, onFrames: vi.fn(), sampleRate: 48_000 });
    host.ready();
    await pending;
    host.exit(2);
    expect(onError).toHaveBeenCalledWith(
      expect.objectContaining({ message: expect.stringMatching(/code 2/) })
    );
  });

  it("shares stop completion and escalates until the exit is actually observed", async () => {
    vi.useFakeTimers();
    const host = new FakeHost();
    const capture = new HelperMicrophoneCapture({ executablePath, spawn: () => host });
    const pending = capture.start({
      onError: vi.fn(),
      onFrames: vi.fn(),
      sampleRate: 48_000,
    });
    host.ready();
    const session = await pending;
    const first = session.stop();
    const second = session.stop();
    expect(first).toBe(second);
    expect(host.killed).toBe(true);
    await vi.advanceTimersByTimeAsync(1_500);
    expect(host.signals).toEqual(["SIGTERM", "SIGKILL"]);
    host.exit(0);
    await Promise.all([first, second]);
  });

  it("finishes stop when the helper already exited by signal", async () => {
    const host = new FakeHost();
    const capture = new HelperMicrophoneCapture({ executablePath, spawn: () => host });
    const pending = capture.start({
      onError: vi.fn(),
      onFrames: vi.fn(),
      sampleRate: 48_000,
    });
    host.ready();
    const session = await pending;
    host.emit("exit", null);
    await session.stop();
    expect(host.signals).toEqual([]);
  });

  it("escalates a timed-out initialization even without a returned session", async () => {
    vi.useFakeTimers();
    const host = new FakeHost();
    const capture = new HelperMicrophoneCapture({
      executablePath,
      readyTimeoutMs: 20,
      spawn: () => host,
    });
    const pending = capture.start({
      onError: vi.fn(),
      onFrames: vi.fn(),
      sampleRate: 48_000,
    });
    const rejected = expect(pending).rejects.toThrow("did not become ready");
    await vi.advanceTimersByTimeAsync(20);
    await rejected;
    await vi.advanceTimersByTimeAsync(1_500);
    expect(host.signals).toEqual(["SIGTERM", "SIGKILL"]);
    host.emit("exit", null);
  });

  it("gives up on a helper that never reports ready", async () => {
    const host = new FakeHost();
    const capture = new HelperMicrophoneCapture({
      executablePath,
      readyTimeoutMs: 20,
      spawn: () => host,
    });
    await expect(
      capture.start({ onError: vi.fn(), onFrames: vi.fn(), sampleRate: 48_000 })
    ).rejects.toThrow(/did not become ready/);
    expect(host.killed).toBe(true);
  });
});

describe("mixMono", () => {
  it("averages both tracks and pads the shorter one with silence", () => {
    const mixed = mixMono(
      { sampleRate: 16_000, samples: new Float32Array([0.5, 0.5, 0.5]) },
      { sampleRate: 16_000, samples: new Float32Array([0.5, -0.5]) }
    );
    expect(Array.from(mixed.samples)).toEqual([0.5, 0, 0.25]);
    expect(mixed.sampleRate).toBe(16_000);
  });

  it("refuses mismatched sample rates", () => {
    expect(() =>
      mixMono(
        { sampleRate: 16_000, samples: new Float32Array(1) },
        { sampleRate: 24_000, samples: new Float32Array(1) }
      )
    ).toThrow(/resampling/);
  });
});
