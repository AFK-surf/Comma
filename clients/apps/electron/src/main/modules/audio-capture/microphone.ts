import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import type { Readable, Writable } from "node:stream";
import {
  audioCaptureMicrophonesSchema,
  type AudioCaptureMicrophones,
} from "@comma/native-bridge";

/**
 * Microphone intake for Main.
 *
 * Main has no Web Audio, so the microphone is read by a tiny native helper
 * (`MicCaptureHost`, AVAudioEngine with voice processing) that streams raw
 * Int16 mono PCM on stdout and JSON events on stderr. This module owns the
 * process; the capture service only sees Float32 frames.
 */
export interface MicrophoneSession {
  stop(): Promise<void>;
}

export interface MicrophoneStartInput {
  deviceId?: string;
  onError: (error: Error) => void;
  onFrames: (frames: Float32Array) => void;
  sampleRate: number;
}

export interface MicrophoneCapture {
  available(): boolean;
  devices(): Promise<AudioCaptureMicrophones>;
  start(input: MicrophoneStartInput): Promise<MicrophoneSession>;
}

export interface MicrophoneHostProcess {
  readonly exitCode: number | null;
  readonly killed: boolean;
  readonly stderr: Readable | null;
  readonly stdin: Writable | null;
  readonly stdout: Readable | null;
  kill(signal?: NodeJS.Signals): boolean;
  on(event: "exit", listener: (code: number | null) => void): unknown;
  on(event: "error", listener: (error: Error) => void): unknown;
  once(event: "exit", listener: (code: number | null) => void): unknown;
}

export type SpawnMicrophoneHost = (
  executablePath: string,
  args: string[]
) => MicrophoneHostProcess;

const READY_TIMEOUT_MS = 8_000;
const STOP_GRACE_MS = 1_500;
const EXIT_MICROPHONE_DENIED = 3;

export class MicrophoneDeniedError extends Error {
  constructor() {
    super("Microphone access was denied by macOS.");
    this.name = "MicrophoneDeniedError";
  }
}

export class HelperMicrophoneCapture implements MicrophoneCapture {
  readonly #executablePath: string;
  readonly #spawn: SpawnMicrophoneHost;
  readonly #readyTimeoutMs: number;

  constructor({
    executablePath,
    readyTimeoutMs = READY_TIMEOUT_MS,
    spawn: spawnImpl = defaultSpawnMicrophoneHost,
  }: {
    executablePath: string;
    readyTimeoutMs?: number;
    spawn?: SpawnMicrophoneHost;
  }) {
    this.#executablePath = executablePath;
    this.#readyTimeoutMs = readyTimeoutMs;
    this.#spawn = spawnImpl;
  }

