import type { CSSProperties } from "react";

/** Palette names the catalog accepts; the client maps each to a theme token. */
export const LABEL_PRESET_COLORS = [
  "gray",
  "blue",
  "indigo",
  "purple",
  "pink",
  "orange",
  "warning",
  "success",
  "error",
  "brand",
] as const;

export type LabelPresetColor = (typeof LABEL_PRESET_COLORS)[number];

const HEX_COLOR = /^#[0-9a-f]{6}$/i;

/** A label colour picked in the custom picker rather than from the presets. */
export function isCustomLabelColor(color: string | undefined): color is `#${string}` {
  return typeof color === "string" && HEX_COLOR.test(color);
}

export function labelDotStyle(color: string | undefined): CSSProperties | undefined {
  return isCustomLabelColor(color) ? { backgroundColor: color } : undefined;
}

/** The hollow mark standing for "no label" where labels are listed. */
export function NoLabelDot({ className = "" }: { className?: string }) {
  return (
    <span aria-hidden className={`comma-label-dot ${className}`} data-color="none" />
  );
}

/** The round colour mark shown beside a label wherever it appears. */
export function LabelDot({
  className = "",
  color,
}: {
  className?: string;
  color: string | undefined;
}) {
  const custom = isCustomLabelColor(color);
  return (
    <span
      aria-hidden
      className={`comma-label-dot ${className}`}
      data-color={custom ? "custom" : (color ?? "gray")}
      style={labelDotStyle(color)}
    />
  );
}
