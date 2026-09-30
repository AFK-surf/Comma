import { mkdtempSync, rmSync } from "node:fs";
import { copyFile, mkdir, readFile, readdir, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  audioCaptureStartCapability,
  audioCaptureSelectMicrophoneCapability,
  audioCaptureStopCapability,
  type AudioCaptureStartInput,
  type AudioCaptureState,
} from "@comma/native-bridge";
import { sessionProductLease } from "@comma/session-contract";
import { AudioCaptureService } from "../modules/audio-capture";
import { frameLevel, WavSink } from "../modules/audio-capture/wav";
import type {
  NativeAudioCapture,
  NativeAudioTapInput,
} from "../modules/audio-capture/native-audio";
import type {
  MicrophoneCapture,
  MicrophoneStartInput,
} from "../modules/audio-capture/microphone";
import {
  MainNativeSessionAdmissionGuard,
  MainProductCredentialAuthority,
} from "../modules/session";

const temporaryDirectories: string[] = [];

afterEach(() => {
  while (temporaryDirectories.length > 0) {
    const directory = temporaryDirectories.pop();
    if (directory) rmSync(directory, { force: true, recursive: true });
  }
});

describe("WavSink", () => {
  it("stores 48 kHz stereo capture as mono 16 kHz PCM", async () => {
    const path = join(tempDirectory(), "capture.wav");
    const sink = await WavSink.open({ channels: 2, path, sampleRate: 48_000 });

    // 48 frames of interleaved stereo decimate 3:1 into 16 mono samples.
    sink.write(new Float32Array(48 * 2).fill(0.5));
    const summary = await sink.finalize();

    expect(summary).toEqual({
      byteLength: 32,
      channels: 1,
      durationMs: 1,
      sampleRate: 16_000,
    });

    const bytes = await readFile(path);
    expect(bytes.subarray(0, 4).toString("ascii")).toBe("RIFF");
    expect(bytes.subarray(8, 12).toString("ascii")).toBe("WAVE");
    expect(bytes.readUInt16LE(22)).toBe(1);
    expect(bytes.readUInt32LE(24)).toBe(16_000);
    expect(bytes.readUInt32LE(40)).toBe(32);
    expect(bytes.readUInt32LE(4)).toBe(36 + 32);
    // 0.5 downmixed and averaged is still 0.5 — decimation must not attenuate.
    expect(bytes.readInt16LE(44)).toBe(Math.round(0.5 * 0x7fff));
  });

  it("keeps the native rate when it is not a multiple of the target rate", async () => {
    const path = join(tempDirectory(), "odd-rate.wav");
    const sink = await WavSink.open({ channels: 1, path, sampleRate: 44_100 });
    sink.write(new Float32Array(441).fill(0));
    const summary = await sink.finalize();

    expect(summary.sampleRate).toBe(44_100);
    expect(summary.byteLength).toBe(441 * 2);
  });

  it("clamps out-of-range samples instead of wrapping them", async () => {
    const path = join(tempDirectory(), "clipped.wav");
    const sink = await WavSink.open({ channels: 1, path, sampleRate: 16_000 });
    sink.write(new Float32Array([4, -4]));
    await sink.finalize();

    const bytes = await readFile(path);
    expect(bytes.readInt16LE(44)).toBe(0x7fff);
    expect(bytes.readInt16LE(46)).toBe(-0x8000);
  });

  it("removes the working file when discarded", async () => {
    const directory = tempDirectory();
    const path = join(directory, "discarded.wav");
    const sink = await WavSink.open({ channels: 1, path, sampleRate: 16_000 });
    sink.write(new Float32Array(16).fill(0.1));
    await sink.discard();

    await expect(readdir(directory)).resolves.toEqual([]);
  });
});

describe("frameLevel", () => {
  it("reports the RMS of the chunk", () => {
    expect(frameLevel(new Float32Array(0))).toBe(0);
    expect(frameLevel(new Float32Array([1, -1]))).toBe(1);
    expect(frameLevel(new Float32Array([0, 0]))).toBe(0);
    expect(frameLevel(new Float32Array([0.5, -0.5]))).toBeCloseTo(0.5, 5);
  });
});