  available() {
    return existsSync(this.#executablePath);
  }

  /** One bounded enumeration per menu open; never starts an audio engine. */
  devices(): Promise<AudioCaptureMicrophones> {
    const child = this.#spawn(this.#executablePath, ["--list-devices"]);
    return new Promise((resolve, reject) => {
      let bytes = Buffer.alloc(0);
      const timeout = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new Error("Microphone enumeration timed out."));
      }, this.#readyTimeoutMs);
      child.stdout?.on("data", (chunk: Buffer) => {
        bytes = Buffer.concat([bytes, chunk]);
        if (bytes.length > 128 * 2048) {
          clearTimeout(timeout);
          child.kill("SIGKILL");
          reject(new Error("Microphone list exceeded its size limit."));
        }
      });
      child.on("error", (error) => {
        clearTimeout(timeout);
        reject(error);
      });
      child.on("exit", (code) => {
        clearTimeout(timeout);
        try {
          if (code !== 0) throw new Error("Microphone enumeration failed.");
          resolve(
            audioCaptureMicrophonesSchema.parse(JSON.parse(bytes.toString("utf8")))
          );
        } catch (error) {
          reject(error);
        }
      });
    });
  }

  start(input: MicrophoneStartInput): Promise<MicrophoneSession> {
    const child = this.#spawn(this.#executablePath, [
      "--sample-rate",
      String(Math.round(input.sampleRate)),
      ...(input.deviceId ? ["--device", input.deviceId] : []),
    ]);
    const decoder = new Int16FrameDecoder(input.onFrames);
    let ready = false;
    let stopping = false;
    let exited = false;
    let stopTask: Promise<void> | undefined;

    return new Promise<MicrophoneSession>((resolve, reject) => {
      const timeout = setTimeout(() => {
        if (ready) return;
        void stop();
        reject(new Error("The microphone helper did not become ready in time."));
      }, this.#readyTimeoutMs);

      let stderrBuffer = "";
      child.stderr?.on("data", (chunk: Buffer | string) => {
        stderrBuffer += chunk.toString();
        let newline = stderrBuffer.indexOf("\n");
        while (newline !== -1) {
          const line = stderrBuffer.slice(0, newline).trim();
          stderrBuffer = stderrBuffer.slice(newline + 1);
          newline = stderrBuffer.indexOf("\n");
          if (!line) continue;
          const event = parseHostEvent(line);
          if (!event) continue;
          if (event.event === "ready" && !ready) {
            ready = true;
            clearTimeout(timeout);
            resolve({ stop: () => stop() });
          } else if (event.event === "error") {
            const error =
              event.message === "microphone_denied"
                ? new MicrophoneDeniedError()
                : new Error(event.message || "The microphone helper failed.");
            if (!ready) {
              clearTimeout(timeout);
              void stop();
              reject(error);
            } else if (!stopping) {
              input.onError(error);
            }
          }
        }
      });

      child.stdout?.on("data", (chunk: Buffer) => {
        if (stopping) return;
        decoder.push(chunk);
      });

      child.on("error", (error) => {
        clearTimeout(timeout);
        if (!ready) reject(error);
        else if (!stopping) input.onError(error);
      });

      child.on("exit", (code) => {
        exited = true;
        clearTimeout(timeout);
        if (!ready) {
          reject(
            code === EXIT_MICROPHONE_DENIED
              ? new MicrophoneDeniedError()
              : new Error(
                  `The microphone helper exited before it was ready (code ${code}).`
                )
          );
        } else if (!stopping && code !== 0) {
          input.onError(
            new Error(`The microphone helper exited unexpectedly (code ${code}).`)
          );
        }
      });

      const stop = () =>
        (stopTask ??= new Promise<void>((done) => {
          stopping = true;
          if (exited || child.exitCode !== null) {
            done();
            return;
          }
          const force = setTimeout(() => {
            // HelperTermination.tla: a sent signal is not an observed exit.
            if (!exited) child.kill("SIGKILL");
          }, STOP_GRACE_MS);
          child.once("exit", () => {
            clearTimeout(force);
            done();
          });
          // EOF on stdin is the helper's stop signal; SIGTERM is the backstop.
          try {
            child.stdin?.end();
          } catch {
            /* the pipe is already gone */
          }
          try {
            child.kill("SIGTERM");
          } catch {
            /* already exited */
          }
        }));
    });
  }
}

/** Turns arbitrary byte chunks into whole Int16 samples scaled to [-1, 1]. */
export class Int16FrameDecoder {
  readonly #onFrames: (frames: Float32Array) => void;
  #carry: Buffer | null = null;

  constructor(onFrames: (frames: Float32Array) => void) {
    this.#onFrames = onFrames;
  }

  push(chunk: Buffer) {
    let bytes = this.#carry ? Buffer.concat([this.#carry, chunk]) : chunk;
    const usable = bytes.length - (bytes.length % 2);
    this.#carry = usable < bytes.length ? bytes.subarray(usable) : null;
    if (usable === 0) return;
    bytes = bytes.subarray(0, usable);
    const frames = new Float32Array(usable / 2);
    for (let i = 0; i < frames.length; i += 1) {
      frames[i] = bytes.readInt16LE(i * 2) / 0x8000;
    }
    this.#onFrames(frames);
  }
}

function parseHostEvent(line: string): { event: string; message?: string } | null {
  try {
    const parsed: unknown = JSON.parse(line);
    if (
      typeof parsed === "object" &&
      parsed !== null &&
      typeof (parsed as { event?: unknown }).event === "string"
    ) {
      const message = (parsed as { message?: unknown }).message;
      return {
        event: (parsed as { event: string }).event,
        ...(typeof message === "string" ? { message } : {}),
      };
    }
  } catch {
    /* not JSON; ignore */
  }
  return null;
}

function defaultSpawnMicrophoneHost(executablePath: string, args: string[]) {
  return spawn(executablePath, args, {
    stdio: ["pipe", "pipe", "pipe"],
  }) as unknown as MicrophoneHostProcess;
}
