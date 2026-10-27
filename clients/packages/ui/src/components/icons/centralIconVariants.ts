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
 * A few glyphs that the stroke-2 package ships as a pre-outlined fill, or draws
 * at an odd width (2.05556, 1.995), are a real 1.5 stroke in the stroke-1.5
 * package. Taken from there, the shared stroke rule (styles.css) draws them at
 * `--comma-icon-stroke-width` like every other icon. Glyphs that both packages
 * ship as a fill come from the stroke-2 package: a fill scales with the icon,
 * and its stroke-2 weight is the nearer one to the token at 16-20px.
 */
export const realStrokeAppIconVariant: CentralIconVariant = {
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
export const REAL_STROKE_APP_ICON_PACKAGE = centralIconPackage(
  realStrokeAppIconVariant
);
export const FILLED_APP_ICON_PACKAGE = centralIconPackage(filledAppIconVariant);
