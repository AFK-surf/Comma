import type { z } from "zod";
import type { cardDataSchemas } from "./cardContract";

/**
 * Data an Agent passes to `comma.card(id, kind, data)`, derived from the card
 * contract. The runtime templates own every visual decision; these fields
 * carry facts only.
 */
export type CardDataByKind = {
  [Kind in keyof typeof cardDataSchemas]: z.input<(typeof cardDataSchemas)[Kind]>;
};

export type CardKind = keyof CardDataByKind;

export type ForecastData = CardDataByKind["forecast"];
export type OptionsData = CardDataByKind["options"];
export type MetricData = CardDataByKind["metric"];
export type TrendData = CardDataByKind["trend"];
export type ComparisonData = CardDataByKind["comparison"];
export type ScheduleData = CardDataByKind["schedule"];
export type ChecklistData = CardDataByKind["checklist"];
export type CompositionData = CardDataByKind["composition"];
export type PlaceData = CardDataByKind["place"];
export type FeedData = CardDataByKind["feed"];
export type TimerData = CardDataByKind["timer"];

/** Localized chrome text. `{name}` placeholders are filled by the runtime. */
export interface CardCopy {
  recommended: string;
  alternatives: string;
  high: string;
  low: string;
  feelsLike: string;
  humidity: string;
  ongoing: string;
  directions: string;
  range: string;
  days: string;
  attribute: string;
  option: string;
  versus: string;
  /** e.g. "已完成 {done}/{total}". */
  checklistProgress: string;
  focus: string;
  rest: string;
  paused: string;
  timeUp: string;
  /** e.g. "第 {current} / {total} 个番茄钟". */
  timerCycle: string;
}

/** Glyphs the templates draw. The host renders each one from its icon registry. */
export const cardIconNames = [
  "sun",
  "moon",
  "cloud",
  "partly-cloudy",
  "rain",
  "snow",
  "check",
  "check-large",
  "arrow-up",
  "arrow-right",
  "chevron-right",
] as const;

export type CardIconName = (typeof cardIconNames)[number];

/**
 * Comma tokens the card templates read. The host resolves each one to a
 * concrete value for the current theme, so custom themes and text scaling
 * carry into the sandbox.
 */
export const cardColorTokens = [
  "--color-bg-popup-secondary",
  "--color-bg-secondary",
  "--color-bg-quaternary",
  "--color-bg-brand-solid",
  "--color-bg-success-solid",
  "--color-border-primary",
  "--color-border-secondary",
  "--color-border-menu-primary",
  "--color-main-panel-bg",
  "--color-button-secondary-bg",
  "--color-button-secondary-fg",
  "--color-button-secondary-border",
  "--color-text-primary",
  "--color-text-secondary",
  "--color-text-tertiary",
  "--color-text-quaternary",
  "--color-text-success-primary",
  "--color-text-error-primary",
  "--color-fg-brand-primary",
  "--color-fg-warning-primary",
  "--color-fg-success-primary",
  "--color-fg-error-primary",
  "--color-fg-quaternary",
  "--color-fg-quinary",
  "--color-fg-white",
  ...[
    "gray",
    "brand",
    "blue",
    "indigo",
    "purple",
    "pink",
    "orange",
    "success",
    "warning",
    "error",
  ].flatMap((family) =>
    ["50", "200", "300", "700"].map((step) => `--color-utility-${family}-${step}`)
  ),
] as const;

export const cardLengthTokens = [
  ...[
    "xxs",
    "xs",
    "sm",
    "md",
    "lg",
    "xl",
    "2xl",
    "3xl",
    "4xl",
    "5xl",
    "6xl",
    "7xl",
    "8xl",
    "9xl",
    "10xl",
    "11xl",
  ].map((step) => `--spacing-${step}`),
  ...["xs", "sm", "md", "lg", "xl", "2xl"].map((step) => `--radius-${step}`),
  ...[
    "micro",
    "xs",
    "sm",
    "md",
    "lg",
    "title-3",
    "title-2",
    "title-1",
    "display-sm",
    "display-md",
    "display-lg",
  ].flatMap((step) => [`--text-${step}`, `--text-${step}--line-height`]),
  "--container-xs",
  "--container-md",
  "--container-lg",
  "--border-width-0-5",
  "--border-width-default",
] as const;

/** Tokens passed through as written: relative tracking, shadows and motion. */
export const cardRawTokens = [
  ...["lg", "title-3", "title-2", "title-1", "display-md", "display-lg"].map(
    (step) => `--text-${step}--letter-spacing`
  ),
  "--comma-icon-stroke-width",
  "--font-weight-regular",
  "--font-weight-medium",
  "--font-weight-semibold",
  "--opacity-disabled",
  "--shadow-xs",
  "--motion-duration-feedback-in",
  "--motion-duration-feedback-out",
  "--motion-duration-state-change",
  "--motion-duration-spatial-move",
  "--motion-duration-icon-swap",
  "--motion-duration-dialog-enter",
  "--motion-duration-progress-fill",
  "--motion-easing-smooth-out",
  "--motion-easing-drawer",
  "--motion-scale-pressed",
] as const;
