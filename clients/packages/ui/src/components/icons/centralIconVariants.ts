export type CentralIconVariant = {
  filled: boolean;
  stroke: 1.5 | 2;
  radius: 1 | 2;
  join: "round";
};

export const parseCentralIconVariantName = (
  variantName: string
): CentralIconVariant | null => {
  const parts = Object.fromEntries(
    variantName.split(",").map((segment) => {
      const [key, value] = segment.trim().split("=");
      return [key, value];
    })
  );

  if (
    (parts.filled !== "off" && parts.filled !== "on") ||
    (parts.stroke !== "1.5" && parts.stroke !== "2") ||
    (parts.radius !== "1" && parts.radius !== "2") ||
    parts.join !== "round"
  ) {
    return null;
  }

  return {
    filled: parts.filled === "on",
    stroke: parts.stroke === "2" ? 2 : 1.5,
    radius: parts.radius === "1" ? 1 : 2,
    join: "round",
  };
};

export const centralIconPackage = (variant: CentralIconVariant): string => {
  const style = variant.filled ? "round-filled" : "round-outlined";
  return `@central-icons-react/${style}-radius-${variant.radius}-stroke-${variant.stroke}`;
};

/** Outlined variant shared by app navigation and action glyphs. */
export const outlinedAppIconVariant: CentralIconVariant = {
  filled: false,
  stroke: 2,
  radius: 2,
  join: "round",
};

/** Stronger outlined variant used only by the AI Input action glyphs. */
export const outlinedAiInputIconVariant: CentralIconVariant = {
  filled: false,
  stroke: 2,
  radius: 2,
  join: "round",
};

/** Stronger filled variant used by generated-media player controls. */
export const filledMediaIconVariant: CentralIconVariant = {
  filled: true,
  stroke: 2,
  radius: 2,
  join: "round",
};

/**
 * Central ships a handful of glyphs as a pre-outlined fill rather than a stroke.
 * A fill has no stroke for `--comma-icon-stroke-width` to thin, so taking them
 * from the stroke-2 package would leave them a third heavier than every icon
 * beside them. The stroke-1.5 package bakes the same glyph at the weight this
 * app renders at, so those glyphs come from there and need no thinning.
 */
export const preThinnedAppIconVariant: CentralIconVariant = {
  filled: false,
  stroke: 1.5,
  radius: 2,
  join: "round",
};

/** Filled status glyphs (toast leading icons, keyboard hints, status dots). */
export const filledAppIconVariant: CentralIconVariant = {
  filled: true,
  stroke: 2,
  radius: 2,
  join: "round",
};

export const OUTLINED_APP_ICON_PACKAGE = centralIconPackage(outlinedAppIconVariant);
export const PRE_THINNED_APP_ICON_PACKAGE = centralIconPackage(
  preThinnedAppIconVariant
);
export const FILLED_APP_ICON_PACKAGE = centralIconPackage(filledAppIconVariant);