describe("AudioCaptureService", () => {
  it("reports unavailable when the platform has no tap", async () => {
    const { service } = createService({ nativeAvailable: false });

    const state = await service.state();

    expect(state.available).toBe(false);
    expect(state.status).toBe("unavailable");
    await expect(service.sources()).resolves.toEqual({ applications: [] });
  });

  it("publishes recording state and measured levels while the tap runs", async () => {
    const { native, published, service } = createService();

    await service.start({ source: { kind: "system" } });
    expect(native.taps).toHaveLength(1);
    // The system tap must never record this app's own output back into itself.
    expect(native.taps[0]?.excludedProcessIds).toEqual([process.pid]);

    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    await settle();

    const latest = published.at(-1);
    expect(latest?.status).toBe("recording");
    expect(latest?.available).toBe(true);
    expect(latest?.channels).toBe(1);
    expect(latest?.sampleRate).toBe(16_000);
    expect(latest?.level).toBeCloseTo(0.5, 2);
    expect(latest?.source).toEqual({ kind: "system" });
  });

  it("taps a single process when the source names one", async () => {
    const { native, service } = createService();

    await service.start({ source: { kind: "application", processId: 42 } });

    expect(native.taps[0]?.processId).toBe(42);
  });

  it("refuses a second recording while one is in progress", async () => {
    const { native, service } = createService();

    await service.start({ source: { kind: "system" } });
    await expect(service.start({ source: { kind: "system" } })).rejects.toThrow(
      "A recording is already in progress."
    );

    expect(native.taps).toHaveLength(1);
    await expect(service.state()).resolves.toMatchObject({ status: "recording" });
  });

  it("saves the recording into Drive and clears the working file after acknowledgement", async () => {
    const { admitted, native, recordingsDir, service, drive } = createService();

    await service.start({ source: { kind: "system" } });
    native.taps[0]?.emit(new Float32Array(48 * 2 * 10).fill(0.25));
    await settle();
    const result = await admitted.stop();

    expect(native.taps[0]?.stopped).toBe(true);
    expect(result).toEqual({
      recording: {
        channels: 1,
        driveFile: {
          space: "comma-drive",
          path: expect.stringMatching(/^recording\/comma-recording-.*\.m4a$/),
        },
        durationMs: 10,
        file: {
          mediaType: "audio/mp4",
          name: expect.stringMatching(/^comma-recording-.*\.m4a$/),
          // The fake encoder preserves PCM bytes for the mix assertions below.
          size: 364,
        },
        sampleRate: 16_000,
      },
      status: "ready",
    });
    expect(drive.save).toHaveBeenCalledWith(
      expect.stringContaining(recordingsDir),
      {
        space: "comma-drive",
        localRoot: expect.any(String),
      },
      expect.any(Number)
    );
    // Drive owns the committed copy; Main keeps no working file behind.
    await expect(readdir(recordingsDir)).resolves.toEqual([]);
    await expect(service.state()).resolves.toMatchObject({ status: "idle" });
  });

  it("reports unavailable and keeps no file when the tap produced no audio", async () => {
    const { admitted, recordingsDir, drive } = createService();

    await admitted.service.start({ source: { kind: "system" } });
    const result = await admitted.stop();

    expect(result).toEqual({ status: "unavailable" });
    expect(drive.save).not.toHaveBeenCalled();
    await expect(readdir(recordingsDir)).resolves.toEqual([]);
  });

  it("retains the completed WAV when Drive fails, including an uncertain commit", async () => {
    const { admitted, native, recordingsDir, service, drive } = createService();
    drive.save.mockRejectedValueOnce(new Error("Put response lost"));
    await service.start({ source: { kind: "system" } });
    native.taps[0]?.emit(new Float32Array(48 * 2 * 10).fill(0.25));
    const result = await admitted.stop();
    expect(result).toMatchObject({
      status: "unavailable",
      reason: expect.stringContaining("retained"),
    });
    const names = await readdir(recordingsDir);
    expect(names).toHaveLength(2);
    const wav = await readFile(
      join(recordingsDir, names.find((name) => name.endsWith(".wav"))!)
    );
    expect(wav.subarray(0, 4).toString()).toBe("RIFF");
    expect(wav.readUInt32LE(40)).toBe(320);
    expect(drive.save).toHaveBeenCalledTimes(1);
    await admitted.stop();
    expect(drive.save).toHaveBeenCalledTimes(1);
  });

  it("does not let another signed-in principal claim the recording", async () => {
    const { admitted, native, rawService, service, drive } = createService();
    await service.start({ source: { kind: "system" } });
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.25));
    const otherUser = createAdmittedService(rawService, "other-user");
    await expect(otherUser.stop()).resolves.toMatchObject({
      status: "unavailable",
      reason: expect.stringContaining("account"),
    });
    expect(drive.save).not.toHaveBeenCalled();
    await expect(admitted.stop()).resolves.toMatchObject({ status: "ready" });
  });

  it("retains the WAV and does not submit to Drive when compression fails", async () => {
    const { admitted, native, recordingsDir, service, drive, encoder } =
      createService();
    encoder.encode.mockRejectedValueOnce(new Error("Encoder exited"));
    await service.start({ source: { kind: "system" } });
    native.taps[0]?.emit(new Float32Array(48 * 2 * 10).fill(0.25));
    await expect(admitted.stop()).resolves.toMatchObject({
      status: "unavailable",
      reason: expect.stringContaining("could not be compressed"),
    });
    expect(drive.save).not.toHaveBeenCalled();
    const names = await readdir(recordingsDir);
    expect(names).toHaveLength(1);
    const bytes = await readFile(join(recordingsDir, names[0]!));
    expect(bytes.readUInt32LE(40)).toBe(320);
    await expect(service.state()).resolves.toMatchObject({ status: "idle" });
  });

  it("returns before ASR completes and supplies the saved Drive source", async () => {
    const gate = Promise.withResolvers<void>();
    const onSaved = vi.fn(
      (
        ..._args: Parameters<
          NonNullable<ConstructorParameters<typeof AudioCaptureService>[0]["onSaved"]>
        >
      ) => gate.promise
    );
    const { admitted, native, recordingsDir, service } = createService({ onSaved });
    await service.start({ source: { kind: "system" } });
    native.taps[0]?.emit(new Float32Array(480 * 2).fill(0.25));
    try {
      await expect(admitted.stop()).resolves.toMatchObject({ status: "ready" });
      await expect(service.state()).resolves.toMatchObject({ status: "idle" });
      expect(onSaved).toHaveBeenCalledOnce();
      const [recording, target, source] = onSaved.mock.calls[0]!;
      expect(source).toBe(join(target.localRoot, recording.driveFile.path));
      expect(await readFile(source)).toEqual(await driveStoreCopy(recordingsDir));
      const files = await readdir(recordingsDir);
      expect(files).toHaveLength(1);
      expect(files[0]).toMatch(/\.m4a$/);
    } finally {
      gate.resolve();
    }
    await vi.waitFor(async () => expect(await readdir(recordingsDir)).toEqual([]));
    expect(await readFile(onSaved.mock.calls[0]![2])).toEqual(
      await driveStoreCopy(recordingsDir)
    );
  });

  it("hands meeting audio to Router without also uploading it to desktop ASR", async () => {
    const directASR = vi.fn(async () => {});
    const gate = Promise.withResolvers<void>();
    const summary = vi.fn(() => gate.promise);
    const { admitted, native, recordingsDir, service } = createService({
      onSaved: directASR,
    });
    await service.start({ source: { kind: "system" } });
    native.taps[0]?.emit(new Float32Array(480 * 2).fill(0.25));
    try {
      await expect(admitted.stop(summary)).resolves.toMatchObject({ status: "ready" });
      expect(summary).toHaveBeenCalledOnce();
      expect(directASR).not.toHaveBeenCalled();
      expect(await readdir(recordingsDir)).toHaveLength(1);
    } finally {
      gate.resolve();
    }
    await vi.waitFor(async () => expect(await readdir(recordingsDir)).toEqual([]));
  });

  it("keeps one finalizer and the WAV while compression is pending", async () => {
    const { admitted, native, recordingsDir, service, drive, encoder } =
      createService();
    const pending = Promise.withResolvers<void>();
    const encode = encoder.encode.getMockImplementation()!;
    encoder.encode.mockImplementationOnce(async (path) => {
      await pending.promise;
      return encode(path);
    });
    await service.start({ source: { kind: "system" } });
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.25));
    const stopping = admitted.stop();
    try {
      await vi.waitFor(() => expect(encoder.encode).toHaveBeenCalledOnce());
      await expect(service.state()).resolves.toMatchObject({ status: "finalizing" });
      await expect(admitted.stop()).resolves.toEqual({ status: "unavailable" });
      await expect(service.start({ source: { kind: "system" } })).rejects.toThrow(
        "already in progress"
      );
      await service.cancel();
      expect(await readdir(recordingsDir)).toHaveLength(1);
      expect(drive.save).not.toHaveBeenCalled();
    } finally {
      pending.resolve();
      await stopping;
    }
    expect(encoder.encode).toHaveBeenCalledOnce();
    expect(drive.save).toHaveBeenCalledOnce();
    expect(await readdir(recordingsDir)).toEqual([]);
  });

  it("keeps one finalizer while the Drive acknowledgement is pending", async () => {
    const { admitted, native, recordingsDir, service, drive } = createService();
    let acknowledge!: () => void;
    const pending = new Promise<void>((resolve) => {
      acknowledge = resolve;
    });
    const save = drive.save.getMockImplementation()!;
    drive.save.mockImplementationOnce(async (...args) => {
      await pending;
      return save(...args);
    });
    await service.start({ source: { kind: "system" } });
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.25));
    const stopping = admitted.stop();
    await vi.waitFor(() => expect(drive.save).toHaveBeenCalledTimes(1));
    await expect(service.start({ source: { kind: "system" } })).rejects.toThrow(
      "already in progress"
    );
    await expect(admitted.stop()).resolves.toEqual({ status: "unavailable" });
    expect(await readdir(recordingsDir)).toHaveLength(2);
    acknowledge();
    await expect(stopping).resolves.toMatchObject({ status: "ready" });
    expect(await readdir(recordingsDir)).toEqual([]);
  });

  it("starts as granted when Electron already holds Screen Recording", async () => {
    const { service } = createService({ screenAccessStatus: () => "granted" });
    await expect(service.state()).resolves.toMatchObject({ permission: "granted" });
  });

  it("flags a suspected missing grant after sustained all-zero audio, then clears it", async () => {
    let nowMs = 1_700_000_000_000;
    const { native, service } = createService({ now: () => nowMs });

    await service.start({ source: { kind: "system" } });
    const tap = native.taps[0];
    tap?.emit(new Float32Array(48 * 2));
    await settle();
    await expect(service.state()).resolves.toMatchObject({ permission: "unknown" });

    nowMs += 4_100;
    tap?.emit(new Float32Array(48 * 2));
    await settle();
    await expect(service.state()).resolves.toMatchObject({
      permission: "suspected_denied",
      status: "recording",
    });

    // Real samples prove the grant exists after all.
    tap?.emit(new Float32Array(48 * 2).fill(0.3));
    await settle();
    await expect(service.state()).resolves.toMatchObject({ permission: "granted" });
    await service.cancel();
  });

  it("opens the macOS system audio privacy pane", async () => {
    const openExternalUrl = vi.fn(async () => undefined);
    const { service } = createService({ openExternalUrl });

    await expect(service.openPermissionSettings()).resolves.toEqual({ opened: true });
    expect(openExternalUrl).toHaveBeenCalledWith(
      "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
    );

    const failing = createService({
      openExternalUrl: async () => {
        throw new Error("no shell");
      },
    });
    await expect(failing.service.openPermissionSettings()).resolves.toEqual({
      opened: false,
    });
  });

  it("mixes the microphone into the system track as an average", async () => {
    const microphone = new FakeMicrophone();
    const { admitted, native, recordingsDir, service } = createService({ microphone });

    await service.start({ microphone: true, source: { kind: "system" } });
    expect(microphone.sessions).toHaveLength(1);
    expect(microphone.sessions[0]?.sampleRate).toBe(48_000);
    await expect(service.state()).resolves.toMatchObject({ microphone: "on" });

    // 48 kHz stereo system at 0.5 and 48 kHz mono mic at -0.5 both decimate
    // 3:1 to 16 samples; averaging cancels to 0. A second mic-only stretch
    // averages against silence to -0.25.
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    microphone.emit(new Float32Array(48).fill(-0.5));
    microphone.emit(new Float32Array(48).fill(-0.5));
    await settle();

    const result = await admitted.stop();
    expect(result.status).toBe("ready");
    expect(microphone.sessions[0]?.stopped).toBe(true);
    if (result.status !== "ready") throw new Error("unreachable");
    expect(result.recording).toMatchObject({ channels: 1, sampleRate: 16_000 });
    expect(result.recording.file.size).toBe(44 + 32 * 2);

    const stored = await driveStoreCopy(recordingsDir);
    expect(stored.readInt16LE(44)).toBe(0);
    expect(stored.readInt16LE(44 + 16 * 2)).toBe(Math.round(-0.25 * 0x7fff));
    await expect(readdir(recordingsDir)).resolves.toEqual([]);
  });

  it("pads the microphone track so a late-starting helper stays aligned", async () => {
    const microphone = new FakeMicrophone();
    let release: (() => void) | undefined;
    // Resolves once the service asks for the microphone: by then the tap and
    // both sinks exist, so the test no longer races filesystem latency.
    const requested = new Promise<void>((resolveRequested) => {
      microphone.start = async (input) => {
        resolveRequested();
        await new Promise<void>((resolve) => {
          release = resolve;
        });
        const session = { ...input, stopped: false };
        microphone.sessions.push(session);
        return { stop: async () => void (session.stopped = true) };
      };
    });
    const { admitted, native, recordingsDir, service } = createService({ microphone });

    const starting = service.start({ microphone: true, source: { kind: "system" } });
    await requested;
    // 48 frames of system audio land before the microphone is ready.
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    release?.();
    await starting;
    microphone.emit(new Float32Array(48).fill(-0.5));
    await settle();

    const result = await admitted.stop();
    expect(result.status).toBe("ready");
    const stored = await driveStoreCopy(recordingsDir);
    // First 16 output samples: system only (0.5 averaged with padding 0).
    expect(stored.readInt16LE(44)).toBe(Math.round(0.25 * 0x7fff));
    // Next 16: microphone only (-0.5 averaged with silence).
    expect(stored.readInt16LE(44 + 16 * 2)).toBe(Math.round(-0.25 * 0x7fff));
  });

  it("falls back to a system-only recording when the microphone cannot start", async () => {
    const microphone = new FakeMicrophone();
    microphone.failWith = new Error("microphone_denied");
    const { admitted, native, service } = createService({ microphone });

    await service.start({ microphone: true, source: { kind: "system" } });
    await expect(service.state()).resolves.toMatchObject({
      microphone: "unavailable",
      status: "recording",
    });
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.25));
    await settle();
    const result = await admitted.stop();
    expect(result.status).toBe("ready");
  });

  it("leaves the microphone off when not requested", async () => {
    const microphone = new FakeMicrophone();
    const { service } = createService({ microphone });
    await service.start({ source: { kind: "system" } });
    expect(microphone.sessions).toHaveLength(0);
    await expect(service.state()).resolves.toMatchObject({ microphone: "off" });
    await service.cancel();
  });

  it("discards both working files on cancel", async () => {
    const microphone = new FakeMicrophone();
    const { native, recordingsDir, service } = createService({ microphone });
    await service.start({ microphone: true, source: { kind: "system" } });
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.4));
    microphone.emit(new Float32Array(48).fill(0.4));
    await settle();
    await service.cancel();
    expect(microphone.sessions[0]?.stopped).toBe(true);
    await expect(readdir(recordingsDir)).resolves.toEqual([]);
  });

  it("discards the working file on cancel", async () => {
    const { native, recordingsDir, service, drive } = createService();

    await service.start({ source: { kind: "system" } });
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.4));
    await settle();
    const state = await service.cancel();

    expect(native.taps[0]?.stopped).toBe(true);
    expect(state.status).toBe("idle");
    expect(state.level).toBe(0);
    expect(drive.save).not.toHaveBeenCalled();
    await expect(readdir(recordingsDir)).resolves.toEqual([]);
  });

  it("stops the tap at the length ceiling but still lets stop claim the recording", async () => {
    let nowMs = 1_000;
    const { admitted, native, published } = createService({ now: () => nowMs });

    await admitted.service.start({ maxDurationMs: 1_000, source: { kind: "system" } });
    nowMs += 1_500;
    native.taps[0]?.emit(new Float32Array(48 * 2 * 10).fill(0.3));
    await settle();

    expect(native.taps[0]?.stopped).toBe(true);
    expect(published.at(-1)).toMatchObject({
      capped: true,
      reason: "The recording reached its length limit.",
      status: "recording",
    });
    await expect(admitted.stop()).resolves.toMatchObject({ status: "ready" });
  });

  it("drops an in-flight recording when Main closes", async () => {
    const { native, recordingsDir, service } = createService();

    await service.start({ source: { kind: "system" } });
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.2));
    await settle();
    await service.close();

    expect(native.taps[0]?.stopped).toBe(true);
    await expect(readdir(recordingsDir)).resolves.toEqual([]);
  });
});

