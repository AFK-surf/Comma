/** Voice-to-text composer visuals: layout, timing, and the no-capture fallback. */

import { motionDuration } from "../../../tokens";

export const AI_INPUT_VOICE_WAVEFORM_BAR_WIDTH = 2;
export const AI_INPUT_VOICE_WAVEFORM_BAR_GAP = 3;
export const AI_INPUT_VOICE_WAVEFORM_HEIGHT_PX = 24;
export const AI_INPUT_VOICE_WAVEFORM_BASELINE_HEIGHT = 2;
export const AI_INPUT_VOICE_WAVEFORM_STEP_MS = 80;
/** Matches `--motion-duration-spatial-move` for bar growth. */
export const AI_INPUT_VOICE_WAVEFORM_BAR_ENTER_MS = motionDuration.spatialMove;
export const AI_INPUT_VOICE_DURATION_WIDTH_PX = 32;
/** Tab-style left fade next to plus — opacity mask, not a blurred overlay. */
export const AI_INPUT_VOICE_WAVEFORM_EDGE_FADE_PX = 24;
export const AI_INPUT_VOICE_WAVEFORM_EDGE_FADE_STOPS = 8;

const easeInOutCubic = (progress: number) =>
  progress < 0.5
    ? 4 * progress * progress * progress
    : 1 - Math.pow(-2 * progress + 2, 3) / 2;

export const createVoiceWaveformEdgeMaskImage = () => {
  const fadePx = AI_INPUT_VOICE_WAVEFORM_EDGE_FADE_PX;
  const stopCount = AI_INPUT_VOICE_WAVEFORM_EDGE_FADE_STOPS;
  const fadeStops = Array.from({ length: stopCount + 1 }, (_, index) => {
    const progress = index / stopCount;
    const alpha = easeInOutCubic(progress).toFixed(3);
    const offset = Number((fadePx * progress).toFixed(2));
    return `rgb(0 0 0 / ${alpha}) ${offset}px`;
  });

  return `linear-gradient(to right, ${fadeStops.join(", ")}, black ${fadePx}px, black 100%)`;
};

export const voiceWaveformEdgeMaskImage = createVoiceWaveformEdgeMaskImage();

const WAVEFORM_BAR_STEP =
  AI_INPUT_VOICE_WAVEFORM_BAR_WIDTH + AI_INPUT_VOICE_WAVEFORM_BAR_GAP;

export const formatVoiceDuration = (durationSeconds: number) => {
  const totalSeconds = Math.max(0, Math.floor(durationSeconds));
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${seconds.toString().padStart(2, "0")}`;
};

export const voiceWaveformBarCountForWidth = (width: number) =>
  Math.max(
    1,
    Math.floor(
      (Math.max(width, WAVEFORM_BAR_STEP) + AI_INPUT_VOICE_WAVEFORM_BAR_GAP) /
        WAVEFORM_BAR_STEP
    )
  );

/** Speech-shaped envelope used when no measured capture level is supplied. */
export const simulatedVoiceLevel = (nowMs: number) => {
  const t = nowMs / 1000;
  const syllable = Math.max(0, Math.sin(t * 7.4));
  const phrase = 0.35 + 0.65 * (0.5 + 0.5 * Math.sin(t * 2.1));
  return Math.min(1, syllable * phrase * 0.88 + 0.1 * Math.random());
};
