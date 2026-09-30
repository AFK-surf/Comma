// Real Main capture finalization, Apple encoder, Drive files and ASR client.
// Only the live tap and ASR provider are deterministic fixtures.
import { execFile } from "node:child_process";
import {
  copyFile,
  mkdtemp,
  mkdir,
  readFile,
  readdir,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import {
  audioCaptureStartCapability,
  audioCaptureStopCapability,
  type SynchronicityState,
} from "@comma/native-bridge";
import { sessionProductLease } from "@comma/session-contract";
import { AudioCaptureService } from "../../../src/main/modules/audio-capture";
import { HelperRecordingEncoder } from "../../../src/main/modules/audio-capture/encoder";
import { DriveRecordingStore } from "../../../src/main/modules/audio-capture/drive-recordings";
import { RecordingTranscriptionService } from "../../../src/main/modules/audio-capture/transcription";
import { MainProductCredentialAuthority } from "../../../src/main/modules/session/main-product-credential-authority";
import { MainNativeSessionAdmissionGuard } from "../../../src/main/modules/session/native-session-admission";

export async function compressionScenario(sampleRate: number, helperPath: string) {
  const directory = await mkdtemp(join(tmpdir(), "comma-compression-e2e-"));
  const localRoot = join(directory, "Drive");
  const recordingsDir = join(directory, "recordings");
  const authority = new MainProductCredentialAuthority({
    authorityInstanceId: "compression-e2e",
    trustedAudience: "https://comma.example",
  });
  const session = sessionProductLease(
    authority.acceptVerifiedCredential({
      audience: "https://comma.example",
      email: "fixture@example.com",
      expiresAtEpochSeconds: Math.floor(Date.now() / 1000) + 600,
      sessionId: "fixture",
      token: "test-only",
      userId: "fixture",
    })
  )!;
  const guard = new MainNativeSessionAdmissionGuard(authority);
  let system!: (frames: Float32Array) => void;
  let microphone!: (frames: Float32Array) => void;
  let openedPath = "";
  const store = new DriveRecordingStore(
    {
      state: async () =>
        ({
          status: "ready",
          defaultSpace: "fixture",
          spaces: [{ id: "fixture", sourcePath: localRoot }],
        }) as SynchronicityState,
      importFile: async ({ sourcePath, path }) => {
        await mkdir(dirname(join(localRoot, path)), { recursive: true });
        await copyFile(sourcePath, join(localRoot, path));
        return { status: "done" };
      },
      write: async ({ path, content }) => {
        await writeFile(join(localRoot, path), Buffer.from(content, "base64"));
        return { status: "done" };
      },
    },
    async (path) => {
      openedPath = path;
      return "";
    }
  );
  let uploadIsM4A = false;
  const asr = new RecordingTranscriptionService(store, () => ({
    url: new URL("https://comma.example/v1/comma/me/recordings/transcribe"),
    assertCurrent() {},
    fetch: async (_url, init) => {
      const bytes = Buffer.from(await (init!.body as Blob).arrayBuffer());
      uploadIsM4A = bytes.toString("ascii", 4, 8) === "ftyp";
      return new Response(
        `event: transcription\ndata: ${JSON.stringify({ status: "ready", result: { transcript: "[00:00] Speaker: Meeting fixture", duration_seconds: 5, chunks: [] } })}\n\n`,
        { headers: { "content-type": "text/event-stream" } }
      );
    },
  }));
  const transcriptionDone = Promise.withResolvers<void>();
  const service = new AudioCaptureService({
    recordingsDir,
    drive: store,
    encoder: new HelperRecordingEncoder(helperPath),
    now: () => new Date(2026, 8, 9, 23, 59).getTime(),
    onStateChanged() {},
    onSaved: async (...args) => {
      try {
        await asr.process(...args);
        transcriptionDone.resolve();
      } catch (error) {
        transcriptionDone.reject(error);
      }
    },
    microphone: {
      available: () => true,
      devices: async () => ({ devices: [] }),
      start: async (input) => {
        microphone = input.onFrames;
        return { stop: async () => {} };
      },
    },
    loadNative: async () => ({
      applications: () => [],
      isUsingMicrophone: () => false,
      onApplicationListChanged: () => () => {},
      tapSystem: (input) => {
        system = input.onFrames;
        return { channels: 1, sampleRate, stop() {} };
      },
      tapApplication: (input) => {
        system = input.onFrames;
        return { channels: 1, sampleRate, stop() {} };
      },
    }),
  });
  try {
    const input = {
      session,
      source:
        sampleRate === 48000
          ? { kind: "system" as const }
          : { kind: "application" as const, processId: 42 },
      microphone: true,
    };
    await guard.run({
      contract: audioCaptureStartCapability.contract,
      input,
      handler: () => service.start(input),
    });
    const tone = (frequency: number, seconds: number) =>
      Float32Array.from(
        { length: sampleRate * seconds },
        (_, i) => 0.6 * Math.sin((2 * Math.PI * frequency * i) / sampleRate)
      );
    system(tone(440, 3));
    microphone(tone(880, 3));
    await service.pause();
    system(tone(1100, 1));
    microphone(tone(1100, 1));
    await service.resume();
    system(tone(440, 2));
    microphone(tone(880, 2));
    const result = await guard.run({
      contract: audioCaptureStopCapability.contract,
      input: { session },
      handler: () => service.stop({ session }),
    });
    if (result.status !== "ready")
      throw new Error(result.reason ?? "Recording did not save");
    await transcriptionDone.promise;
    const recording = result.recording;
    const path = join(localRoot, recording.driveFile.path);
    await store.open(recording.driveFile);
    const decoded = join(directory, "decoded.wav");
    await promisify(execFile)("/usr/bin/afconvert", [
      "-f",
      "WAVE",
      "-d",
      "LEI16",
      path,
      decoded,
    ]);
    const bytes = await readFile(decoded);
    let data = Buffer.alloc(0),
      rate = 0,
      channels = 0;
    for (let offset = 12; offset + 8 <= bytes.length; ) {
      const name = bytes.toString("ascii", offset, offset + 4),
        size = bytes.readUInt32LE(offset + 4);
      if (name === "fmt ") {
        channels = bytes.readUInt16LE(offset + 10);
        rate = bytes.readUInt32LE(offset + 12);
      }
      if (name === "data") data = bytes.subarray(offset + 8, offset + 8 + size);
      offset += 8 + size + (size % 2);
    }
    const amplitude = (hz: number) => {
      let real = 0,
        imaginary = 0;
      const start = Math.floor(rate / 2),
        count = rate * 2;
      for (let i = start; i < start + count; i++) {
        const value = data.readInt16LE(i * 2) / 32768;
        real += value * Math.cos((2 * Math.PI * hz * i) / rate);
        imaginary += value * Math.sin((2 * Math.PI * hz * i) / rate);
      }
      return (2 * Math.hypot(real, imaginary)) / count;
    };
    // The background callback releases its staging source after it returns.
    for (
      let attempt = 0;
      attempt < 20 && (await readdir(recordingsDir)).length;
      attempt++
    )
      await new Promise((resolve) => setTimeout(resolve, 10));
    return {
      recording,
      channels,
      decodedDurationMs: (data.length / 2 / rate) * 1000,
      systemAmplitude: amplitude(440),
      microphoneAmplitude: amplitude(880),
      pausedAmplitude: amplitude(1100),
      uploadIsM4A,
      openedCorrectFile: openedPath === (await realpath(path)),
      artifacts: await readdir(dirname(path)),
      staging: await readdir(recordingsDir),
      transcript: await readFile(path.replace(/\.m4a$/, ".transcript.txt"), "utf8"),
    };
  } finally {
    await service.close();
    await rm(directory, { recursive: true, force: true });
  }
}

/** Exercise the native encoder with a stereo source; the archive contract is always mono. */
export async function stereoCompressionScenario(helperPath: string) {
  const directory = await mkdtemp(join(tmpdir(), "comma-stereo-encoder-e2e-"));
  try {
    const sampleRate = 48_000;
    const frames = sampleRate;
    const data = Buffer.alloc(frames * 2 * 2);
    for (let frame = 0; frame < frames; frame++) {
      data.writeInt16LE(
        Math.round(12_000 * Math.sin((2 * Math.PI * 440 * frame) / sampleRate)),
        frame * 4
      );
      data.writeInt16LE(
        Math.round(12_000 * Math.sin((2 * Math.PI * 880 * frame) / sampleRate)),
        frame * 4 + 2
      );
    }
    const wav = Buffer.alloc(44 + data.length);
    wav.write("RIFF", 0);
    wav.writeUInt32LE(36 + data.length, 4);
    wav.write("WAVEfmt ", 8);
    wav.writeUInt32LE(16, 16);
    wav.writeUInt16LE(1, 20);
    wav.writeUInt16LE(2, 22);
    wav.writeUInt32LE(sampleRate, 24);
    wav.writeUInt32LE(sampleRate * 4, 28);
    wav.writeUInt16LE(4, 32);
    wav.writeUInt16LE(16, 34);
    wav.write("data", 36);
    wav.writeUInt32LE(data.length, 40);
    data.copy(wav, 44);
    const source = join(directory, "stereo.wav");
    const encoded = join(directory, "stereo.m4a");
    const decoded = join(directory, "decoded.wav");
    await writeFile(source, wav);
    await promisify(execFile)(helperPath, ["--encode-recording", source, encoded]);
    await promisify(execFile)("/usr/bin/afconvert", [
      "-f",
      "WAVE",
      "-d",
      "LEI16",
      encoded,
      decoded,
    ]);
    const bytes = await readFile(decoded);
    for (let offset = 12; offset + 8 <= bytes.length; ) {
      const name = bytes.toString("ascii", offset, offset + 4);
      const size = bytes.readUInt32LE(offset + 4);
      if (name === "fmt ") return { channels: bytes.readUInt16LE(offset + 10) };
      offset += 8 + size + (size % 2);
    }
    throw new Error("Decoded WAV has no format chunk");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
