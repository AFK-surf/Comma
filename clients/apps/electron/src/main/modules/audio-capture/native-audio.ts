/**
 * Adapter over the platform audio tap.
 *
 * `@recappi/sdk` is a NAPI addon that ships prebuilt binaries for a subset of
 * platforms, so it is imported dynamically: a runtime without a binary must
 * degrade to an unavailable capability rather than fail module evaluation.
 * Everything past this file speaks only the interfaces declared here, which is
 * also what lets the service be tested without the addon.
 */

import { Worker } from "node:worker_threads";
import { realMainClock, type MainClock } from "../../clock";

export interface NativeAudioApplication {
  bundleIdentifier: string;
  name: string;
  processId: number;
}

export interface NativeAudioTap {
  readonly channels: number;
  readonly sampleRate: number;
  stop(): void;
}

export interface NativeAudioTapInput {
  onError: (error: Error) => void;
  onFrames: (frames: Float32Array) => void;
}

export interface NativeAudioCapture {
  applications(): NativeAudioApplication[];
  /** True while the process holds an audio input (its microphone is live). */
  isUsingMicrophone(processId: number): boolean;
  /** Fires when the set of audio-active processes changes; returns unsubscribe. */
  onApplicationListChanged(listener: () => void): () => void;
  /** Taps a single process's output — the whole point of a per-app recording. */
  tapApplication(input: NativeAudioTapInput & { processId: number }): NativeAudioTap;
  /** Taps the system mix, minus the excluded processes (this app, normally). */
  tapSystem(
    input: NativeAudioTapInput & { excludedProcessIds: readonly number[] }
  ): NativeAudioTap;
}

type RecappiApplicationInfo = {
  bundleIdentifier: string;
  name: string;
  processId: number;
};

type RecappiSession = {
  channels: number;
  sampleRate: number;
  stop(): void;
};

type RecappiStreamCallback = (error: Error | null, frames: Float32Array) => void;

export type RecappiModule = {
  getPlatformCapabilities(): { tapAudio: boolean; tapGlobalAudio: boolean };
  ShareableContent: {
    applications(): RecappiApplicationInfo[];
    applicationWithProcessId(processId: number): RecappiApplicationInfo | null;
    isUsingMicrophone(processId: number): boolean;
    onApplicationListChanged(callback: (error: Error | null) => void): {
      unsubscribe(): void;
    };
    tapAudio(processId: number, callback: RecappiStreamCallback): RecappiSession;
    tapGlobalAudio(
      excluded: RecappiApplicationInfo[] | null,
      callback: RecappiStreamCallback
    ): RecappiSession;
  };
};

export interface NativeAudioLogger {
  info(message: string, context: Record<string, unknown>): void;
  warn(message: string, context: Record<string, unknown>): void;
}

export interface NativeAudioCaptureLoaderDeps {
  importSdk?: () => Promise<RecappiModule>;
  /**
   * Makes the SDK's first CoreAudio call off Main's thread and settles when it
   * returns. Absent where that call costs nothing (other platforms).
   */
  firstCoreAudioCall?: (() => Promise<void>) | undefined;
  logger?: NativeAudioLogger | undefined;
  /** Main's clock: how long the first CoreAudio call took. */
  clock?: MainClock;
}

/**
 * The first CoreAudio call in a process sets up CoreAudio's client side,
 * which asks tccd for microphone access synchronously. That took from 13 ms
 * to 39 s, with the calling thread blocked throughout; CoreAudio does the
 * setup once per process. A worker thread makes that call, so Main's thread
 * never waits on tccd; Main imports and calls the SDK only after the worker's
 * call has settled. If the worker fails, Main makes the first call itself, as
 * it did before.
 */
export function createNativeAudioCaptureLoader({
  importSdk = importRecappiSdk,
  firstCoreAudioCall = process.platform === "darwin"
    ? makeFirstCoreAudioCallInWorker
    : undefined,
  logger,
  clock = realMainClock,
}: NativeAudioCaptureLoaderDeps = {}): () => Promise<NativeAudioCapture | undefined> {
  let load: Promise<NativeAudioCapture | undefined> | undefined;
  return () => {
    load ??= (async () => {
      if (firstCoreAudioCall) {
        const startedAt = clock.now();
        try {
          await firstCoreAudioCall();
          logger?.info("first CoreAudio call finished off Main's thread", {
            durationMs: clock.now() - startedAt,
            source: "native-audio",
          });
        } catch (error) {
          logger?.warn("first CoreAudio call failed off Main's thread; Main makes it", {
            durationMs: clock.now() - startedAt,
            error: error instanceof Error ? error.message : String(error),
            source: "native-audio",
          });
        }
      }
      return importNativeAudioCapture(importSdk);
    })();
    return load;
  };
}

