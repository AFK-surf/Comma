/* oxlint-disable jsx-a11y/prefer-tag-over-role -- Canvas waveform is a named graphic, not a raster image. */
import { useEffect, useRef } from "react";
import {
  isReducedMotionEnabled,
  motionEasing,
  subscribeToReducedMotion,
} from "../../../tokens";
import { cx } from "../../utils";
import {
  AI_INPUT_VOICE_WAVEFORM_BAR_ENTER_MS,
  AI_INPUT_VOICE_WAVEFORM_BAR_GAP,
  AI_INPUT_VOICE_WAVEFORM_BAR_WIDTH,
  AI_INPUT_VOICE_WAVEFORM_BASELINE_HEIGHT,
  AI_INPUT_VOICE_WAVEFORM_HEIGHT_PX,
  AI_INPUT_VOICE_WAVEFORM_STEP_MS,
  simulatedVoiceLevel,
  voiceWaveformBarCountForWidth,
  voiceWaveformEdgeMaskImage,
} from "./voiceRecording";

const BAR_STEP = AI_INPUT_VOICE_WAVEFORM_BAR_WIDTH + AI_INPUT_VOICE_WAVEFORM_BAR_GAP;
const CENTER_Y = AI_INPUT_VOICE_WAVEFORM_HEIGHT_PX / 2;

const cubicBezierA = (start: number, end: number) => 1 - 3 * end + 3 * start;
const cubicBezierB = (start: number, end: number) => 3 * end - 6 * start;
const cubicBezierC = (start: number) => 3 * start;

const parseCubicBezier = (value: string) => {
  const match =
    /cubic-bezier\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)/.exec(
      value
    );
  if (!match) {
    return [0.22, 1, 0.36, 1] as const;
  }
  return [
    Number(match[1]),
    Number(match[2]),
    Number(match[3]),
    Number(match[4]),
  ] as const;
};

const SURFACE_EASE = createCubicBezierEasing(
  ...parseCubicBezier(motionEasing.surfaceSmoothOut)
);

type WaveformBar = {
  level: number;
  introducedAt: number;
};

const readThemeColors = (element: HTMLElement) => {
  const styles = getComputedStyle(element);
  return {
    active: styles.getPropertyValue("--color-fg-primary").trim() || "#1a1b1e",
    baseline: styles.getPropertyValue("--color-bg-quaternary").trim() || "#f1f1f1",
  };
};

function createCubicBezierEasing(x1: number, y1: number, x2: number, y2: number) {
  const sampleCurve = (t: number, start: number, end: number) =>
    ((cubicBezierA(start, end) * t + cubicBezierB(start, end)) * t +
      cubicBezierC(start)) *
    t;
  const sampleSlope = (t: number, start: number, end: number) =>
    3 * cubicBezierA(start, end) * t * t +
    2 * cubicBezierB(start, end) * t +
    cubicBezierC(start);

  const solveCurveT = (x: number) => {
    let estimate = x;
    for (let iteration = 0; iteration < 4; iteration += 1) {
      const slope = sampleSlope(estimate, x1, x2);
      if (Math.abs(slope) < 1e-6) break;
      estimate -= (sampleCurve(estimate, x1, x2) - x) / slope;
    }
    return Math.min(Math.max(estimate, 0), 1);
  };

  return (progress: number) => {
    if (progress <= 0) return 0;
    if (progress >= 1) return 1;
    return sampleCurve(solveCurveT(progress), y1, y2);
  };
}

const ensureCanvasResolution = (
  canvas: HTMLCanvasElement,
  context: CanvasRenderingContext2D,
  cssWidth: number
) => {
  const devicePixelRatio = window.devicePixelRatio || 1;
  const width = Math.max(1, Math.round(cssWidth * devicePixelRatio));
  const height = Math.round(AI_INPUT_VOICE_WAVEFORM_HEIGHT_PX * devicePixelRatio);
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
    canvas.style.width = `${cssWidth}px`;
    canvas.style.height = `${AI_INPUT_VOICE_WAVEFORM_HEIGHT_PX}px`;
  }
  context.setTransform(devicePixelRatio, 0, 0, devicePixelRatio, 0, 0);
};

const paintBars = (
  context: CanvasRenderingContext2D,
  bars: WaveformBar[],
  colors: { active: string; baseline: string },
  shiftProgress: number,
  timestamp: number,
  cssWidth: number
) => {
  context.clearRect(0, 0, cssWidth, AI_INPUT_VOICE_WAVEFORM_HEIGHT_PX);
  context.lineWidth = AI_INPUT_VOICE_WAVEFORM_BAR_WIDTH;
  context.lineCap = "round";

  const offsetX = -shiftProgress * BAR_STEP;

  context.strokeStyle = colors.baseline;
  context.beginPath();
  for (let index = 0; index < bars.length; index += 1) {
    const x = offsetX + index * BAR_STEP + AI_INPUT_VOICE_WAVEFORM_BAR_WIDTH / 2;
    if (x < -BAR_STEP || x > cssWidth + BAR_STEP) continue;
    context.moveTo(x, CENTER_Y - AI_INPUT_VOICE_WAVEFORM_BASELINE_HEIGHT / 2);
    context.lineTo(x, CENTER_Y + AI_INPUT_VOICE_WAVEFORM_BASELINE_HEIGHT / 2);
  }
  context.stroke();

  context.strokeStyle = colors.active;
  for (let index = 0; index < bars.length; index += 1) {
    const bar = bars[index];
    if (!bar) continue;
    const x = offsetX + index * BAR_STEP + AI_INPUT_VOICE_WAVEFORM_BAR_WIDTH / 2;
    if (x < -BAR_STEP || x > cssWidth + BAR_STEP) continue;

    const enterProgress = SURFACE_EASE(
      Math.min(
        1,
        Math.max(
          0,
          (timestamp - bar.introducedAt) / AI_INPUT_VOICE_WAVEFORM_BAR_ENTER_MS
        )
      )
    );
    const activeHeight =
      AI_INPUT_VOICE_WAVEFORM_BASELINE_HEIGHT +
      bar.level *
        (AI_INPUT_VOICE_WAVEFORM_HEIGHT_PX - AI_INPUT_VOICE_WAVEFORM_BASELINE_HEIGHT) *
        enterProgress;
    if (activeHeight <= AI_INPUT_VOICE_WAVEFORM_BASELINE_HEIGHT) continue;

    context.beginPath();
    context.moveTo(x, CENTER_Y - activeHeight / 2);
    context.lineTo(x, CENTER_Y + activeHeight / 2);
    context.stroke();
  }
};