type FakeTap = {
  emit(frames: Float32Array): void;
  excludedProcessIds?: readonly number[];
  processId?: number;
  stopped: boolean;
};

function createFakeNative() {
  const taps: FakeTap[] = [];
  const register = (
    listeners: NativeAudioTapInput,
    extra: Pick<FakeTap, "excludedProcessIds" | "processId">
  ) => {
    const tap: FakeTap = {
      emit: (frames) => listeners.onFrames(frames),
      stopped: false,
      ...extra,
    };
    taps.push(tap);
    return {
      channels: 2,
      sampleRate: 48_000,
      stop: () => {
        tap.stopped = true;
      },
    };
  };

  const native: NativeAudioCapture & { taps: FakeTap[] } = {
    applications: () => [
      { bundleIdentifier: "com.example.meet", name: "Meet", processId: 42 },
    ],
    isUsingMicrophone: () => false,
    onApplicationListChanged: () => () => undefined,
    tapApplication: ({ processId, ...listeners }) => register(listeners, { processId }),
    tapSystem: ({ excludedProcessIds, ...listeners }) =>
      register(listeners, { excludedProcessIds }),
    taps,
  };
  return native;
}

describe("AudioCaptureService pause and resume", () => {
  it("drops frames while paused and keeps both tracks aligned on resume", async () => {
    const microphone = new FakeMicrophone();
    const { admitted, native, recordingsDir, service } = createService({ microphone });
    await service.start({ microphone: true, source: { kind: "system" } });

    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    microphone.emit(new Float32Array(48).fill(-0.5));
    await settle();
    await expect(service.state()).resolves.toMatchObject({
      durationMs: 1,
      status: "recording",
    });

    await expect(service.pause()).resolves.toMatchObject({
      level: 0,
      status: "paused",
    });
    // Neither track advances while paused; the tap and helper stay open.
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    microphone.emit(new Float32Array(48).fill(-0.5));
    await settle();
    await expect(service.state()).resolves.toMatchObject({
      durationMs: 1,
      status: "paused",
    });
    expect(native.taps[0]?.stopped).toBe(false);
    expect(microphone.sessions[0]?.stopped).toBe(false);

    await expect(service.resume()).resolves.toMatchObject({ status: "recording" });
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    microphone.emit(new Float32Array(48).fill(-0.5));
    await settle();

    const result = await admitted.stop();
    expect(result.status).toBe("ready");
    const stored = await driveStoreCopy(recordingsDir);
    // Two recorded chunks of 16 samples each, both cancelled to 0 by the mic.
    expect(stored.length).toBe(44 + 32 * 2);
    expect(stored.readInt16LE(44)).toBe(0);
    expect(stored.readInt16LE(44 + 16 * 2)).toBe(0);
  });

  it("re-aligns the tracks on resume when the two sources dropped different amounts", async () => {
    const microphone = new FakeMicrophone();
    const { admitted, native, recordingsDir, service } = createService({ microphone });
    await service.start({ microphone: true, source: { kind: "system" } });

    // Three system chunks land before the pause but only one from the helper.
    for (let i = 0; i < 3; i += 1)
      native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    microphone.emit(new Float32Array(48).fill(-0.5));
    await settle();
    await service.pause();
    await service.resume();
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    microphone.emit(new Float32Array(48).fill(-0.5));
    await settle();

    const result = await admitted.stop();
    expect(result.status).toBe("ready");
    const stored = await driveStoreCopy(recordingsDir);
    // 4 system chunks = 64 samples; the mic was padded to 48 before resuming,
    // so its last chunk lines up with the last system chunk.
    expect(stored.length).toBe(44 + 64 * 2);
    expect(stored.readInt16LE(44)).toBe(0); // mic + system
    expect(stored.readInt16LE(44 + 16 * 2)).toBe(Math.round(0.25 * 0x7fff)); // system alone
    expect(stored.readInt16LE(44 + 40 * 2)).toBe(Math.round(0.25 * 0x7fff)); // padded silence
    expect(stored.readInt16LE(44 + 48 * 2)).toBe(0); // realigned after resume
  });

  it("queues startup frames and only offers pause after initialization", async () => {
    const { admitted, native, recordingsDir, service } = createService();
    let release: (() => void) | undefined;
    let reachedOpen!: () => void;
    const opening = new Promise<void>((resolve) => {
      reachedOpen = resolve;
    });
    // Hold the sink open so the first frames have to queue.
    const realOpen = WavSink.open;
    const openSpy = vi.spyOn(WavSink, "open").mockImplementationOnce(async (input) => {
      await new Promise<void>((resolve) => {
        release = resolve;
        reachedOpen();
      });
      return realOpen(input);
    });
    const starting = service.start({ source: { kind: "system" } });
    await opening;
    await expect(service.pause()).resolves.toMatchObject({ status: "idle" });
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    release?.();
    await starting;
    await service.pause();
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    await service.resume();
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    await settle();
    openSpy.mockRestore();

    const result = await admitted.stop();
    expect(result.status).toBe("ready");
    const stored = await driveStoreCopy(recordingsDir);
    expect(stored.length).toBe(44 + 32 * 2);
  });

  it("excludes paused time from the silence and length heuristics", async () => {
    let nowMs = 1_700_000_000_000;
    const { native, service } = createService({ now: () => nowMs });
    await service.start({ maxDurationMs: 5_000, source: { kind: "system" } });
    native.taps[0]?.emit(new Float32Array(48 * 2));
    await settle();

    await service.pause();
    nowMs += 60_000;
    await service.resume();
    nowMs += 1_000;
    native.taps[0]?.emit(new Float32Array(48 * 2));
    await settle();
    // Only 1 s of wall time counts: no silence suspicion, no length cap.
    await expect(service.state()).resolves.toMatchObject({
      capped: false,
      permission: "unknown",
      status: "recording",
    });

    nowMs += 3_100;
    native.taps[0]?.emit(new Float32Array(48 * 2));
    await settle();
    await expect(service.state()).resolves.toMatchObject({
      permission: "suspected_denied",
    });
  });

  it("ignores pause and resume outside their phases", async () => {
    const { native, service } = createService();
    await expect(service.pause()).resolves.toMatchObject({ status: "idle" });
    await expect(service.resume()).resolves.toMatchObject({ status: "idle" });

    await service.start({ source: { kind: "system" } });
    await expect(service.resume()).resolves.toMatchObject({ status: "recording" });
    await service.pause();
    await expect(service.pause()).resolves.toMatchObject({ status: "paused" });
    await expect(service.start({ source: { kind: "system" } })).rejects.toThrow(
      "A recording is already in progress."
    );
    await expect(service.state()).resolves.toMatchObject({ status: "paused" });
    expect(native.taps).toHaveLength(1);
  });

  it("changes the real input without restarting system capture or losing earlier microphone audio", async () => {
    const microphone = new FakeMicrophone();
    const { admitted, service, native, recordingsDir, drive } = createService({
      microphone,
    });
    await service.start({ source: { kind: "system" }, microphone: true });
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    microphone.emit(new Float32Array(48).fill(-0.5));
    const old = microphone.sessions[0]!;
    await admitted.selectMicrophone("built-in");
    expect(old.stopped).toBe(true);
    expect(microphone.sessions[1]?.deviceId).toBe("built-in");
    expect(native.taps).toHaveLength(1);
    expect(drive.save).not.toHaveBeenCalled();
    // A retired helper's late frames must not enter the shared mic track.
    old.onFrames(new Float32Array(4800).fill(1));
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    microphone.emit(new Float32Array(48).fill(-0.5));
    const result = await admitted.stop();
    expect(result.status).toBe("ready");
    const bytes = await driveStoreCopy(recordingsDir);
    expect(bytes.readUInt32LE(40)).toBe(64);
    expect(bytes.readInt16LE(44)).toBe(0);
    expect(bytes.readInt16LE(44 + 32)).toBe(0);
  });

  it("discards during a pending microphone switch and stops its late helper without importing", async () => {
    const microphone = new FakeMicrophone();
    const { admitted, service, native, drive, recordingsDir } = createService({
      microphone,
    });
    await service.start({ source: { kind: "system" }, microphone: true });
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    let ready!: (session: { stop: () => Promise<void> }) => void;
    const opening = new Promise<{ stop: () => Promise<void> }>((resolve) => {
      ready = resolve;
    });
    vi.spyOn(microphone, "start").mockReturnValueOnce(opening);
    const changing = admitted.selectMicrophone("built-in");
    await settle();
    const cancelled = service.cancel();
    const lateStop = vi.fn(async () => {});
    ready({ stop: lateStop });
    await Promise.all([changing, cancelled]);
    expect(lateStop).toHaveBeenCalledOnce();
    expect(native.taps[0]?.stopped).toBe(true);
    expect(drive.save).not.toHaveBeenCalled();
    await expect(readdir(recordingsDir)).resolves.toEqual([]);
    await expect(service.state()).resolves.toMatchObject({
      status: "idle",
      microphone: "off",
    });
  });

  it("keeps a microphone unavailable when its helper fails immediately after readiness", async () => {
    const microphone = new FakeMicrophone();
    const { admitted, service } = createService({ microphone });
    await service.start({ source: { kind: "system" }, microphone: true });
    const stop = vi.fn(async () => {});
    vi.spyOn(microphone, "start").mockImplementationOnce(async (input) => {
      input.onError(new Error("Microphone disconnected"));
      return { stop };
    });
    await admitted.selectMicrophone("built-in");
    expect(stop).toHaveBeenCalledOnce();
    await expect(service.state()).resolves.toMatchObject({
      status: "recording",
      microphone: "unavailable",
    });
    await service.cancel();
  });

  it("finalizes a paused recording on stop and discards it on cancel", async () => {
    const { admitted, native, service } = createService();
    await service.start({ source: { kind: "system" } });
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.25));
    await settle();
    await service.pause();

    const result = await admitted.stop();
    expect(result.status).toBe("ready");
    await expect(service.state()).resolves.toMatchObject({ status: "idle" });

    await service.start({ source: { kind: "system" } });
    await service.pause();
    await expect(service.cancel()).resolves.toMatchObject({ status: "idle" });
    expect(native.taps[1]?.stopped).toBe(true);
  });
});

