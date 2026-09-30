/**
 * Typography tokens — Comma Design System.
 * Source: Figma "Typography" page (node 18:1951).
 * Sizes/line-heights stay as px numbers here so the Figma source remains easy
 * to compare. The CSS generator emits these lengths as rem from a 16px root.
 * Letter spacing is expressed in em (Figma supplies it as a percentage).
 */
export const fontFamily = {
  sans: "'Inter Variable', 'SF Pro Display', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Open Sans', 'Helvetica Neue', sans-serif",
  mono: "'Geist Mono', ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
} as const;

export const fontWeight = {
  /** Inter Variable's 450 optical weight is used as the regular UI weight. */
  regular: 450,
  medium: 500,
  semibold: 600,
  bold: 700,
} as const;

export interface TypeStyle {
  fontSize: number;
  lineHeight: number;
  letterSpacing: string;
}

/**
 * Compact application type scale, kept in design-source px values.
 * The generator publishes the corresponding CSS variables in rem.
 */
export const compactTypeScale = {
  micro: { fontSize: 11, lineHeight: 16, letterSpacing: "0em" },
  mini: { fontSize: 12, lineHeight: 18, letterSpacing: "0em" },
  small: { fontSize: 13, lineHeight: 20, letterSpacing: "0em" },
  regular: { fontSize: 15, lineHeight: 24, letterSpacing: "0em" },
  large: { fontSize: 18, lineHeight: 28, letterSpacing: "-0.01em" },
  title3: { fontSize: 20, lineHeight: 30, letterSpacing: "-0.01em" },
  title2: { fontSize: 24, lineHeight: 32, letterSpacing: "-0.02em" },
  title1: { fontSize: 36, lineHeight: 44, letterSpacing: "-0.02em" },
} as const satisfies Record<string, TypeStyle>;

export type CompactTypeScaleKey = keyof typeof compactTypeScale;

export const typeScale = {
  display2xl: { fontSize: 72, lineHeight: 90, letterSpacing: "-0.02em" },
  displayXl: { fontSize: 60, lineHeight: 72, letterSpacing: "-0.02em" },
  displayLg: { fontSize: 48, lineHeight: 60, letterSpacing: "-0.02em" },
  displayMd: compactTypeScale.title1,
  displaySm: { fontSize: 30, lineHeight: 38, letterSpacing: "0em" },
  displayXs: compactTypeScale.title2,
  // Keep the existing Tailwind/Text API backed by the compact scale.
  textXl: compactTypeScale.title3,
  textLg: compactTypeScale.large,
  textMd: compactTypeScale.regular,
  textSm: compactTypeScale.small,
  textXs: compactTypeScale.mini,
} as const satisfies Record<string, TypeStyle>;

export type TypeScaleKey = keyof typeof typeScale;
export type FontWeightKey = keyof typeof fontWeight;