export const AiInputVoiceWaveform = ({
  className,
  label,
  level,
}: {
  className?: string;
  label: string;
  /**
   * Measured 0..1 capture level. Omitted where no capture backs the strip —
   * Storybook, the web build — and the simulated envelope stands in.
   */
  level?: number;
}) => {
  const viewportRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  // The paint loop runs outside React, so the newest level reaches it through
  // a ref instead of retearing down the animation on every meter update.
  const levelRef = useRef(level);

  useEffect(() => {
    levelRef.current = level;
  }, [level]);

  useEffect(() => {
    const viewport = viewportRef.current;
    const canvas = canvasRef.current;
    const context = canvas?.getContext("2d");
    if (!viewport || !canvas || !context) return;

    let cssWidth = Math.max(1, Math.round(viewport.clientWidth));
    let colors = readThemeColors(canvas);
    let bars: WaveformBar[] = Array.from(
      { length: voiceWaveformBarCountForWidth(cssWidth) + 2 },
      () => ({ level: 0, introducedAt: 0 })
    );
    let elapsedSinceStep = 0;
    let lastTimestamp: number | null = null;
    let frameId = 0;
    let reducedMotion = isReducedMotionEnabled();

    const syncWidth = (nextWidth: number) => {
      const measured = Math.max(1, Math.round(nextWidth));
      if (measured === cssWidth) return;
      cssWidth = measured;
      const nextCount = voiceWaveformBarCountForWidth(cssWidth) + 2;
      if (nextCount > bars.length) {
        bars = [
          ...Array.from({ length: nextCount - bars.length }, () => ({
            level: 0,
            introducedAt: 0,
          })),
          ...bars,
        ];
      } else if (nextCount < bars.length) {
        bars = bars.slice(bars.length - nextCount);
      }
    };

    const tick = (timestamp: number) => {
      colors = readThemeColors(canvas);
      ensureCanvasResolution(canvas, context, cssWidth);

      if (reducedMotion) {
        paintBars(context, bars, colors, 0, timestamp, cssWidth);
        frameId = 0;
        return;
      }

      const previous = lastTimestamp ?? timestamp;
      elapsedSinceStep += Math.min(48, timestamp - previous);
      lastTimestamp = timestamp;

      while (elapsedSinceStep >= AI_INPUT_VOICE_WAVEFORM_STEP_MS) {
        elapsedSinceStep -= AI_INPUT_VOICE_WAVEFORM_STEP_MS;
        bars.shift();
        const measured = levelRef.current;
        bars.push({
          level:
            measured === undefined
              ? simulatedVoiceLevel(timestamp)
              : Math.min(1, Math.max(0, measured)),
          introducedAt: timestamp,
        });
      }

      paintBars(
        context,
        bars,
        colors,
        elapsedSinceStep / AI_INPUT_VOICE_WAVEFORM_STEP_MS,
        timestamp,
        cssWidth
      );
      frameId = window.requestAnimationFrame(tick);
    };

    syncWidth(viewport.clientWidth);
    frameId = window.requestAnimationFrame(tick);

    const resizeObserver =
      typeof ResizeObserver === "undefined"
        ? null
        : new ResizeObserver((entries) => {
            const nextWidth = entries[0]?.contentRect.width;
            if (nextWidth != null) syncWidth(nextWidth);
          });
    resizeObserver?.observe(viewport);

    const unsubscribeReducedMotion = subscribeToReducedMotion(() => {
      reducedMotion = isReducedMotionEnabled();
      lastTimestamp = null;
      if (!reducedMotion && frameId === 0) {
        frameId = window.requestAnimationFrame(tick);
      }
    });

    return () => {
      window.cancelAnimationFrame(frameId);
      resizeObserver?.disconnect();
      unsubscribeReducedMotion();
    };
  }, []);

  return (
    <div
      aria-label={label}
      className={cx("relative min-w-0 flex-1 overflow-hidden", className)}
      data-slot="ai-input-voice-waveform"
      ref={viewportRef}
      role="img"
      style={{
        height: AI_INPUT_VOICE_WAVEFORM_HEIGHT_PX,
        maskImage: voiceWaveformEdgeMaskImage,
        WebkitMaskImage: voiceWaveformEdgeMaskImage,
      }}
    >
      <canvas
        aria-hidden
        className="absolute inset-y-0 right-0 block"
        ref={canvasRef}
      />
    </div>
  );
};
