import { useLayoutEffect, type RefObject } from "react";
import { isReducedMotionEnabled, subscribeToReducedMotion } from "../../tokens";

/**
 * Product shimmer tuned from the public interaction controls demonstrated by
 * https://github.com/BIAsia/gradient-shimmer. This is a Comma-owned
 * implementation: real DOM text, a measured finite band, and one WAAPI sweep
 * followed by an explicit idle interval.
 */
export const gradientShimmerMotion = {
  angleDegrees: 105,
  bandCoreRatio: 0.44,
  easing: "cubic-bezier(0.76, 0, 0.24, 1)",
  maximumSpreadPx: 48,
  pauseMs: 300,
  spreadMidRatio: 0.72,
  spreadPerCharacterPx: 5,
  sweepDurationMs: 2_000,
} as const;

const BASE_FONT_SIZE_PX = 14;
const FALLBACK_TEXT_WIDTH_PX = 96;
const INTERSECTION_ROOT_MARGIN = "160px";
const SCROLL_IDLE_MS = 120;

type GradientShimmerOptions = {
  active: boolean;
  contentIdentity: unknown;
};

type ShimmerMeasurement = {
  endPositionPx: number;
  startPositionPx: number;
};

/** Runs the shared Comma gradient shimmer on an existing, readable text node. */
export function useGradientShimmer(
  ref: RefObject<HTMLElement | null>,
  { active, contentIdentity }: GradientShimmerOptions
) {
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element || !active || !supportsGradientText()) return;

    element.dataset.shimmerReady = "true";
    let animation: Animation | null = null;
    let cycleTimer: number | undefined;
    let scrollTimer: number | undefined;
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

    const measure = (): ShimmerMeasurement => {
      const textLength = countCodePoints(element.textContent ?? "");
      const fontSize = Number.parseFloat(getComputedStyle(element).fontSize);
      const fontScale = Number.isFinite(fontSize) ? fontSize / BASE_FONT_SIZE_PX : 1;
      const spreadPx = Math.min(
        textLength * gradientShimmerMotion.spreadPerCharacterPx * fontScale,
        gradientShimmerMotion.maximumSpreadPx * fontScale
      );
      const spreadMidPx = spreadPx * gradientShimmerMotion.spreadMidRatio;
      const spreadCorePx = spreadMidPx * gradientShimmerMotion.bandCoreRatio;
      const spreadInnerPx = spreadCorePx / 3;
      const textWidth =
        element.getBoundingClientRect().width || FALLBACK_TEXT_WIDTH_PX * fontScale;
      const layerWidth = Math.max(1, textWidth + spreadPx * 2);
      const startPositionPx = -spreadPx - layerWidth / 2;
      const endPositionPx = textWidth + spreadPx - layerWidth / 2;

      element.style.setProperty("--ai-activity-shimmer-spread", `${spreadPx}px`);
      element.style.setProperty("--ai-activity-shimmer-spread-mid", `${spreadMidPx}px`);
      element.style.setProperty(
        "--ai-activity-shimmer-spread-core",
        `${spreadCorePx}px`
      );
      element.style.setProperty(
        "--ai-activity-shimmer-spread-inner",
        `${spreadInnerPx}px`
      );
      element.style.setProperty(
        "--ai-activity-shimmer-angle",
        `${gradientShimmerMotion.angleDegrees}deg`
      );
      element.style.backgroundSize = `${layerWidth}px 100%`;
      element.style.backgroundPosition = `${startPositionPx}px center`;

      return { endPositionPx, startPositionPx };
    };

    const beginSweep = () => {
      window.clearTimeout(cycleTimer);
      cycleTimer = undefined;
      if (!mayAnimate()) {
        pendingSweep = true;
        return;
      }

      pendingSweep = false;
      const { endPositionPx, startPositionPx } = measure();
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
        if (disposed || animation !== nextAnimation) return;
        cycleTimer = window.setTimeout(beginSweep, gradientShimmerMotion.pauseMs);
      };
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
      window.clearTimeout(scrollTimer);
      reconcileActivity();
      scrollTimer = window.setTimeout(() => {
        scrolling = false;
        reconcileActivity();
      }, SCROLL_IDLE_MS);
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

    measure();
    beginSweep();

    return () => {
      disposed = true;
      animation?.cancel();
      window.clearTimeout(cycleTimer);
      window.clearTimeout(scrollTimer);
      intersectionObserver?.disconnect();
      stopReducedMotion();
      forcedColorsQuery?.removeEventListener("change", onForcedColorsChange);
      document.removeEventListener("visibilitychange", onVisibilityChange);
      window.removeEventListener("scroll", onScroll, { capture: true });
      element.removeAttribute("data-shimmer-ready");
      element.style.removeProperty("--ai-activity-shimmer-spread");
      element.style.removeProperty("--ai-activity-shimmer-spread-mid");
      element.style.removeProperty("--ai-activity-shimmer-spread-core");
      element.style.removeProperty("--ai-activity-shimmer-spread-inner");
      element.style.removeProperty("--ai-activity-shimmer-angle");
      element.style.removeProperty("background-position");
      element.style.removeProperty("background-size");
    };
  }, [active, contentIdentity, ref]);
}

function countCodePoints(value: string) {
  let count = 0;
  for (const codePoint of value) {
    if (codePoint) count += 1;
  }
  return count;
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
