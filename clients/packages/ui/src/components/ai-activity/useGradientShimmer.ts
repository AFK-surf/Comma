import { useLayoutEffect, type RefObject } from "react";
import { scheduleLayoutRead, uiClock, type CancelUiTimer } from "../../clock";
import { isReducedMotionEnabled, subscribeToReducedMotion } from "../../tokens";
import {
  applyShimmerBand,
  clearShimmerBand,
  gradientShimmerMotion,
  measureShimmerBand,
  type ShimmerBand,
} from "./gradientShimmerBand";

export { gradientShimmerMotion } from "./gradientShimmerBand";

const INTERSECTION_ROOT_MARGIN = "160px";

type GradientShimmerOptions = {
  active: boolean;
  contentIdentity: unknown;
  /** Sweep again after each pause (default), or sweep once and rest. */
  repeat?: boolean | undefined;
};

/** Runs the shared Comma gradient shimmer on an existing, readable text node. */
export function useGradientShimmer(
  ref: RefObject<HTMLElement | null>,
  { active, contentIdentity, repeat = true }: GradientShimmerOptions
) {
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element || !active || !supportsGradientText()) return;

    let animation: Animation | null = null;
    let cycleTimer: CancelUiTimer | undefined;
    let scrollTimer: CancelUiTimer | undefined;
    let sweepRead: CancelUiTimer | undefined;
    let disposed = false;
    let pendingSweep = false;
    let inViewport = true;
    let pageVisible = !document.hidden;
    let scrolling = false;
    let reducedMotion = isReducedMotionEnabled();
    const forcedColorsQuery = window.matchMedia?.("(forced-colors: active)");
    let forcedColors = forcedColorsQuery?.matches ?? false;

    const mayAnimate = () =>
      !disposed &&
      inViewport &&
      pageVisible &&
      !scrolling &&
      !reducedMotion &&
      !forcedColors;

    const sweep = ({ endPositionPx, startPositionPx }: ShimmerBand) => {
      if (typeof element.animate !== "function") return;
      const nextAnimation = element.animate(
        [
          { backgroundPosition: `${startPositionPx}px center` },
          { backgroundPosition: `${endPositionPx}px center` },
        ],
        {
          duration: gradientShimmerMotion.sweepDurationMs,
          easing: gradientShimmerMotion.easing,
          fill: "forwards",
        }
      );
      animation?.cancel();
      animation = nextAnimation;
      nextAnimation.onfinish = () => {
        if (disposed || animation !== nextAnimation || !repeat) return;
        // motion
        cycleTimer = uiClock.after(gradientShimmerMotion.pauseMs, beginSweep);
      };
    };

    const beginSweep = () => {
      cycleTimer?.();
      cycleTimer = undefined;
      if (!mayAnimate()) {
        pendingSweep = true;
        return;
      }
      pendingSweep = false;
      const band = measureShimmerBand(element);
      applyShimmerBand(element, band);
      sweep(band);
    };

    const reconcileActivity = () => {
      if (mayAnimate()) {
        if (animation?.playState === "paused") animation.play();
        if (pendingSweep) beginSweep();
      } else if (animation?.playState === "running") {
        animation.pause();
      }
    };

    const onVisibilityChange = () => {
      pageVisible = !document.hidden;
      reconcileActivity();
    };
    document.addEventListener("visibilitychange", onVisibilityChange);

    const onScroll = () => {
      scrolling = true;
      scrollTimer?.();
      reconcileActivity();
      // motion
      scrollTimer = uiClock.after(gradientShimmerMotion.scrollIdleMs, () => {
        scrolling = false;
        reconcileActivity();
      });
    };
    window.addEventListener("scroll", onScroll, { capture: true, passive: true });

    const intersectionObserver =
      typeof IntersectionObserver === "function"
        ? new IntersectionObserver(
            (entries) => {
              const latest = entries.at(-1);
              if (!latest) return;
              inViewport = latest.isIntersecting;
              reconcileActivity();
            },
            { rootMargin: INTERSECTION_ROOT_MARGIN }
          )
        : null;
    intersectionObserver?.observe(element);

    const stopReducedMotion = subscribeToReducedMotion(() => {
      reducedMotion = isReducedMotionEnabled();
      reconcileActivity();
    });
    const onForcedColorsChange = () => {
      forcedColors = forcedColorsQuery?.matches ?? false;
      reconcileActivity();
    };
    forcedColorsQuery?.addEventListener("change", onForcedColorsChange);

    // The first band is measured in the frame's shared layout read phase:
    // the shimmer mounts in the commit that adds a turn, and reading there
    // forced the transcript's layout ahead of the frame's own.
    sweepRead = scheduleLayoutRead(() => {
      sweepRead = undefined;
      if (disposed) return undefined;
      const band = measureShimmerBand(element);
      return () => {
        if (disposed) return;
        applyShimmerBand(element, band);
        if (!mayAnimate()) {
          pendingSweep = true;
          return;
        }
        pendingSweep = false;
        sweep(band);
      };
    });

    return () => {
      disposed = true;
      animation?.cancel();
      cycleTimer?.();
      sweepRead?.();
      scrollTimer?.();
      intersectionObserver?.disconnect();
      stopReducedMotion();
      forcedColorsQuery?.removeEventListener("change", onForcedColorsChange);
      document.removeEventListener("visibilitychange", onVisibilityChange);
      window.removeEventListener("scroll", onScroll, { capture: true });
      clearShimmerBand(element);
    };
  }, [active, contentIdentity, ref, repeat]);
}

function supportsGradientText() {
  if (typeof window.CSS?.supports !== "function") return false;
  const clipsText =
    window.CSS.supports("background-clip", "text") ||
    window.CSS.supports("-webkit-background-clip", "text");
  const mixesColors = window.CSS.supports(
    "color",
    "color-mix(in oklab, black 50%, white)"
  );
  return clipsText && mixesColors;
}
