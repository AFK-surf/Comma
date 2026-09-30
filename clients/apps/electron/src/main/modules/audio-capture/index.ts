import { randomUUID } from "node:crypto";
import { mkdir, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import type {
  AudioCaptureSource,
  AudioCaptureOpenSavedInput,
  AudioCaptureOpenSavedResult,
  AudioCaptureSourcesResult,
  AudioCaptureStartInput,
  AudioCaptureState,
  AudioCaptureStopInput,
  AudioCaptureStopResult,
  AudioCaptureMicrophones,
  AudioCaptureRecording,
  AudioCaptureSelectMicrophoneInput,
} from "@comma/native-bridge";
import { getCurrentNativeSessionAdmission } from "../session/native-session-admission";
import {
  loadNativeAudioCapture,
  type NativeAudioCapture,
  type NativeAudioTap,
} from "./native-audio";
import { frameLevel, WavSink } from "./wav";
import { mixMono, readWavPcm } from "./mix";
import type { MicrophoneCapture, MicrophoneSession } from "./microphone";
import type { AudioCaptureDriveStore, RecordingDriveTarget } from "./drive-recordings";
import type { RecordingEncoder } from "./encoder";

/** Bound one recording's PCM file before handing it to Drive. */
const MAX_RECORDING_BYTES = 480 * 1024 * 1024;
const DEFAULT_MAX_DURATION_MS = 2 * 60 * 60 * 1_000;
/** Matches the composer waveform step so published levels map 1:1 to bars. */
const LEVEL_PUBLISH_INTERVAL_MS = 80;
/** Attack is immediate, release is smoothed; a meter that only falls slowly. */
const LEVEL_RELEASE = 0.65;
/** All-zero PCM for this long after start is treated as a missing TCC grant. */
const SILENCE_SUSPECT_MS = 4_000;
const MACOS_AUDIO_CAPTURE_SETTINGS_URL =
  "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture";

export type ScreenAccessStatus =
  | "granted"
  | "denied"
  | "not-determined"
  | "restricted"
  | "unknown";

export interface AudioCaptureProvider {
  cancel(input: void): Promise<AudioCaptureState>;
  openPermissionSettings(input: void): Promise<{ opened: boolean }>;
  openSaved(input: AudioCaptureOpenSavedInput): Promise<AudioCaptureOpenSavedResult>;
  pause(input: void): Promise<AudioCaptureState>;
  resume(input: void): Promise<AudioCaptureState>;
  sources(input: void): Promise<AudioCaptureSourcesResult>;
  microphones(input: void): Promise<AudioCaptureMicrophones>;
  selectMicrophone(
    input: AudioCaptureSelectMicrophoneInput
  ): Promise<AudioCaptureState>;
  start(input: AudioCaptureStartInput): Promise<AudioCaptureState>;
  state(input: void): Promise<AudioCaptureState>;
  stop(input: AudioCaptureStopInput): Promise<AudioCaptureStopResult>;
}

type ActiveCapture = {
  driveTarget: RecordingDriveTarget;
  ownerUserId: string;
  capped: boolean;
  channels: number;
  micLevel: number;
  micPath: string;
  micSession: MicrophoneSession | undefined;
  micSink: WavSink | undefined;
  microphone: AudioCaptureState["microphone"];
  microphoneDeviceId: string | undefined;
  micGeneration: number;
  micTask: Promise<void> | undefined;
  maxDurationMs: number;
  path: string;
  /** Frames are dropped, not queued, while paused; both tracks skip the same wall time. */
  paused: boolean;
  pausedAtMs: number;
  /** Wall time spent paused so far; excluded from the silence and length heuristics. */
  pausedTotalMs: number;
  pending: Float32Array[];
  sampleRate: number;
  /** A non-zero sample has arrived; distinguishes silence from a denied tap. */
  sawSignal: boolean;
  sink: WavSink | undefined;
  source: AudioCaptureSource;
  startedAtMs: number;
  archiveAtMs: number;
  stopped: boolean;
  tap: NativeAudioTap;
};

/**
 * Main owns the platform audio tap.
 *
 * Captured audio is written straight to a Main-private file and never crosses
 * the bridge; renderers observe a bounded state snapshot (status, duration,
 * meter level) and, once a recording is stopped, a logical Drive file reference.
 * The tap is a single-session resource, so a second `start` is refused rather
 * than queued.
 */
export class AudioCaptureService implements AudioCaptureProvider {
  readonly #loadNative: () => Promise<NativeAudioCapture | undefined>;
  readonly #microphone: MicrophoneCapture | undefined;
  readonly #now: () => number;
  readonly #onStateChanged: (state: AudioCaptureState) => void;
  readonly #openExternalUrl: (url: string) => Promise<void>;
  readonly #recordingsDir: string;
  readonly #drive: AudioCaptureDriveStore;
  readonly #encoder: RecordingEncoder;
  readonly #onSaved:
    | ((
        recording: AudioCaptureRecording,
        target: RecordingDriveTarget,
        sourcePath: string
      ) => Promise<void>)
    | undefined;
  #starting: Promise<AudioCaptureState> | undefined;
  #startCancelled = false;
  #cancelling: Promise<AudioCaptureState> | undefined;
  #closed = false;
  #active: ActiveCapture | undefined;
  #available: boolean | undefined;
  #level = 0;
  #levelPublishedAtMs = 0;
  #permission: AudioCaptureState["permission"];
  #reason: string | undefined;
  #revision = 1;
  #status: AudioCaptureState["status"] = "idle";

  constructor({
    loadNative = loadNativeAudioCapture,
    microphone,
    now = () => Date.now(),
    onStateChanged,
    openExternalUrl = async () => {
      throw new Error("Opening system settings is unavailable in this runtime.");
    },
    recordingsDir,
    screenAccessStatus,
    drive,
    encoder,
    onSaved,
  }: {
    loadNative?: () => Promise<NativeAudioCapture | undefined>;
    /** Microphone intake; absent means system audio only. */
    microphone?: MicrophoneCapture | undefined;
    now?: () => number;
    onStateChanged: (state: AudioCaptureState) => void;
    openExternalUrl?: (url: string) => Promise<void>;
    recordingsDir: string;
    /**
     * Electron `systemPreferences.getMediaAccessStatus("screen")`. Screen
     * Recording implies system-audio capture; anything else stays `unknown`.
     */
    screenAccessStatus?: (() => ScreenAccessStatus) | undefined;
    drive: AudioCaptureDriveStore;
    encoder: RecordingEncoder;
    onSaved?: (
      recording: AudioCaptureRecording,
      target: RecordingDriveTarget,
      sourcePath: string
    ) => Promise<void>;
  }) {
    this.#loadNative = loadNative;
    this.#microphone = microphone;
    this.#now = now;
    this.#onStateChanged = onStateChanged;
    this.#openExternalUrl = openExternalUrl;
    this.#recordingsDir = recordingsDir;
    this.#drive = drive;
    this.#encoder = encoder;
    this.#onSaved = onSaved;
    this.#permission = readScreenAccess(screenAccessStatus) ? "granted" : "unknown";
  }

  async openPermissionSettings(): Promise<{ opened: boolean }> {
    try {
      await this.#openExternalUrl(MACOS_AUDIO_CAPTURE_SETTINGS_URL);
      return { opened: true };
    } catch {
      return { opened: false };
    }
  }

  async state(): Promise<AudioCaptureState> {
    await this.#resolveNative();
    return this.#snapshot();
  }

  async sources(): Promise<AudioCaptureSourcesResult> {
    const native = await this.#resolveNative();
    if (!native) return { applications: [] };
    try {
      return {
        applications: native
          .applications()
          .filter((application) => application.processId > 0)
          .slice(0, 256),
      };
    } catch {
      return { applications: [] };
    }
  }

  async start(
    input: AudioCaptureStartInput,
    archiveAtMs?: number
  ): Promise<AudioCaptureState> {
    const admission = getCurrentNativeSessionAdmission();
    if (this.#closed) throw new Error("Audio capture is closed.");
    if (
      this.#starting ||
      this.#cancelling ||
      this.#active ||
      this.#status === "finalizing"
    ) {
      throw new Error("A recording is already in progress.");
    }
    this.#startCancelled = false;
    const starting = this.#start(input, admission.principalUserId, archiveAtMs);
    this.#starting = starting;
    try {
      return await starting;
    } finally {
      this.#starting = undefined;
    }
  }

  async #start(
    input: AudioCaptureStartInput,
    ownerUserId: string,
    archiveAtMs?: number
  ): Promise<AudioCaptureState> {
    const native = await this.#resolveNative();
    if (!native || this.#startCancelled) return this.#snapshot();
    if (this.#active) {
      // Refuse loudly: returning the in-flight snapshot would let a second
      // caller mistake someone else's recording for its own.
      throw new Error("A recording is already in progress.");
    }

    // RecordingSave.tla: Begin fixes this recording's owner and logical target.
    const driveTarget = await this.#drive.target();
    if (this.#startCancelled) return this.#snapshot();
    const startedAtMs = this.#now();
    const path = join(this.#recordingsDir, recordingFileName(startedAtMs));
    let capture: ActiveCapture | undefined;

    const onFrames = (frames: Float32Array) => {
      if (!capture || capture.stopped || capture.paused) return;
      if (!capture.sink) {
        capture.pending.push(frames);
        return;
      }
      this.#ingest(capture, frames);
    };
    const onError = () => {
      if (!capture) return;
      this.#capTap(capture, "The system audio tap stopped unexpectedly.");
    };

    let tap: NativeAudioTap;
    try {
      await mkdir(this.#recordingsDir, { recursive: true });
      if (this.#startCancelled) return this.#snapshot();
      tap =
        input.source.kind === "application"
          ? native.tapApplication({
              onError,
              onFrames,
              processId: input.source.processId,
            })
          : native.tapSystem({
              excludedProcessIds: [process.pid],
              onError,
              onFrames,
            });
    } catch (error) {
      return this.#publish({ reason: startFailureReason(error) });
    }

    capture = {
      driveTarget,
      ownerUserId,
      capped: false,
      channels: tap.channels,
      micLevel: 0,
      micPath: path.replace(/\.wav$/, ".mic.wav"),
      micSession: undefined,
      micSink: undefined,
      microphone: "off",
      microphoneDeviceId: undefined,
      micGeneration: 0,
      micTask: undefined,
      maxDurationMs: input.maxDurationMs ?? DEFAULT_MAX_DURATION_MS,
      path,
      paused: false,
      pausedAtMs: 0,
      pausedTotalMs: 0,
      pending: [],
      sampleRate: tap.sampleRate,
      sawSignal: false,
      sink: undefined,
      source: input.source,
      startedAtMs,
      archiveAtMs: archiveAtMs ?? startedAtMs,
      stopped: false,
      tap,
    };
    this.#active = capture;
    this.#level = 0;
    this.#levelPublishedAtMs = 0;
    this.#publish({ reason: undefined });

    try {
      // Frames start arriving the moment the tap opens, so they queue until the
      // sink exists rather than being dropped on the floor.
      const sink = await WavSink.open({
        channels: tap.channels,
        path,
        sampleRate: tap.sampleRate,
      });
      // CaptureInitialization.tla: LateOpen is owned until cancellation drains.
      if (this.#startCancelled) {
        await sink.discard();
        return this.#snapshot();
      }
      capture.sink = sink;
      const pending = capture.pending.splice(0, capture.pending.length);
      for (const frames of pending) this.#ingest(capture, frames);
      if (input.microphone) await this.#changeMicrophone(capture, "default");
      if (!this.#startCancelled) this.#publish({ status: "recording" });
    } catch (error) {
      await this.#teardown(capture);
      if (this.#active === capture) this.#active = undefined;
      if (this.#startCancelled) return this.#snapshot();
      return this.#publish({ reason: startFailureReason(error), status: "idle" });
    }

    return this.#snapshot();
  }

  async stop(
    _input: AudioCaptureStopInput,
    afterSaved = this.#onSaved
  ): Promise<AudioCaptureStopResult> {
    const admission = getCurrentNativeSessionAdmission();
    // Stop saves frames accepted during initialization; cancel/close discard them.
    await this.#starting?.catch(() => undefined);
    const capture = this.#active;
    if (!capture) return { status: "unavailable" };
    if (capture.ownerUserId !== admission.principalUserId) {
      return {
        status: "unavailable",
        reason: "Sign in to the account that started this recording to save it.",
      };
    }

    // RecordingSave.tla: ClaimStop admits exactly one finalizer.
    this.#publish({ status: "finalizing" });
    this.#stopTap(capture);
    this.#active = undefined;
    const micSummary = await this.#finishMicrophone(capture);

    let summary;
    try {
      summary = await capture.sink?.finalize();
    } catch {
      await rm(capture.path, { force: true });
      this.#publish({ reason: "The recording could not be written.", status: "idle" });
      return { status: "unavailable" };
    }

    if (summary && summary.byteLength > 0 && micSummary && micSummary.byteLength > 0) {
      try {
        summary = await this.#mixMicrophone(capture, summary.sampleRate);
      } catch (error) {
        // The system track is still a valid recording on its own.
        this.#publish({ reason: `Microphone mix failed: ${describeError(error)}` });
      }
    }
    await rm(capture.micPath, { force: true }).catch(() => undefined);

    if (!summary || summary.byteLength === 0) {
      await rm(capture.path, { force: true });
      this.#publish({ reason: "The recording captured no audio.", status: "idle" });
      return { status: "unavailable" };
    }

    let encodedPath: string;
    try {
      encodedPath = await this.#encoder.encode(capture.path);
    } catch {
      const reason =
        "The recording could not be compressed. The WAV is retained in Comma's local recordings folder on this device.";
      this.#publish({ reason, status: "idle" });
      return { reason, status: "unavailable" };
    }

    try {
      const saved = await this.#drive.save(
        encodedPath,
        capture.driveTarget,
        capture.archiveAtMs
      );
      // RecordingSave.tla: Ack -> Cleanup. Cleanup failure leaves a spare copy;
      // it cannot turn a confirmed Drive save into a reported failure.
      await rm(capture.path, { force: true }).catch(() => undefined);
      const recording = {
        channels: summary.channels,
        durationMs: summary.durationMs,
        ...saved,
        sampleRate: summary.sampleRate,
      };
      // Background consumers use the confirmed Drive copy, not the encoder scratch
      // file. A saved meeting journal can retry this path after callback failure
      // or restart, even after the scratch file is removed.
      if (afterSaved) {
        void Promise.resolve()
          .then(() =>
            afterSaved(
              recording,
              capture.driveTarget,
              join(capture.driveTarget.localRoot, recording.driveFile.path)
            )
          )
          .catch(() => console.warn("Recording transcription did not complete."))
          .finally(() => rm(encodedPath, { force: true }).catch(() => undefined));
      } else {
        await rm(encodedPath, { force: true }).catch(() => undefined);
      }
      return {
        recording,
        status: "ready",
      };
    } catch {
      const reason =
        "The recording could not be saved to Drive. The WAV and M4A are retained in Comma's local recordings folder on this device.";
      // RecordingSave.tla: Fail retains the completed file without retrying Put.
      this.#publish({ reason, status: "idle" });
      return { reason, status: "unavailable" };
    } finally {
      if (this.#status !== "idle") this.#publish({ status: "idle" });
    }
  }

  async openSaved(
    input: AudioCaptureOpenSavedInput
  ): Promise<AudioCaptureOpenSavedResult> {
    getCurrentNativeSessionAdmission();
    return this.#drive.open(input.driveFile);
  }

  async cancel(): Promise<AudioCaptureState> {
    if (this.#cancelling) return this.#cancelling;
    const cancelling = this.#cancel();
    this.#cancelling = cancelling;
    try {
      return await cancelling;
    } finally {
      this.#cancelling = undefined;
    }
  }

  async #cancel(): Promise<AudioCaptureState> {
    // CaptureInitialization.tla: Cancel invalidates admission even before a tap exists.
    this.#startCancelled = true;
    const capture = this.#active;
    if (!capture && !this.#starting) return this.#snapshot();
    this.#publish({ status: "finalizing" });
    this.#active = undefined;
    if (capture) this.#stopTap(capture);
    // Do not report cleanup complete while a late sink/helper can still open.
    await this.#starting?.catch(() => undefined);
    if (capture) await this.#teardown(capture);
    return this.#publish({ reason: undefined, status: "idle" });
  }

  /**
   * Holds the recording without releasing the tap or the microphone helper:
   * frames are dropped rather than written, so the bytes-derived duration
   * freezes and both tracks stay aligned on resume.
   */
  async pause(): Promise<AudioCaptureState> {
    const capture = this.#active;
    if (!capture || this.#status !== "recording") return this.#snapshot();
    capture.paused = true;
    capture.pausedAtMs = this.#now();
    capture.micLevel = 0;
    this.#level = 0;
    return this.#publish({ status: "paused" });
  }

  async resume(): Promise<AudioCaptureState> {
    const capture = this.#active;
    if (!capture || this.#status !== "paused") return this.#snapshot();
    capture.pausedTotalMs += Math.max(0, this.#now() - capture.pausedAtMs);
    this.#alignTracks(capture);
    capture.paused = false;
    return this.#publish({ status: "recording" });
  }

  /**
   * The system tap and the microphone helper deliver chunks on unrelated
   * cadences, so each side drops a different amount of audio around a pause.
   * Pad the shorter track with silence so both resume from the same instant;
   * otherwise the offset would accumulate across pauses and the mix would
   * drift. Both sinks share one input and one output rate.
   */
  #alignTracks(capture: ActiveCapture) {
    const system = capture.sink;
    const mic = capture.micSink;
    if (!system || !mic) return;
    const deltaSamples = system.byteLength / 2 - mic.byteLength / 2;
    if (deltaSamples === 0) return;
    const frames = Math.round(
      (Math.abs(deltaSamples) * capture.sampleRate) / system.outputSampleRate
    );
    if (frames <= 0) return;
    if (deltaSamples > 0) mic.write(new Float32Array(frames));
    else system.write(new Float32Array(frames * capture.channels));
  }

  /** Drops any in-flight recording. Main must not leave a tap open on exit. */
  async close() {
    this.#closed = true;
    await this.cancel();
  }

  async microphones(): Promise<AudioCaptureMicrophones> {
    if (!this.#microphone?.available()) return { devices: [] };
    return this.#microphone.devices();
  }

  async selectMicrophone(
    input: AudioCaptureSelectMicrophoneInput
  ): Promise<AudioCaptureState> {
    const admission = getCurrentNativeSessionAdmission();
    const capture = this.#active;
    if (!capture || capture.stopped || this.#starting)
      throw new Error("No recording is available to change.");
    if (capture.ownerUserId !== admission.principalUserId)
      throw new Error("Sign in to the account that started this recording.");
    if (capture.micTask) throw new Error("The microphone is still changing.");
    await this.#changeMicrophone(capture, input.deviceId);
    return this.#snapshot();
  }

  /** MicrophoneSelection.tla: one transition; retire callbacks before stopping the helper. */
  #changeMicrophone(capture: ActiveCapture, deviceId: string | null): Promise<void> {
    const task = this.#replaceMicrophone(capture, deviceId);
    capture.micTask = task;
    this.#publish({});
    return task.finally(() => {
      capture.micTask = undefined;
      if (this.#active === capture) this.#publish({});
    });
  }

  async #replaceMicrophone(capture: ActiveCapture, deviceId: string | null) {
    const generation = ++capture.micGeneration;
    capture.microphone = "off";
    capture.micLevel = 0;
    const previous = capture.micSession;
    capture.micSession = undefined;
    await previous?.stop();
    if (capture.stopped) return;
    if (deviceId === null) {
      capture.microphoneDeviceId = undefined;
      return;
    }
    const microphone = this.#microphone;
    if (!microphone?.available()) {
      capture.microphone = "unavailable";
      return;
    }
    try {
      // Append to the same mic track across device changes; earlier speech is retained.
      capture.micSink ??= await WavSink.open({
        channels: 1,
        path: capture.micPath,
        sampleRate: capture.sampleRate,
      });
      if (capture.stopped) return;
      let accepting = false;
      let failed: Error | undefined;
      const session = await microphone.start({
        deviceId,
        sampleRate: capture.sampleRate,
        onError: (error) => {
          if (capture.stopped || capture.micGeneration !== generation) return;
          accepting = false;
          failed = error;
          capture.microphone = "unavailable";
          if (this.#active === capture)
            this.#publish({
              reason: `Microphone stopped: ${error.message}`.slice(0, 200),
            });
        },
        onFrames: (frames) => {
          if (
            !accepting ||
            capture.stopped ||
            capture.paused ||
            capture.micGeneration !== generation
          )
            return;
          capture.micSink?.write(frames);
          capture.micLevel = Math.max(
            frameLevel(frames),
            capture.micLevel * LEVEL_RELEASE
          );
        },
      });
      // Stop/cancel may have won while the helper was opening. Never revive it.
      if (capture.stopped || capture.micGeneration !== generation) {
        await session.stop();
        return;
      }
      if (failed) {
        await session.stop();
        throw failed;
      }
      this.#alignTracks(capture);
      capture.micSession = session;
      capture.microphoneDeviceId = deviceId;
      capture.microphone = "on";
      accepting = true;
      this.#publish({ reason: undefined });
    } catch (error) {
      if (capture.stopped || this.#active !== capture) return;
      capture.microphone = "unavailable";
      this.#publish({
        reason: `Microphone unavailable: ${describeError(error)}`.slice(0, 200),
      });
    }
  }

  /** Stops the helper and closes the microphone track; returns its summary. */
  async #finishMicrophone(capture: ActiveCapture) {
    await capture.micTask?.catch(() => undefined);
    const session = capture.micSession;
    capture.micSession = undefined;
    if (session) await session.stop().catch(() => undefined);
    const sink = capture.micSink;
    capture.micSink = undefined;
    if (!sink) return undefined;
    try {
      return await sink.finalize();
    } catch {
      return undefined;
    }
  }

  /**
   * Replaces the system track with the average of system + microphone. Both
   * sinks were opened with the same input rate, so they share an output rate
   * and mix sample for sample without resampling.
   */
  async #mixMicrophone(capture: ActiveCapture, sampleRate: number) {
    const [system, microphone] = await Promise.all([
      readWavPcm(capture.path),
      readWavPcm(capture.micPath),
    ]);
    const mixed = mixMono(system, microphone);
    const mixedPath = capture.path.replace(/\.wav$/, ".mixed.wav");
    const sink = await WavSink.open({ channels: 1, path: mixedPath, sampleRate });
    sink.write(mixed.samples);
    const summary = await sink.finalize();
    await rename(mixedPath, capture.path);
    return summary;
  }

  #ingest(capture: ActiveCapture, frames: Float32Array) {
    const sink = capture.sink;
    if (!sink || capture.stopped || capture.paused) return;
    sink.write(frames);
    const level = frameLevel(frames);
    this.#level = Math.max(level, this.#level * LEVEL_RELEASE);

    const elapsedMs = this.#now() - capture.startedAtMs - capture.pausedTotalMs;
    if (level > 0 && !capture.sawSignal) {
      capture.sawSignal = true;
      if (this.#permission !== "granted") {
        this.#permission = "granted";
        this.#publish({});
      }
    } else if (
      !capture.sawSignal &&
      this.#permission === "unknown" &&
      elapsedMs >= SILENCE_SUSPECT_MS
    ) {
      // The tap delivers silence rather than an error when macOS has not
      // granted system audio recording; surface it so the UI can point at the
      // privacy pane instead of showing a flat waveform forever.
      this.#permission = "suspected_denied";
      this.#publish({});
    }
    if (elapsedMs >= capture.maxDurationMs || sink.byteLength >= MAX_RECORDING_BYTES) {
      this.#capTap(capture, "The recording reached its length limit.");
      return;
    }

    const nowMs = this.#now();
    if (nowMs - this.#levelPublishedAtMs < LEVEL_PUBLISH_INTERVAL_MS) return;
    this.#levelPublishedAtMs = nowMs;
    this.#publish({});
  }

  /** Stops the tap but keeps the session open so `stop` can still claim it. */
  #capTap(capture: ActiveCapture, reason: string) {
    if (capture.capped) return;
    capture.capped = true;
    this.#stopTap(capture);
    this.#publish({ reason });
  }

  #stopTap(capture: ActiveCapture) {
    if (capture.stopped) return;
    capture.stopped = true;
    try {
      capture.tap.stop();
    } catch {
      /* A tap that refuses to stop is already gone. */
    }
  }

  async #teardown(capture: ActiveCapture) {
    this.#stopTap(capture);
    await this.#finishMicrophone(capture).catch(() => undefined);
    await rm(capture.micPath, { force: true }).catch(() => undefined);
    if (capture.sink) {
      await capture.sink.discard().catch(() => undefined);
      return;
    }
    await rm(capture.path, { force: true }).catch(() => undefined);
  }

  async #resolveNative() {
    if (this.#available === false) return undefined;
    const native = await this.#loadNative();
    this.#available = Boolean(native);
    if (!native) {
      this.#status = "unavailable";
      this.#reason = "Audio capture is unavailable in this runtime.";
    } else if (this.#status === "unavailable") {
      this.#status = "idle";
      this.#reason = undefined;
    }
    return native;
  }

  #publish(patch: {
    reason?: string | undefined;
    status?: AudioCaptureState["status"];
  }) {
    if ("reason" in patch) this.#reason = patch.reason;
    if (patch.status) this.#status = patch.status;
    if (patch.status === "idle") this.#level = 0;
    this.#revision += 1;
    const snapshot = this.#snapshot();
    this.#onStateChanged(snapshot);
    return snapshot;
  }

  #snapshot(): AudioCaptureState {
    const capture = this.#active;
    return {
      available: this.#available ?? false,
      capped: capture?.capped ?? false,
      channels: capture ? 1 : 0,
      durationMs: capture?.sink?.durationMs ?? 0,
      level:
        this.#status === "recording"
          ? Math.max(this.#level, capture?.micLevel ?? 0)
          : 0,
      microphone: capture?.microphone ?? "off",
      microphoneChanging: Boolean(capture?.micTask),
      ...(capture?.microphoneDeviceId
        ? { microphoneDeviceId: capture.microphoneDeviceId }
        : {}),
      permission: this.#permission,
      ...(this.#reason ? { reason: this.#reason } : {}),
      revision: this.#revision,
      sampleRate: capture?.sink?.outputSampleRate ?? 0,
      ...(capture ? { source: capture.source } : {}),
      status: this.#status,
    };
  }
}

function readScreenAccess(read: (() => ScreenAccessStatus) | undefined) {
  try {
    return read?.() === "granted";
  } catch {
    return false;
  }
}

function describeError(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function recordingFileName(startedAtMs: number) {
  const stamp = new Date(startedAtMs)
    .toISOString()
    .replace(/[:.]/g, "-")
    .replace(/Z$/, "");
  return `comma-recording-${stamp}-${randomUUID()}.wav`;
}

function startFailureReason(error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  return message.trim().slice(0, 200) || "The system audio tap could not be opened.";
}
