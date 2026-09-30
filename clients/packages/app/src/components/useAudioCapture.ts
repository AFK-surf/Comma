import {
  getNativeBridge,
  type AudioCaptureMicrophones,
  type AudioCaptureStopResult,
  type AudioCaptureSource,
  type AudioCaptureState,
} from "@comma/native-bridge";
import { useCallback, useContext, useEffect, useRef, useState } from "react";
import { CommaAuthContext } from "./auth-context";

const SYSTEM_AUDIO: AudioCaptureSource = { kind: "system" };

/**
 * Renderer view of the Main-owned audio tap.
 *
 * Captured audio never reaches the renderer: this hook observes the bounded
 * capture state (status, duration, meter level) and, on stop, receives the
 * saved Drive location of the recording.
 */
export function useAudioCapture({ enabled = true }: { enabled?: boolean } = {}) {
  const bridge = getNativeBridge();
  // Composer also renders in signed-out shells (Side Chat) and in tests without
  // CommaAuthGate. A product lease is required to begin and claim a recording.
  const productLease = useContext(CommaAuthContext)?.productLease;
  // Surfaces that never show the voice control (Side Chat, threads) pass
  // `enabled: false` so they neither subscribe nor trip that window's
  // permission allowlist.
  const platformSupported = enabled && bridge.platform === "electron";
  const [state, setState] = useState<AudioCaptureState | null>(null);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const [microphones, setMicrophones] = useState<AudioCaptureMicrophones["devices"]>(
    []
  );
  const [microphonesLoading, setMicrophonesLoading] = useState(false);
  const [microphonesFailed, setMicrophonesFailed] = useState(false);
  const microphoneRequest = useRef(0);
  useEffect(
    () => () => {
      microphoneRequest.current += 1;
    },
    []
  );
  const loadMicrophones = useCallback(async () => {
    const request = ++microphoneRequest.current;
    setMicrophonesLoading(true);
    setMicrophonesFailed(false);
    try {
      const result = await bridge.audioCapture.microphones();
      if (microphoneRequest.current === request) setMicrophones(result.devices);
    } catch {
      if (microphoneRequest.current === request) setMicrophonesFailed(true);
    } finally {
      if (microphoneRequest.current === request) setMicrophonesLoading(false);
    }
  }, [bridge]);

  const accept = useCallback((next: AudioCaptureState) => {
    setState((current) =>
      current && current.revision > next.revision ? current : next
    );
  }, []);

  useEffect(() => {
    if (!platformSupported) return;
    return bridge.audioCapture.state.subscribe(accept);
  }, [accept, bridge, platformSupported]);

  const run = useCallback(
    async <Result>(operation: () => Promise<Result>) => {
      setPending(true);
      setError(undefined);
      try {
        return await operation();
      } catch (reason) {
        setError(reason instanceof Error ? reason.message : String(reason));
        try {
          accept(await bridge.audioCapture.state.get());
        } catch {
          /* retain last fact */
        }
        return undefined;
      } finally {
        setPending(false);
      }
    },
    [accept, bridge]
  );

  /** Resolves to the post-start state, or undefined when the call failed. */
  const start = useCallback(
    (
      source: AudioCaptureSource = SYSTEM_AUDIO,
      options: { microphone?: boolean } = {}
    ) =>
      run(async () => {
        if (!productLease) throw new Error("Sign in before starting a recording.");
        const next = await bridge.audioCapture.start({
          session: productLease,
          source,
          ...(options.microphone === undefined
            ? {}
            : { microphone: options.microphone }),
        });
        accept(next);
        return next;
      }).then((next) => next ?? undefined),
    [accept, bridge, productLease, run]
  );

  const selectMicrophone = useCallback(
    (deviceId: string | null) =>
      run(async () => {
        if (!productLease)
          throw new Error("Sign in to change the recording microphone.");
        const next = await bridge.audioCapture.selectMicrophone({
          session: productLease,
          deviceId,
        });
        accept(next);
        if (deviceId !== null && next.microphone === "unavailable")
          throw new Error(next.reason ?? "Microphone unavailable.");
        return next;
      }),
    [accept, bridge, productLease, run]
  );

  const openPermissionSettings = useCallback(
    () => bridge.audioCapture.openPermissionSettings(),
    [bridge]
  );

  const cancel = useCallback(
    () =>
      run(async () => {
        const next = await bridge.audioCapture.cancel();
        accept(next);
        return next;
      }),
    [accept, bridge, run]
  );

  /** Holds the recording; the tap stays open and the duration freezes. */
  const pause = useCallback(
    () =>
      run(async () => {
        accept(await bridge.audioCapture.pause());
      }),
    [accept, bridge, run]
  );

  const resume = useCallback(
    () =>
      run(async () => {
        accept(await bridge.audioCapture.resume());
      }),
    [accept, bridge, run]
  );

  /** Keeps Main's failure detail so a retained local WAV is visible to its owner. */
  const stop = useCallback(
    (): Promise<AudioCaptureStopResult | undefined> =>
      run(async () => {
        if (!productLease) {
          await bridge.audioCapture.cancel();
          return undefined;
        }
        return bridge.audioCapture.stop({ session: productLease });
      }).then((result) => result ?? undefined),
    [bridge, productLease, run]
  );

  return {
    /** True once Main has confirmed a working platform tap. */
    microphones,
    microphonesLoading,
    microphonesFailed,
    loadMicrophones,
    selectMicrophone,
    available: platformSupported && (state?.available ?? false),
    cancel,
    /** The tap stopped itself at the length ceiling; `stop` still claims it. */
    capped: state?.capped ?? false,
    durationMs: state?.durationMs ?? 0,
    error,
    level: state?.status === "recording" ? state.level : 0,
    openPermissionSettings,
    pause,
    paused: state?.status === "paused",
    pending,
    permission: state?.permission ?? "unknown",
    /** A recording is in flight, paused or not; `stop` and `cancel` apply. */
    recording: state?.status === "recording" || state?.status === "paused",
    resume,
    start,
    state,
    stop,
  };
}
