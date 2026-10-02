import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type RefObject,
} from "react";
import type { ForwardedAiInputProps } from "../types";

export interface VoiceRecordingOptions extends ForwardedAiInputProps<
  "onVoiceCancel" | "onVoiceConfirm" | "onVoicePress"
> {
  disabled: boolean;
  /** Where focus falls back when the recording ends with no voice control left. */
  promptRef: RefObject<HTMLElement | null>;
  readOnly: boolean;
  showVoiceButton: boolean;
  submitPending: boolean;
}

export type VoiceRecording = ReturnType<typeof useVoiceRecording>;

/**
 * One dictation from the composer's voice control: its running duration, and
 * where focus goes once it is confirmed, cancelled, or no longer available.
 */
export function useVoiceRecording({
  disabled,
  onVoiceCancel,
  onVoiceConfirm,
  onVoicePress,
  promptRef,
  readOnly,
  showVoiceButton,
  submitPending,
}: VoiceRecordingOptions) {
  const [isVoiceRecording, setIsVoiceRecording] = useState(false);
  const [voiceDuration, setVoiceDuration] = useState(0);
  const voiceDurationRef = useRef(0);
  const voiceRecordingActiveRef = useRef(false);
  const shouldRestoreVoiceFocusRef = useRef(false);
  const voiceTriggerRef = useRef<HTMLButtonElement>(null);
  const voiceInputAvailable =
    showVoiceButton && !disabled && !readOnly && !submitPending;
  const canStartVoiceRecording = voiceInputAvailable && !isVoiceRecording;

  const resetVoiceRecording = useCallback((restoreFocus: boolean) => {
    if (!voiceRecordingActiveRef.current) return false;
    voiceRecordingActiveRef.current = false;
    shouldRestoreVoiceFocusRef.current = restoreFocus;
    setIsVoiceRecording(false);
    voiceDurationRef.current = 0;
    setVoiceDuration(0);
    return true;
  }, []);

  const startVoiceRecording = useCallback(() => {
    if (!canStartVoiceRecording || voiceRecordingActiveRef.current) return;
    voiceRecordingActiveRef.current = true;
    voiceDurationRef.current = 0;
    setVoiceDuration(0);
    setIsVoiceRecording(true);
    const outcome = onVoicePress?.();
    if (outcome === false) {
      resetVoiceRecording(false);
      return;
    }
    if (outcome && typeof (outcome as Promise<unknown>).then === "function") {
      (outcome as Promise<unknown>).catch(() => {
        // Native capture refused to start: leave the recording UI instead of
        // showing a live waveform over nothing.
        resetVoiceRecording(true);
      });
    }
  }, [canStartVoiceRecording, onVoicePress, resetVoiceRecording]);

  const cancelVoiceRecording = useCallback(() => {
    if (!resetVoiceRecording(true)) return;
    onVoiceCancel?.();
  }, [onVoiceCancel, resetVoiceRecording]);

  const cancelVoiceRecordingWithoutFocus = useCallback(() => {
    if (!resetVoiceRecording(false)) return;
    onVoiceCancel?.();
  }, [onVoiceCancel, resetVoiceRecording]);

  const confirmVoiceRecording = useCallback(() => {
    const durationSeconds = voiceDurationRef.current;
    if (!resetVoiceRecording(true)) return;
    onVoiceConfirm?.(durationSeconds);
  }, [onVoiceConfirm, resetVoiceRecording]);

  useLayoutEffect(() => {
    if (isVoiceRecording || !shouldRestoreVoiceFocusRef.current) return;
    shouldRestoreVoiceFocusRef.current = false;

    const activeElement = document.activeElement;
    if (
      activeElement &&
      activeElement !== document.body &&
      activeElement !== document.documentElement
    ) {
      return;
    }

    const voiceTrigger = voiceTriggerRef.current;
    if (voiceTrigger && !voiceTrigger.disabled) {
      voiceTrigger.focus();
      return;
    }
    if (!disabled) promptRef.current?.focus();
  }, [disabled, isVoiceRecording, promptRef]);

  useEffect(() => {
    if (!isVoiceRecording) return;

    const startedAt = performance.now();
    const intervalId = window.setInterval(() => {
      const nextDuration = (performance.now() - startedAt) / 1000;
      voiceDurationRef.current = nextDuration;
      setVoiceDuration(nextDuration);
    }, 100);

    return () => window.clearInterval(intervalId);
  }, [isVoiceRecording]);

  useLayoutEffect(() => {
    if (isVoiceRecording && !voiceInputAvailable) {
      cancelVoiceRecordingWithoutFocus();
    }
  }, [cancelVoiceRecordingWithoutFocus, isVoiceRecording, voiceInputAvailable]);

  return {
    canStartVoiceRecording,
    cancelVoiceRecording,
    confirmVoiceRecording,
    isVoiceRecording,
    startVoiceRecording,
    voiceDuration,
    voiceTriggerRef,
  };
}