class FakeMicrophone implements MicrophoneCapture {
  async devices() {
    return {
      devices: [{ id: "built-in", label: "Built-in microphone", isDefault: true }],
    };
  }
  isAvailable = true;
  failWith: Error | null = null;
  sessions: Array<MicrophoneStartInput & { stopped: boolean }> = [];

  available() {
    return this.isAvailable;
  }
  async start(input: MicrophoneStartInput) {
    if (this.failWith) throw this.failWith;
    const session = { ...input, stopped: false };
    this.sessions.push(session);
    return {
      stop: async () => {
        session.stopped = true;
      },
    };
  }
  emit(frames: Float32Array) {
    this.sessions.at(-1)?.onFrames(frames);
  }
}

function createService({
  microphone,
  nativeAvailable = true,
  now,
  openExternalUrl,
  screenAccessStatus,
  onSaved,
}: {
  onSaved?: NonNullable<
    ConstructorParameters<typeof AudioCaptureService>[0]["onSaved"]
  >;
  microphone?: MicrophoneCapture;
  nativeAvailable?: boolean;
  now?: () => number;
  openExternalUrl?: (url: string) => Promise<void>;
  screenAccessStatus?: () => "granted" | "unknown";
} = {}) {
  const native = createFakeNative();
  const recordingsDir = join(tempDirectory(), "recordings");
  const published: AudioCaptureState[] = [];
  const target = { space: "comma-drive", localRoot: join(tempDirectory(), "Drive") };
  const drive = {
    target: vi.fn(async () => target),
    open: vi.fn(async () => ({ status: "opened" as const })),
    save: vi.fn(async (sourcePath: string, _target: typeof target) => {
      lastDriveBytes.set(recordingsDir, await readFile(sourcePath));
      const destination = join(target.localRoot, "recording", basename(sourcePath));
      await mkdir(join(target.localRoot, "recording"), { recursive: true });
      await copyFile(sourcePath, destination);
      return {
        driveFile: { space: target.space, path: `recording/${basename(sourcePath)}` },
        file: {
          mediaType: "audio/mp4" as const,
          name: basename(sourcePath),
          size: (await stat(sourcePath)).size,
        },
      };
    }),
  };
  // Fault-injection encoder: preserve PCM so pause, mixing and alignment tests
  // inspect the signal. The Electron compression E2E uses the real Apple encoder.
  const encoder = {
    encode: vi.fn(async (sourcePath: string) => {
      const outputPath = sourcePath.replace(/\.wav$/, ".m4a");
      await copyFile(sourcePath, outputPath);
      return outputPath;
    }),
  };
  const service = new AudioCaptureService({
    encoder,
    ...(onSaved ? { onSaved } : {}),
    loadNative: async () => (nativeAvailable ? native : undefined),
    ...(microphone ? { microphone } : {}),
    ...(now ? { now } : {}),
    onStateChanged: (state) => published.push(state),
    ...(openExternalUrl ? { openExternalUrl } : {}),
    recordingsDir,
    ...(screenAccessStatus ? { screenAccessStatus } : {}),
    drive,
  });

  const admitted = createAdmittedService(service);
  return {
    admitted,
    native,
    published,
    recordingsDir,
    service: admitted.service,
    rawService: service,
    drive,
    encoder,
  };
}

