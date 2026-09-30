export type SliderLabelPosition = "none" | "bottom" | "tooltip";

export { THUMB_SIZE, THUMB_RADIUS } from "./slider-geometry";

export const labelPadding: Record<SliderLabelPosition, string> = {
  none: "py-2",
  bottom: "pb-7 pt-2",
  tooltip: "pt-9 pb-2",
};

export const thumbClass =
  "absolute top-1/2 z-10 -translate-x-1/2 -translate-y-1/2 focus:outline-none disabled:cursor-not-allowed";

export const thumbHandleClass =
  "box-border size-5 shrink-0 rounded-full border-2 border-slider-handle-border bg-slider-handle-bg shadow-md transition-shadow hover:shadow-md focus-visible:shadow-focus-brand-shadow-xs disabled:border-secondary disabled:bg-disabled";

export const tooltipClass =
  "pointer-events-none absolute bottom-full left-1/2 mb-1.5 -translate-x-1/2 whitespace-nowrap rounded-full border border-secondary bg-popup-primary px-2.5 py-1 text-xs font-medium text-secondary shadow-xs";

export const bottomLabelClass =
  "pointer-events-none absolute top-full left-1/2 mt-1.5 -translate-x-1/2 text-xs font-medium text-tertiary";
