/**
 * Minimal, dependency-free sRGB -> OKLCH conversion and the Comma theme remap.
 *
 * OKLCH is a 3D color. Comma shares one (L, C, H) control point across the
 * token family, the same net as https://oklch.com:
 *
 *   `--comma-theme-h`  hue of the sample
 *   `--comma-theme-c`  peak chroma *gain* (C a midtone would receive)
 *   `--comma-theme-l`  sample lightness; 0.5 is identity for tokens
 *
 * Each token keeps its own origin lightness `l` from the Figma hex, then:
 *
 *   C(l) = gain · 4l(1 − l)
 *   L'(l) = clamp(0, l + (themeL − 0.5) · 4l(1 − l), 1)
 *
 * The parabola is 0 at black and white and 1 at l=0.5, so paper chrome stays
 * a quiet tint, poles keep contrast, and midtones carry the color. CSS Color 5
 * relative color evaluates `l` inside `oklch(from <hex> …)`.
 */

/** Peak chroma at L=0.5. Custom chroma sliders map 0–100 onto this range. */
export const commaThemeChromaGainMax = 0.16;

/** Sample lightness that leaves every token L unchanged. */
export const commaThemeLightnessNeutral = 0.5;

/**
 * Product range for `--comma-theme-l`. The token transform is an unbounded
 * lever over 0..1; these endpoints keep primary ≥ 4.5:1 and tertiary copy
 * readable at both Light and Dark custom schemes.
 */
export const commaThemeLightnessMin = 0.36;
export const commaThemeLightnessMax = 0.64;

export const clampCommaThemeLightness = (lightness: number) =>
  Math.min(commaThemeLightnessMax, Math.max(commaThemeLightnessMin, lightness));

/** Map a clamped sample L onto the pad's 0..1 lightness axis. */
export const commaThemeLightnessToPad = (lightness: number) =>
  (clampCommaThemeLightness(lightness) - commaThemeLightnessMin) /
  (commaThemeLightnessMax - commaThemeLightnessMin);

/** Map a pad unit 0..1 onto the product L range. */
export const commaThemePadToLightness = (unit: number) =>
  commaThemeLightnessMin +
  Math.min(1, Math.max(0, unit)) * (commaThemeLightnessMax - commaThemeLightnessMin);

/**
 * Chroma channel for retinted neutrals. `l` is the origin token lightness
 * from CSS relative color syntax — not a custom property.
 */
export const commaThemeChromaCssExpr = "calc(var(--comma-theme-c) * 4 * l * (1 - l))";

/**
 * Lightness channel for retinted neutrals. Same envelope as chroma, so a
 * custom L of 0.5 is a no-op and black/white barely move. Theme L is clamped
 * in the expression so endpoints cannot collapse semantic contrast.
 */
export const commaThemeLightnessCssExpr = `calc(clamp(0, l + (clamp(${commaThemeLightnessMin}, var(--comma-theme-l), ${commaThemeLightnessMax}) - 0.5) * 4 * l * (1 - l), 1))`;

export const oklchNeutralCss = (hex: string) =>
  `oklch(from ${hex} ${commaThemeLightnessCssExpr} ${commaThemeChromaCssExpr} var(--comma-theme-h))`;

/** 4L(1 − L): 0 at the poles, 1 at mid gray. */
export const oklchChromaEnvelope = (lightness: number) =>
  4 * lightness * (1 - lightness);

/** Token L' after a theme-sample lightness is applied. */
export const oklchShiftedLightness = (originL: number, themeL: number) => {
  const next =
    originL +
    (clampCommaThemeLightness(themeL) - commaThemeLightnessNeutral) *
      oklchChromaEnvelope(originL);
  return Math.min(1, Math.max(0, next));
};

/** Convert a sampled OKLCH chroma at a known L into peak gain. */
export const oklchChromaGainFromSample = (chroma: number, lightness: number) => {
  const envelope = oklchChromaEnvelope(lightness);
  if (envelope < 1e-7) return 0;
  return chroma / envelope;
};

const clamp01 = (v: number) => Math.min(1, Math.max(0, v));

const parseHex = (hex: string) => {
  const normalized = hex.trim().toLowerCase();
  const match = /^#([0-9a-f]{6})$/.exec(normalized);
  if (!match) {
    throw new Error(`hexToOklch: expected #RRGGBB, got: ${hex}`);
  }

  const int = Number.parseInt(match[1]!, 16);
  const r8 = (int >> 16) & 0xff;
  const g8 = (int >> 8) & 0xff;
  const b8 = int & 0xff;
  return { r8, g8, b8 };
};

const srgb8ToLinear = (v8: number) => {
  const v = clamp01(v8 / 255);
  return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
};

/**
 * Convert sRGB hex to OKLCH.
 *
 * Returns:
 * - L in [0, 1]
 * - C as a positive scalar (same scale as CSS OKLCH chroma expects as <number>)
 * - h in degrees [0, 360)
 */
export function hexToOklch(hex: string): { l: number; c: number; h: number } {
  const { r8, g8, b8 } = parseHex(hex);
  const r = srgb8ToLinear(r8);
  const g = srgb8ToLinear(g8);
  const b = srgb8ToLinear(b8);

  // Linear sRGB → LMS (Björn Ottosson). These coefficients are not XYZ.
  const lmsL = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
  const lmsM = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
  const lmsS = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;

  // LMS -> OKLab
  const l = Math.cbrt(Math.max(0, lmsL));
  const m = Math.cbrt(Math.max(0, lmsM));
  const s = Math.cbrt(Math.max(0, lmsS));

  const L = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s;
  const a = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
  const b2 = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;

  const C = Math.sqrt(a * a + b2 * b2);
  const hRad = Math.atan2(b2, a);
  const hDeg = ((hRad * 180) / Math.PI + 360) % 360;

  return { l: Math.min(1, Math.max(0, L)), c: C, h: hDeg };
}
