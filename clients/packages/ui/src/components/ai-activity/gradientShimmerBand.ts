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
  /** Scrolling pauses the sweep until it has been idle this long. */
  scrollIdleMs: 120,
  spreadMidRatio: 0.72,
  spreadPerCharacterPx: 5,
  sweepDurationMs: 2_000,
} as const;

const BASE_FONT_SIZE_PX = 14;
const FALLBACK_TEXT_WIDTH_PX = 96;

/** The band's geometry for one sweep across the text. */
export type ShimmerBand = {
  endPositionPx: number;
  layerWidth: number;
  spreadCorePx: number;
  spreadInnerPx: number;
  spreadMidPx: number;
  spreadPx: number;
  startPositionPx: number;
};

/** Reads the text's size and length; writes nothing. */
export function measureShimmerBand(element: HTMLElement): ShimmerBand {
  const textLength = countCodePoints(element.textContent ?? "");
  const fontSize = Number.parseFloat(getComputedStyle(element).fontSize);
  const fontScale = Number.isFinite(fontSize) ? fontSize / BASE_FONT_SIZE_PX : 1;
  const spreadPx = Math.min(
    textLength * gradientShimmerMotion.spreadPerCharacterPx * fontScale,
    gradientShimmerMotion.maximumSpreadPx * fontScale
  );
  const spreadMidPx = spreadPx * gradientShimmerMotion.spreadMidRatio;
  const spreadCorePx = spreadMidPx * gradientShimmerMotion.bandCoreRatio;
  const textWidth =
    element.getBoundingClientRect().width || FALLBACK_TEXT_WIDTH_PX * fontScale;
  const layerWidth = Math.max(1, textWidth + spreadPx * 2);
  return {
    endPositionPx: textWidth + spreadPx - layerWidth / 2,
    layerWidth,
    spreadCorePx,
    spreadInnerPx: spreadCorePx / 3,
    spreadMidPx,
    spreadPx,
    startPositionPx: -spreadPx - layerWidth / 2,
  };
}

/** Sizes the gradient and switches the text to it (`data-shimmer-ready`). */
export function applyShimmerBand(element: HTMLElement, band: ShimmerBand) {
  const { style } = element;
  style.setProperty("--ai-activity-shimmer-spread", `${band.spreadPx}px`);
  style.setProperty("--ai-activity-shimmer-spread-mid", `${band.spreadMidPx}px`);
  style.setProperty("--ai-activity-shimmer-spread-core", `${band.spreadCorePx}px`);
  style.setProperty("--ai-activity-shimmer-spread-inner", `${band.spreadInnerPx}px`);
  style.setProperty(
    "--ai-activity-shimmer-angle",
    `${gradientShimmerMotion.angleDegrees}deg`
  );
  style.backgroundSize = `${band.layerWidth}px 100%`;
  style.backgroundPosition = `${band.startPositionPx}px center`;
  element.dataset.shimmerReady = "true";
}

export function clearShimmerBand(element: HTMLElement) {
  element.removeAttribute("data-shimmer-ready");
  for (const property of [
    "--ai-activity-shimmer-spread",
    "--ai-activity-shimmer-spread-mid",
    "--ai-activity-shimmer-spread-core",
    "--ai-activity-shimmer-spread-inner",
    "--ai-activity-shimmer-angle",
    "background-position",
    "background-size",
  ]) {
    element.style.removeProperty(property);
  }
}

function countCodePoints(value: string) {
  let count = 0;
  for (const codePoint of value) {
    if (codePoint) count += 1;
  }
  return count;
}
