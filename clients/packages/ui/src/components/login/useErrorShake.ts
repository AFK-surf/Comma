import { useLayoutEffect, useSyncExternalStore, type RefObject } from "react";
import {
  isReducedMotionEnabled,
  motionLoginCodeError,
  subscribeToReducedMotion,
} from "../../tokens/motion";

const INTEGRATION_STEP_SECONDS = 1 / 240;
const MAX_SAMPLED_SECONDS = 1;
const REST_POSITION = 0.05;
const REST_VELOCITY = 0.5;
const reducedMotionServerSnapshot = () => false;

export type ErrorShakeState = {
  position: number;
  velocity: number;
};

export type ErrorShakeConfig = {
  amplitude: number;
  damping: number;
  stagger: number;
  stiffness: number;
};

export const stepErrorShake = (
  state: ErrorShakeState,
  dtSeconds: number,
  config: Pick<ErrorShakeConfig, "damping" | "stiffness">
): ErrorShakeState => {
  const acceleration =
    -config.stiffness * state.position - config.damping * state.velocity;
  const velocity = state.velocity + acceleration * dtSeconds;
  const position = state.position + velocity * dtSeconds;
  return { position, velocity };
};

/**
 * Samples the spring from its initial displacement using small, bounded steps.
 * Sampling from per-cell elapsed time keeps the stagger and spring curve stable
 * when animation frames are delayed or arrive at different display cadences.
 */
export const sampleErrorShake = (
  elapsedSeconds: number,
  config: Pick<ErrorShakeConfig, "amplitude" | "damping" | "stiffness">
): ErrorShakeState => {
  let state: ErrorShakeState = { position: config.amplitude, velocity: 0 };
  let remainingSeconds = Math.min(Math.max(elapsedSeconds, 0), MAX_SAMPLED_SECONDS);

  while (remainingSeconds > Number.EPSILON) {
    const dtSeconds = Math.min(remainingSeconds, INTEGRATION_STEP_SECONDS);
    state = stepErrorShake(state, dtSeconds, config);
    remainingSeconds -= dtSeconds;
  }

  return state;
};

export const isErrorShakeResting = (state: ErrorShakeState) =>
  Math.abs(state.position) < REST_POSITION && Math.abs(state.velocity) < REST_VELOCITY;

const applyShakeTransform = (element: HTMLElement | null, position: number) => {
  if (!element) {
    return;
  }
  if (Math.abs(position) < REST_POSITION) {
    element.style.transform = "";
    element.style.willChange = "";
    return;
  }
  element.style.willChange = "transform";
  element.style.transform = `translate3d(${position}px, 0, 0)`;
};

const resetShakeTransforms = (cells: Array<HTMLElement | null>) => {
  for (const cell of cells) {
    applyShakeTransform(cell, 0);
  }
};

export const useErrorShake = ({
  active,
  cellsRef,
  config = motionLoginCodeError,
  count,
  replayKey,
}: {
  active: boolean;
  cellsRef: RefObject<Array<HTMLElement | null>>;
  config?: ErrorShakeConfig;
  count: number;
  replayKey?: string | undefined;
}) => {
  const reducedMotion = useSyncExternalStore(
    subscribeToReducedMotion,
    isReducedMotionEnabled,
    reducedMotionServerSnapshot
  );

  useLayoutEffect(() => {
    const cells = cellsRef.current;

    if (!active || reducedMotion) {
      resetShakeTransforms(cells);
      return;
    }

    const startedAt = performance.now();
    let frameId = 0;

    const tick = (now: number) => {
      const elapsedMs = now - startedAt;
      let remaining = false;

      for (let index = 0; index < count; index += 1) {
        const delayMs = index * config.stagger;
        if (elapsedMs < delayMs) {
          remaining = true;
          continue;
        }

        const next = sampleErrorShake((elapsedMs - delayMs) / 1000, config);
        applyShakeTransform(cells[index] ?? null, next.position);
        if (!isErrorShakeResting(next)) {
          remaining = true;
        }
      }

      if (remaining) {
        frameId = window.requestAnimationFrame(tick);
        return;
      }

      resetShakeTransforms(cells);
    };

    frameId = window.requestAnimationFrame(tick);
    return () => {
      window.cancelAnimationFrame(frameId);
      resetShakeTransforms(cells);
    };
  }, [active, cellsRef, config, count, reducedMotion, replayKey]);
};