/** Resolves the platform tap once per process, with no logger. */
export const loadNativeAudioCapture = createNativeAudioCaptureLoader();

async function importRecappiSdk(): Promise<RecappiModule> {
  return (await import("@recappi/sdk")) as unknown as RecappiModule;
}

/**
 * A missing addon, a platform without tap support, and a load failure are all
 * the same answer: undefined.
 */
async function importNativeAudioCapture(
  importSdk: () => Promise<RecappiModule>
): Promise<NativeAudioCapture | undefined> {
  let recappi: RecappiModule;
  try {
    recappi = await importSdk();
  } catch {
    return undefined;
  }

  try {
    const capabilities = recappi.getPlatformCapabilities();
    if (!capabilities.tapGlobalAudio && !capabilities.tapAudio) return undefined;
  } catch {
    return undefined;
  }

  return createRecappiAudioCapture(recappi);
}

// Listing the audio processes reaches CoreAudio's system object, which sets
// up the client side for the whole process.
const FIRST_CORE_AUDIO_CALL = `
const { parentPort, workerData } = require("node:worker_threads");
require(workerData.sdkPath).ShareableContent.applications();
parentPort.postMessage("done");
`;

/** Runs the SDK's first CoreAudio call in a worker thread. */
export async function makeFirstCoreAudioCallInWorker(
  sdkPath: string = require.resolve("@recappi/sdk")
): Promise<void> {
  const worker = new Worker(FIRST_CORE_AUDIO_CALL, {
    eval: true,
    workerData: { sdkPath },
  });
  try {
    await new Promise<void>((resolve, reject) => {
      worker.once("message", () => resolve());
      worker.once("error", reject);
      worker.once("exit", (code) =>
        reject(new Error(`The CoreAudio worker exited with code ${code}.`))
      );
    });
  } finally {
    await worker.terminate();
  }
}

function toTap(session: RecappiSession): NativeAudioTap {
  return {
    channels: session.channels,
    sampleRate: session.sampleRate,
    stop: () => session.stop(),
  };
}

function toStreamCallback({
  onError,
  onFrames,
}: NativeAudioTapInput): RecappiStreamCallback {
  return (error, frames) => {
    if (error) {
      onError(error);
      return;
    }
    onFrames(frames);
  };
}

export function createRecappiAudioCapture(recappi: RecappiModule): NativeAudioCapture {
  return {
    applications() {
      return recappi.ShareableContent.applications().map((application) => ({
        bundleIdentifier: application.bundleIdentifier,
        name: application.name,
        processId: application.processId,
      }));
    },
    isUsingMicrophone(processId) {
      try {
        return recappi.ShareableContent.isUsingMicrophone(processId) === true;
      } catch {
        return false;
      }
    },
    onApplicationListChanged(listener) {
      let subscription: { unsubscribe(): void } | undefined;
      try {
        subscription = recappi.ShareableContent.onApplicationListChanged((error) => {
          if (!error) listener();
        });
      } catch {
        return () => undefined;
      }
      return () => {
        try {
          subscription?.unsubscribe();
        } catch {
          /* already gone */
        }
      };
    },
    tapApplication({ processId, ...listeners }) {
      return toTap(
        recappi.ShareableContent.tapAudio(processId, toStreamCallback(listeners))
      );
    },
    tapSystem({ excludedProcessIds, ...listeners }) {
      const excluded = excludedProcessIds
        .map((processId) =>
          recappi.ShareableContent.applicationWithProcessId(processId)
        )
        .filter((application): application is RecappiApplicationInfo =>
          Boolean(application)
        );
      return toTap(
        recappi.ShareableContent.tapGlobalAudio(
          excluded.length > 0 ? excluded : null,
          toStreamCallback(listeners)
        )
      );
    },
  };
}
