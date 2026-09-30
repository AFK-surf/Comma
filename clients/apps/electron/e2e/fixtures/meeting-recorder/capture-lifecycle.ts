// Fault injection only: real Electron Main, Session admission and filesystem;
// controllable audio frames and sink-open timing, without microphone/TCC access.
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import {
  audioCaptureStartCapability,
  audioCaptureStopCapability,
} from "@comma/native-bridge";
import { sessionProductLease } from "@comma/session-contract";
import { AudioCaptureService } from "../../../src/main/modules/audio-capture";
import { WavSink } from "../../../src/main/modules/audio-capture/wav";
import { MainProductCredentialAuthority } from "../../../src/main/modules/session/main-product-credential-authority";
import { MainNativeSessionAdmissionGuard } from "../../../src/main/modules/session/native-session-admission";

export async function captureLifecycleScenario(action: "cancel" | "stop" | "close") {
  const directory = await mkdtemp(join(tmpdir(), "comma-capture-lifecycle-"));
  const authority = new MainProductCredentialAuthority({
    authorityInstanceId: "capture-lifecycle-e2e",
    trustedAudience: "https://capture.example",
  });
  const session = sessionProductLease(
    authority.acceptVerifiedCredential({
      audience: "https://capture.example",
      email: "fixture@example.com",
      expiresAtEpochSeconds: Math.floor(Date.now() / 1000) + 600,
      sessionId: "capture-fixture",
      token: "test-only",
      userId: "capture-fixture",
    })
  )!;
  const guard = new MainNativeSessionAdmissionGuard(authority);
  let emit: ((frames: Float32Array) => void) | undefined;
  let tapStopped = false;
  let savedBytes = 0;
  let recordingPublishedBeforeOpen = false;
  let opened = false;
  const entered = Promise.withResolvers<void>();
  const gate = Promise.withResolvers<void>();
  const originalOpen = WavSink.open;
  let lateSink: WavSink | undefined;
  WavSink.open = async (input) => {
    entered.resolve();
    await gate.promise;
    lateSink = await originalOpen(input);
    opened = true;
    return lateSink;
  };
  const service = new AudioCaptureService({
    // This fixture isolates sink-open ownership. Compression has a separate E2E.
    encoder: { encode: async (path) => path },
    recordingsDir: directory,
    onStateChanged: (state) => {
      if (state.status === "recording" && !opened) recordingPublishedBeforeOpen = true;
    },
    loadNative: async () => ({
      applications: () => [],
      isUsingMicrophone: () => false,
      onApplicationListChanged: () => () => {},
      tapApplication: () => {
        throw new Error("Not used in this fixture.");
      },
      tapSystem: ({ onFrames }) => {
        emit = onFrames;
        return {
          channels: 2,
          sampleRate: 48000,
          stop: () => {
            tapStopped = true;
          },
        };
      },
    }),
    drive: {
      target: async () => ({ space: "fixture", localRoot: directory }),
      open: async () => ({ status: "opened" }),
      save: async (path) => {
        const bytes = await readFile(path);
        savedBytes = bytes.readUInt32LE(40);
        return {
          driveFile: { space: "fixture", path: `recording/${basename(path)}` },
          file: { mediaType: "audio/wav", name: basename(path), size: bytes.length },
        };
      },
    },
  });
  const input = { session, source: { kind: "system" as const } };
  const starting = Promise.resolve(
    guard.run({
      contract: audioCaptureStartCapability.contract,
      input,
      handler: () => service.start(input),
    })
  );
  try {
    await entered.promise;
    emit?.(new Float32Array(48 * 2).fill(0.5));
    let completed = false;
    const ending = (
      action === "stop"
        ? Promise.resolve(
            guard.run({
              contract: audioCaptureStopCapability.contract,
              input: { session },
              handler: () => service.stop({ session }),
            })
          )
        : service[action]()
    ).then(() => {
      completed = true;
    });
    await new Promise((resolve) => setTimeout(resolve, 20));
    const completedBeforeOpen = completed;
    gate.resolve();
    await Promise.all([starting, ending]);
    return {
      completedBeforeOpen,
      recordingPublishedBeforeOpen,
      tapStopped,
      savedBytes,
      files: await readdir(directory),
    };
  } finally {
    gate.resolve();
    await starting.catch(() => undefined);
    await service.close();
    await lateSink?.discard();
    WavSink.open = originalOpen;
    await rm(directory, { recursive: true, force: true });
  }
}