/** Runs `stop` inside a real Session admission, the way the gateway does. */
function createAdmittedService(service: AudioCaptureService, userId = "user-capture") {
  const authority = new MainProductCredentialAuthority({
    authorityInstanceId: `authority-capture-${Math.random()}`,
    trustedAudience: "https://api.comma.example",
  });
  const signedIn = authority.acceptVerifiedCredential({
    audience: "https://api.comma.example",
    email: "capture@example.com",
    expiresAtEpochSeconds: 1_900_000_000,
    sessionId: `session-capture-${Math.random()}`,
    token: "main_secret",
    userId,
  });
  const session = sessionProductLease(signedIn);
  if (!session) throw new Error("Expected signed-in Session lease.");
  const guard = new MainNativeSessionAdmissionGuard(authority);

  return {
    service: {
      state: service.state.bind(service),
      sources: service.sources.bind(service),
      start: (input: Omit<AudioCaptureStartInput, "session">) =>
        Promise.resolve(
          guard.run({
            contract: audioCaptureStartCapability.contract,
            handler: () => service.start({ ...input, session }),
            input: { ...input, session },
          })
        ),
      pause: service.pause.bind(service),
      resume: service.resume.bind(service),
      cancel: service.cancel.bind(service),
      close: service.close.bind(service),
      openPermissionSettings: service.openPermissionSettings.bind(service),
    },
    selectMicrophone: (deviceId: string | null) =>
      Promise.resolve(
        guard.run({
          contract: audioCaptureSelectMicrophoneCapability.contract,
          handler: () => service.selectMicrophone({ session, deviceId }),
          input: { session, deviceId },
        })
      ),
    stop: (afterSaved?: Parameters<AudioCaptureService["stop"]>[1]) =>
      Promise.resolve(
        guard.run({
          contract: audioCaptureStopCapability.contract,
          handler: () => service.stop({ session }, afterSaved),
          input: { session },
        })
      ),
  };
}

