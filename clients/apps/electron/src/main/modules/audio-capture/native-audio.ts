/**
 * Adapter over the platform audio tap.
 *
 * `@recappi/sdk` is a NAPI addon that ships prebuilt binaries for a subset of
 * platforms, so it is imported dynamically: a runtime without a binary must
 * degrade to an unavailable capability rather than fail module evaluation.
 * Everything past this file speaks only the interfaces declared here, which is
 * also what lets the service be tested without the addon.
 */

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

type RecappiModule = {
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

let cachedLoad: Promise<NativeAudioCapture | undefined> | undefined;

/**
 * Resolves the platform tap once per process. A missing addon, a platform
 * without tap support, and a load failure are all the same answer: undefined.
 */
export function loadNativeAudioCapture(): Promise<NativeAudioCapture | undefined> {
  cachedLoad ??= importNativeAudioCapture();
  return cachedLoad;
}

async function importNativeAudioCapture(): Promise<NativeAudioCapture | undefined> {
  let recappi: RecappiModule;
  try {
    recappi = (await import("@recappi/sdk")) as unknown as RecappiModule;
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