const lastDriveBytes = new Map<string, Buffer>();

/** The fake store keeps the bytes it was handed so tests can inspect them. */
async function driveStoreCopy(recordingsDir: string) {
  const bytes = lastDriveBytes.get(recordingsDir);
  if (!bytes) throw new Error("no snapshot captured");
  return bytes;
}

function tempDirectory() {
  const directory = mkdtempSync(join(tmpdir(), "comma-audio-capture-"));
  temporaryDirectories.push(directory);
  return directory;
}

/** Capture writes are queued off the callback; let the tail drain. */
async function settle() {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

describe("capture initialization ownership", () => {
  it.each(["cancel", "close"] as const)(
    "drains an opening sink before %s completes",
    async (action) => {
      const { service, native, recordingsDir, published } = createService();
      const entered = Promise.withResolvers<void>();
      const gate = Promise.withResolvers<void>();
      const original = WavSink.open.bind(WavSink);
      let sink: WavSink | undefined;
      vi.spyOn(WavSink, "open").mockImplementationOnce(async (input) => {
        entered.resolve();
        await gate.promise;
        return (sink = await original(input));
      });
      const starting = service.start({ source: { kind: "system" }, microphone: true });
      await entered.promise;
      const recordingPublished = published.some(
        (state) => state.status === "recording"
      );
      let done = false;
      const cancelling = service[action]().then(() => {
        done = true;
      });
      await settle();
      const completedBeforeOpen = done;
      gate.resolve();
      await Promise.all([starting, cancelling]);
      try {
        expect(recordingPublished).toBe(false);
        expect(completedBeforeOpen).toBe(false);
        expect(native.taps[0]?.stopped).toBe(true);
        expect(await readdir(recordingsDir)).toEqual([]);
      } finally {
        await sink?.discard();
        await service.close();
      }
    }
  );

  it("saves frames received while Stop waits for sink initialization", async () => {
    const { admitted, service, native, recordingsDir, drive } = createService();
    const entered = Promise.withResolvers<void>();
    const gate = Promise.withResolvers<void>();
    const original = WavSink.open.bind(WavSink);
    let sink: WavSink | undefined;
    vi.spyOn(WavSink, "open").mockImplementationOnce(async (input) => {
      entered.resolve();
      await gate.promise;
      return (sink = await original(input));
    });
    const starting = service.start({ source: { kind: "system" } });
    await entered.promise;
    native.taps[0]?.emit(new Float32Array(48 * 2).fill(0.5));
    const stopping = admitted.stop();
    await settle();
    gate.resolve();
    await starting;
    const result = await stopping;
    try {
      expect(result.status).toBe("ready");
      expect(drive.save).toHaveBeenCalledOnce();
      expect(await readdir(recordingsDir)).toEqual([]);
    } finally {
      await sink?.discard();
      await service.close();
    }
  });

  it.each(["cancel", "close"] as const)(
    "%s invalidates admission before the tap exists",
    async (action) => {
      const { service, native, drive } = createService();
      const entered = Promise.withResolvers<void>();
      const gate = Promise.withResolvers<void>();
      const target = drive.target.getMockImplementation()!;
      drive.target.mockImplementationOnce(async () => {
        entered.resolve();
        await gate.promise;
        return target();
      });
      const starting = service.start({ source: { kind: "system" } });
      await entered.promise;
      const cancelling = service[action]();
      gate.resolve();
      await Promise.all([starting, cancelling]);
      try {
        expect(native.taps).toHaveLength(0);
        if (action === "close") {
          await expect(service.start({ source: { kind: "system" } })).rejects.toThrow(
            "closed"
          );
        } else {
          await expect(
            service.start({ source: { kind: "system" } })
          ).resolves.toMatchObject({ status: "recording" });
        }
      } finally {
        await service.close();
      }
    }
  );

  it("releases the active slot after sink initialization fails", async () => {
    const { service } = createService();
    vi.spyOn(WavSink, "open").mockRejectedValueOnce(new Error("ENOSPC"));
    await expect(service.start({ source: { kind: "system" } })).resolves.toMatchObject({
      status: "idle",
    });
    try {
      await expect(
        service.start({ source: { kind: "system" } })
      ).resolves.toMatchObject({ status: "recording" });
    } finally {
      await service.close();
    }
  });

  it("duplicate cancellations share cleanup until an opening sink is retired", async () => {
    const { service, recordingsDir } = createService();
    const entered = Promise.withResolvers<void>();
    const gate = Promise.withResolvers<void>();
    const original = WavSink.open.bind(WavSink);
    vi.spyOn(WavSink, "open").mockImplementationOnce(async (input) => {
      entered.resolve();
      await gate.promise;
      return original(input);
    });
    const starting = service.start({ source: { kind: "system" } });
    await entered.promise;
    const first = service.cancel();
    const second = service.cancel();
    await expect(service.start({ source: { kind: "system" } })).rejects.toThrow(
      "already in progress"
    );
    gate.resolve();
    await Promise.all([starting, first, second]);
    expect(await readdir(recordingsDir)).toEqual([]);
    await expect(service.start({ source: { kind: "system" } })).resolves.toMatchObject({
      status: "recording",
    });
    await service.close();
  });
});
